"""Command-line interface.

One-shot mode (`whisper-transcribe`) loads the model, transcribes, and exits —
weights are in VRAM only for the duration of the run. Server mode
(`whisper-serve`) keeps the model resident across requests until the idle
window expires; with WHISPER_AUTO_STOP=1 the server process itself exits
after the window (systemd socket activation restarts it on the next request).
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

from . import __version__
from .config import load_config
from .engine import ModelManager, TranscriptionResult


def _print_result(result: TranscriptionResult, fmt: str, model: str, language: str | None) -> None:
    if fmt == "json":
        print(
            json.dumps(
                {
                    "model": model,
                    "language": result.language,
                    "language_probability": result.language_probability,
                    "duration": result.duration,
                    "transcription_time": result.transcription_time,
                    "text": result.text,
                    "segments": result.segments,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    elif fmt == "srt":
        from .app import _to_srt

        print(_to_srt(result.segments))
    elif fmt == "vtt":
        from .app import _to_vtt

        print(_to_vtt(result.segments))
    else:
        print(result.text)


def cmd_transcribe(args: argparse.Namespace) -> int:
    cfg = load_config()
    logging.basicConfig(level=args.log_level, format="%(levelname)s %(name)s: %(message)s")
    mgr = ModelManager(cfg)
    try:
        for path in args.files:
            p = Path(path)
            if not p.exists():
                print(f"error: file not found: {path}", file=sys.stderr)
                return 2
            result = mgr.transcribe(
                p,
                model=args.model,
                language=args.language,
                vad_filter=args.vad_filter,
                beam_size=args.beam_size,
            )
            if args.files != [path]:
                print(f"=== {path} ===")
            _print_result(result, args.format, args.model or cfg.model, args.language)
    finally:
        mgr.shutdown()  # release VRAM immediately
    return 0


def _fetch(server: str, path: str, *, method: str = "GET", data: bytes | None = None, timeout: float = 60.0) -> str | None:
    """HTTP helper for the control subcommands.

    Returns the decoded body, or None (after printing a hint) when the
    service cannot be reached — expected when it is stopped between
    requests (socket activation + WHISPER_AUTO_STOP).
    """
    import urllib.error
    import urllib.request

    req = urllib.request.Request(f"{server}{path}", data=data, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read().decode()
    except urllib.error.URLError as exc:
        print(f"error: cannot reach {server}{path}: {exc.reason}", file=sys.stderr)
        print(
            "hint: with socket activation + WHISPER_AUTO_STOP the service process "
            "exits once the model is released; the next request re-activates it. "
            "Retry, or inspect: systemctl status whisper-service.socket whisper-service.service",
            file=sys.stderr,
        )
        return None


def cmd_serve(args: argparse.Namespace) -> int:
    from dataclasses import replace

    from .app import run_server

    # run_server configures logging itself; honour --log-level via the env.
    os.environ.setdefault("WHISPER_LOG_LEVEL", args.log_level)
    cfg = load_config()
    if args.host is not None:
        cfg = replace(cfg, host=args.host)
    if args.port is not None:
        cfg = replace(cfg, port=args.port)
    return run_server(cfg)


def cmd_status(args: argparse.Namespace) -> int:
    body = _fetch(args.server, "/status", timeout=10)
    if body is None:
        return 3
    print(body)
    return 0


def cmd_load(args: argparse.Namespace) -> int:
    import urllib.parse

    data = urllib.parse.urlencode({"model": args.model}).encode() if args.model else b""
    body = _fetch(args.server, "/load", method="POST", data=data, timeout=600)
    if body is None:
        return 3
    print(body)
    return 0


def cmd_unload(args: argparse.Namespace) -> int:
    body = _fetch(args.server, "/unload", method="POST", timeout=60)
    if body is None:
        return 3
    print(body)
    return 0


def cmd_fetch_model(args: argparse.Namespace) -> int:
    """Pre-download a model (HF openai/whisper-* -> ctranslate2 format) into the cache."""
    cfg = load_config()
    from faster_whisper import WhisperModel

    print(f"fetching {args.model} (first use downloads + converts, this can take a while)...")
    WhisperModel(args.model, device="cpu", compute_type="int8")
    print(f"done. model now cached under {cfg.hf_home}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="whisper", description=__doc__.splitlines()[0])
    p.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True)

    t = sub.add_parser("transcribe", help="one-shot transcription (loads model, runs, frees VRAM)")
    t.add_argument("files", nargs="+", help="audio files")
    t.add_argument("--model", default=None, help="model name (default: $WHISPER_MODEL or large-v3)")
    t.add_argument("--language", default=None, help="force language (e.g. en, de)")
    t.add_argument("--format", choices=["text", "json", "srt", "vtt"], default="text")
    t.add_argument("--vad-filter", action="store_true", help="enable silero VAD filtering")
    t.add_argument("--beam-size", type=int, default=5)
    t.add_argument("--log-level", default="INFO")
    t.set_defaults(func=cmd_transcribe)

    s = sub.add_parser("serve", help="run the HTTP service")
    s.add_argument("--host", default=None)
    s.add_argument("--port", type=int, default=None)
    s.add_argument("--log-level", default="INFO")
    s.set_defaults(func=cmd_serve)

    st = sub.add_parser("status", help="print residency status of the running server")
    st.add_argument("--server", default="http://127.0.0.1:8790")
    st.set_defaults(func=cmd_status)

    l = sub.add_parser("load", help="load the model now (pre-warm VRAM on the running server)")
    l.add_argument("--model", default=None)
    l.add_argument("--server", default="http://127.0.0.1:8790")
    l.set_defaults(func=cmd_load)

    u = sub.add_parser("unload", help="release the model (free VRAM) on the running server")
    u.add_argument("--server", default="http://127.0.0.1:8790")
    u.set_defaults(func=cmd_unload)

    f = sub.add_parser("fetch-model", help="pre-download a model into the local cache")
    f.add_argument("model", nargs="?", default=None)
    f.set_defaults(func=cmd_fetch_model)

    return p


def serve_main(argv: list[str] | None = None) -> int:
    """Entry point for the `whisper-serve` console script.

    Equivalent to `whisper serve`, so `whisper-serve` starts the HTTP service
    and `whisper-serve --port 9000` (etc.) passes through to the serve subcommand.
    """
    if argv is None:
        argv = sys.argv[1:]
    return main(["serve", *argv])


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.cmd == "serve":
        cfg = load_config()
        if args.host is None:
            args.host = cfg.host
        if args.port is None:
            args.port = cfg.port
    if args.cmd == "fetch-model" and args.model is None:
        args.model = load_config().model
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())