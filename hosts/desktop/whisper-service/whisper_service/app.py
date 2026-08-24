"""FastAPI application: OpenAI-compatible transcription endpoint + residency control."""

from __future__ import annotations

import logging
import os
import signal
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import anyio
from fastapi import FastAPI, File, Form, HTTPException, Query, UploadFile
from fastapi.responses import JSONResponse, PlainTextResponse

from . import __version__
from .config import Config, load_config
from .engine import ModelManager

log = logging.getLogger("whisper_service.app")

# SIGTERM/teardown: how long to wait for the model lock before giving up on
# an explicit unload. The lock is held for the whole model load, so an
# unbounded wait would hang the handler until systemd force-kills us.
SHUTDOWN_LOCK_TIMEOUT = 30.0

AUDIO_EXTS = {
    ".wav", ".mp3", ".m4a", ".aac", ".ogg", ".opus", ".flac", ".wma",
    ".webm", ".mp4", ".mov", ".mkv", ".avi", ".m4b", ".amr", ".3gp",
}


def _fmt_ts_srt(t: float) -> str:
    ms = int(round(t * 1000))
    h, ms = divmod(ms, 3600_000)
    m, ms = divmod(ms, 60_000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def _fmt_ts_vtt(t: float) -> str:
    return _fmt_ts_srt(t).replace(",", ".")


def _to_srt(segments: list[dict[str, Any]]) -> str:
    out: list[str] = []
    for i, seg in enumerate(segments, 1):
        out.append(f"{i}\n{_fmt_ts_srt(seg['start'])} --> {_fmt_ts_srt(seg['end'])}\n{seg['text']}\n")
    return "\n".join(out)


def _to_vtt(segments: list[dict[str, Any]]) -> str:
    out = ["WEBVTT\n"]
    for seg in segments:
        out.append(f"{_fmt_ts_vtt(seg['start'])} --> {_fmt_ts_vtt(seg['end'])}\n{seg['text']}\n")
    return "\n".join(out)


class AppState:
    def __init__(self) -> None:
        self.cfg: Config = load_config()
        self.manager: ModelManager = ModelManager(self.cfg)


def create_app(state: AppState | None = None) -> FastAPI:
    state = state or AppState()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        log.info(
            "whisper-service %s starting: model=%s device=%s idle_timeout=%.0fs",
            __version__, state.cfg.model, state.manager.device, state.cfg.idle_timeout,
        )

        def _term(signum: int, _frame: Any) -> None:
            log.info("signal %s: unloading model and exiting", signum)
            state.manager.shutdown(timeout=SHUTDOWN_LOCK_TIMEOUT)
            os._exit(0)

        try:
            signal.signal(signal.SIGTERM, _term)
            signal.signal(signal.SIGINT, _term)
        except ValueError:  # pragma: no cover - non-main thread
            pass
        yield
        state.manager.shutdown(timeout=SHUTDOWN_LOCK_TIMEOUT)
        log.info("whisper-service stopped")

    app = FastAPI(
        title="whisper-service",
        version=__version__,
        description=(
            "GPU-accelerated Whisper transcription. Weights load into VRAM on demand, "
            "are released after the idle window, and — with WHISPER_AUTO_STOP=1 — the "
            "whole process exits (systemd socket activation restarts it on demand)."
        ),
        lifespan=lifespan,
    )
    app.state.ws = state

    # ------------------------------------------------------------------ health

    @app.get("/health")
    async def health() -> dict[str, Any]:
        s = state.manager.status()
        return {
            "status": "ok",
            "version": __version__,
            "model_loaded": s["model_loaded"],
            "device": s["device"],
            "cuda_devices_visible": s["cuda_devices_visible"],
        }

    @app.get("/status")
    async def status() -> dict[str, Any]:
        return state.manager.status()

    # ------------------------------------------------------------- residency

    @app.post("/load")
    async def load(model: str | None = Form(None)) -> dict[str, Any]:
        """Load the model into VRAM now (pre-warm)."""
        t0 = time.monotonic()
        try:
            await anyio.to_thread.run_sync(state.manager.ensure_loaded, model)
        except Exception as exc:
            raise HTTPException(500, f"model load failed: {exc}") from exc
        s = state.manager.status()
        return {
            "loaded": True,
            "model": s["model"],
            "device": s["device"],
            "load_time_s": round(time.monotonic() - t0, 2),
        }

    @app.post("/unload")
    async def unload() -> dict[str, Any]:
        had = await anyio.to_thread.run_sync(state.manager.unload)
        return {"unloaded": had, "model_loaded": state.manager.is_loaded}

    # ------------------------------------------------------------------ models

    @app.get("/v1/models")
    @app.get("/models")
    async def models() -> dict[str, Any]:
        cfg = state.cfg
        local: list[str] = []
        if cfg.model_dir.is_dir():
            local = sorted(p.name for p in cfg.model_dir.iterdir() if (p / "model.bin").exists())
        return {
            "object": "list",
            "data": [
                {
                    "id": m,
                    "object": "model",
                    "owned_by": "local",
                    "local": (cfg.model_dir / m / "model.bin").exists() if m in local else False,
                }
                for m in ([cfg.model] + [m for m in local if m != cfg.model])
            ],
        }

    # ----------------------------------------------------------- transcription

    @app.post("/v1/audio/transcriptions")
    @app.post("/audio/transcriptions")
    async def transcriptions(
        file: UploadFile = File(...),
        model: str | None = Form(None),
        language: str | None = Form(None),
        prompt: str | None = Form(None),
        response_format: str = Form("json"),
        timestamp_granularities: str | None = Form(None),
        vad_filter: bool = Form(False),
        temperature: float | None = Form(None),
        beam_size: int = Form(5),
    ):
        """OpenAI-compatible transcription endpoint.

        Accepts any audio format PyAV can decode (wav, mp3, m4a, ogg, flac,
        mp4/mov containers, ...).
        """
        model = model or state.cfg.model
        if response_format not in ("json", "verbose_json", "text", "srt", "vtt"):
            raise HTTPException(
                400, "response_format must be one of json|verbose_json|text|srt|vtt"
            )

        name = file.filename or "audio"
        ext = Path(name).suffix.lower()
        if ext not in AUDIO_EXTS:
            raise HTTPException(415, f"unsupported file type {ext or '(none)'}")

        size = 0
        tmp_path: str | None = None
        try:
            fd, tmp_path = tempfile.mkstemp(suffix=ext, prefix="whisper-up-")
            with os.fdopen(fd, "wb") as out:
                while chunk := await file.read(1 << 20):
                    size += len(chunk)
                    if size > state.cfg.max_upload_mb * 1024 * 1024:
                        raise HTTPException(413, "file too large")
                    out.write(chunk)
            if size == 0:
                raise HTTPException(400, "empty file")

            result = await anyio.to_thread.run_sync(
                lambda: state.manager.transcribe(
                    tmp_path,
                    model=model,
                    language=language,
                    vad_filter=vad_filter,
                    temperature=temperature,
                    beam_size=beam_size,
                    initial_prompt=prompt,
                )
            )
        except HTTPException:
            raise
        except Exception as exc:
            log.exception("transcription failed")
            raise HTTPException(500, f"transcription failed: {exc}") from exc
        finally:
            if tmp_path:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass

        if response_format == "text":
            return PlainTextResponse(result.text)
        if response_format == "srt":
            return PlainTextResponse(_to_srt(result.segments), media_type="text/plain")
        if response_format == "vtt":
            return PlainTextResponse(_to_vtt(result.segments), media_type="text/vtt")
        return JSONResponse(
            {
                "task": "transcription",
                "model": model,
                "language": result.language,
                "language_probability": result.language_probability,
                "duration": result.duration,
                "transcription_time": result.transcription_time,
                "text": result.text,
                "segments": result.segments,
            }
        )

    # ------------------------------------------------------------------ misc

    @app.get("/")
    async def root() -> dict[str, Any]:
        return {
            "service": "whisper-service",
            "version": __version__,
            "endpoints": [
                "POST /v1/audio/transcriptions",
                "GET  /v1/models",
                "GET  /status",
                "POST /load",
                "POST /unload",
                "GET  /health",
            ],
        }

    return app


def _configure_logging() -> None:
    logging.basicConfig(
        level=os.environ.get("WHISPER_LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def _socket_activated() -> bool:
    """True when systemd handed us a socket via socket activation (LISTEN_FDS)."""
    return os.environ.get("LISTEN_PID", "").strip() == str(os.getpid())


def run_server(cfg: Config, state: AppState | None = None) -> int:
    """Run the HTTP server; return the process exit code.

    Socket activation: when systemd started us via a .socket unit (LISTEN_FDS
    is set for this pid) the listening socket is inherited — uvicorn binds
    nothing itself. Otherwise bind host:port from the config.

    Auto-stop (WHISPER_AUTO_STOP=1): once the model is released — by the idle
    reaper or an explicit /unload — the process exits with code 0 *after* the
    in-flight request has been answered. The systemd socket unit keeps the
    port bound and re-activates the service on the next connection, so the
    steady state is "no process at all" (VRAM and host memory both ~0).
    """
    import asyncio
    import socket as socket_mod

    import uvicorn

    _configure_logging()
    state = state or AppState()
    app = create_app(state)

    inherited: list[socket_mod.socket] = []
    if _socket_activated():
        # systemd handed us the listening socket (fd 3, LISTEN_FDS=1).
        # uvicorn does not read LISTEN_FDS itself, so wrap the fd and pass
        # the socket to serve() explicitly (the same path Gunicorn workers
        # use). The process binds nothing itself.
        config = uvicorn.Config(app, log_level="info")
        inherited = [socket_mod.socket(fileno=3)]
    else:
        config = uvicorn.Config(
            app, host=cfg.host, port=cfg.port, log_level="info"
        )

    server = uvicorn.Server(config)

    stop_requested = False
    if cfg.auto_stop:

        def _request_stop() -> None:
            # Called by the engine when the model transitions to released.
            # The in-flight request (if any) has already been answered — the
            # callback fires after the job finished — so stopping now is safe.
            nonlocal stop_requested
            if stop_requested:
                return
            stop_requested = True
            log.info(
                "model released and WHISPER_AUTO_STOP=1: stopping process "
                "(exit 0; socket activation re-activates on next request)"
            )
            server.should_exit = True

        state.manager.on_model_released = _request_stop

    log.info(
        "starting uvicorn: socket_activated=%s auto_stop=%s",
        _socket_activated(), cfg.auto_stop,
    )
    asyncio.run(server.serve(sockets=inherited or None))
    return 0


def main() -> None:
    cfg = load_config()
    raise SystemExit(run_server(cfg))


if __name__ == "__main__":
    main()