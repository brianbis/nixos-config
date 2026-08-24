"""Model residency engine: lazy VRAM load, idle unload, status reporting.

The whole point of this module: whisper weights occupy GPU memory *only while
the service is running* (i.e. while a model is loaded), and are released as
soon as the idle window expires. Nothing is loaded at process start.
"""

from __future__ import annotations

import gc
import logging
import os
import shutil
import subprocess
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterator

import ctranslate2

from .config import Config

log = logging.getLogger("whisper_service.engine")


def cuda_device_count() -> int:
    """Number of CUDA devices visible to ctranslate2 (0 when no /dev/nvidia* nodes)."""
    try:
        return int(ctranslate2.get_cuda_device_count())
    except Exception:  # pragma: no cover - driver hiccup
        return 0


def process_rss_mb() -> float:
    try:
        with open("/proc/self/status") as fh:
            for line in fh:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) / 1024.0
    except OSError:
        pass
    return -1.0


def nvidia_smi_summary() -> str | None:
    """One-line GPU memory summary if nvidia-smi is available, else None."""
    exe = shutil.which("nvidia-smi")
    if not exe:
        return None
    try:
        out = subprocess.run(
            [
                exe,
                "--query-gpu=index,name,memory.used,memory.total,utilization.gpu",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if out.returncode == 0:
            return out.stdout.strip().replace("\n", " | ")
    except (subprocess.SubprocessError, OSError):
        pass
    return None


@dataclass
class TranscriptionResult:
    text: str
    language: str
    language_probability: float
    duration: float
    segments: list[dict[str, Any]]
    transcription_time: float


class ModelManager:
    """Owns the (at most one) loaded whisper model and its VRAM lifetime."""

    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self._lock = threading.RLock()  # guards load/unload/switch
        self._busy = threading.Semaphore(max(1, cfg.max_concurrent))
        self._model: Any | None = None
        self._model_name: str | None = None
        self._device: str | None = None
        self._compute_type: str | None = None
        self._last_used: float | None = None
        self._active_jobs = 0
        self._loaded_at: float | None = None
        self._load_time: float | None = None
        self._cuda_count = cuda_device_count()
        self._reaper: threading.Thread | None = None
        # Called (lock released) when the model transitions from loaded to
        # fully released — by the idle reaper or an explicit unload, but NOT
        # during a model switch. The app uses this to request a graceful
        # process stop when WHISPER_AUTO_STOP=1.
        self.on_model_released: Callable[[], None] | None = None
        if cfg.idle_timeout > 0 and not cfg.keep_loaded:
            self._reaper = threading.Thread(
                target=self._reaper_loop, name="whisper-idle-reaper", daemon=True
            )
            self._reaper.start()
        log.info(
            "ModelManager ready: cuda_devices=%s device_pref=%s idle_timeout=%.0fs",
            self._cuda_count,
            cfg.device,
            cfg.idle_timeout,
        )

    # ------------------------------------------------------------------ device

    @property
    def device(self) -> str:
        """Resolve the effective device (auto -> cuda when visible, else cpu)."""
        with self._lock:
            if self._device is None:
                pref = self.cfg.device_allowed
                if pref == "cuda" and self._cuda_count == 0:
                    log.warning("WHISPER_DEVICE=cuda requested but no CUDA device visible; using CPU")
                    self._device = "cpu"
                elif pref == "auto":
                    self._device = "cuda" if self._cuda_count > 0 else "cpu"
                else:
                    self._device = pref
            return self._device

    @property
    def compute_type(self) -> str:
        with self._lock:
            if self._compute_type is None:
                pref = self.cfg.compute_type
                if pref == "auto":
                    self._compute_type = "float16" if self.device == "cuda" else "int8"
                else:
                    self._compute_type = pref
            return self._compute_type

    # ------------------------------------------------------------------- state

    @property
    def model_name(self) -> str | None:
        with self._lock:
            return self._model_name

    @property
    def is_loaded(self) -> bool:
        with self._lock:
            return self._model is not None

    @property
    def active_jobs(self) -> int:
        with self._lock:
            return self._active_jobs

    def seconds_idle(self) -> float | None:
        with self._lock:
            if self._last_used is None:
                return None
            return max(0.0, time.monotonic() - self._last_used)

    # -------------------------------------------------------------------- load

    def _resolve_model_path(self, name: str) -> str:
        """Prefer a local model dir; otherwise let faster-whisper fetch from HF."""
        local = self.cfg.model_dir / name
        if local.is_dir() and (local / "model.bin").exists():
            return str(local)
        return name

    def ensure_loaded(self, name: str | None = None) -> None:
        """Load the model into (VRAM|RAM) if not already resident. Blocks until ready."""
        name = name or self.cfg.model
        with self._lock:
            if self._model is not None and self._model_name == name:
                self._last_used = time.monotonic()
                return
            if self._model is not None:
                log.info("Switching model %s -> %s (releasing old weights)", self._model_name, name)
                self._release_locked()
            from faster_whisper import WhisperModel  # deferred: import cost + keeps startup light

            device = self.device
            compute = self.compute_type
            path = self._resolve_model_path(name)
            log.info(
                "Loading whisper model %r into %s (%s) ...", name, device, compute
            )
            t0 = time.monotonic()
            self._model = WhisperModel(
                path,
                device=device,
                compute_type=compute,
                cpu_threads=self.cfg.cpu_threads,
            )
            self._model_name = name
            self._device = device
            self._compute_type = compute
            self._loaded_at = time.monotonic()
            self._last_used = time.monotonic()
            self._load_time = time.monotonic() - t0
            log.info(
                "Model %r resident on %s in %.1fs (rss=%.0fMB)",
                name, device, self._load_time, process_rss_mb(),
            )

    def _release_locked(self) -> None:
        """Drop the model and free its memory. Caller holds the lock."""
        if self._model is None:
            return
        name = self._model_name
        self._model = None
        self._model_name = None
        self._last_used = None
        self._loaded_at = None
        gc.collect()
        # ctranslate2 returns GPU allocations to the CUDA context when the
        # model object is destroyed; nothing else to empty.
        log.info("Released model %r (rss=%.0fMB)", name, process_rss_mb())

    def unload(self) -> bool:
        """Explicitly release the model (frees VRAM). Returns True if something was loaded."""
        with self._lock:
            had = self._model is not None
            self._release_locked()
        if had:
            self._notify_released()
        return had

    def _notify_released(self) -> None:
        """Invoke the release callback (if any), outside the model lock."""
        cb = self.on_model_released
        if cb is None:
            return
        try:
            cb()
        except Exception:  # pragma: no cover - a callback bug must not break residency
            log.exception("on_model_released callback failed")

    # ------------------------------------------------------------------ reaper

    def _reaper_loop(self) -> None:
        while True:
            time.sleep(1.0)
            try:
                self._maybe_unload_idle()
            except Exception:  # pragma: no cover
                log.exception("idle reaper error")

    def _maybe_unload_idle(self) -> None:
        released = False
        with self._lock:
            if self._model is None or self._last_used is None:
                return
            if self._active_jobs > 0:
                return
            idle = time.monotonic() - self._last_used
            if idle >= self.cfg.idle_timeout:
                log.info(
                    "Idle for %.0fs (timeout %.0fs); unloading model to free %s memory",
                    idle, self.cfg.idle_timeout, self._device or "device",
                )
                self._release_locked()
                released = True
        if released:
            self._notify_released()

    # ----------------------------------------------------------------- transcribe

    @contextmanager
    def job(self, model: str | None = None) -> Iterator[Any]:
        """Acquire a transcription slot; ensures the model is resident."""
        self._busy.acquire()
        with self._lock:
            self._active_jobs += 1
        try:
            self.ensure_loaded(model)
            with self._lock:
                m = self._model
                assert m is not None
            yield m
        finally:
            with self._lock:
                self._active_jobs = max(0, self._active_jobs - 1)
                self._last_used = time.monotonic()
            self._busy.release()

    def transcribe(
        self,
        audio_path: str | Path,
        *,
        model: str | None = None,
        language: str | None = None,
        task: str = "transcribe",
        vad_filter: bool = False,
        beam_size: int = 5,
        temperature: float | None = 0.0,
        initial_prompt: str | None = None,
        condition_on_previous_text: bool = True,
    ) -> TranscriptionResult:
        """Run one transcription; loads the model on demand if not resident."""
        t0 = time.monotonic()
        with self.job(model) as m:
            segments_iter, info = m.transcribe(
                str(audio_path),
                language=language,
                task=task,
                vad_filter=vad_filter,
                beam_size=beam_size,
                temperature=temperature if temperature is not None else 0.0,
                initial_prompt=initial_prompt,
                condition_on_previous_text=condition_on_previous_text,
            )
            segments: list[dict[str, Any]] = []
            for seg in segments_iter:
                segments.append(
                    {
                        "id": seg.id,
                        "start": round(seg.start, 3),
                        "end": round(seg.end, 3),
                        "text": seg.text.strip(),
                    }
                )
        return TranscriptionResult(
            text=" ".join(s["text"] for s in segments).strip(),
            language=info.language,
            language_probability=round(float(info.language_probability), 4),
            duration=round(float(info.duration), 3),
            segments=segments,
            transcription_time=round(time.monotonic() - t0, 3),
        )

    # ------------------------------------------------------------------- status

    def status(self) -> dict[str, Any]:
        with self._lock:
            return {
                "model_loaded": self._model is not None,
                "model": self._model_name,
                "default_model": self.cfg.model,
                "device": self._device or self.device,
                "compute_type": self._compute_type or self.compute_type,
                "cuda_devices_visible": self._cuda_count,
                "seconds_since_last_use": (
                    round(self.seconds_idle() or 0.0, 1)
                    if self._model is not None
                    else None
                ),
                "idle_timeout_s": self.cfg.idle_timeout,
                "keep_loaded": self.cfg.keep_loaded,
                "active_jobs": self._active_jobs,
                "max_concurrent": self.cfg.max_concurrent,
                "model_load_time_s": (
                    round(self._load_time, 2) if self._load_time is not None else None
                ),
                "process_rss_mb": round(process_rss_mb(), 1),
                "nvidia_smi": nvidia_smi_summary(),
            }

    # --------------------------------------------------------------- shutdown

    def shutdown(self, timeout: float | None = None) -> bool:
        """Release the model and free its memory.

        ``timeout`` bounds how long to wait for the model lock. The lock is
        held for the whole model load (including the first-use weight
        download, which can take minutes), so an unbounded wait here would
        hang a SIGTERM handler until systemd force-kills the process. When
        the lock cannot be acquired in time the explicit unload is skipped:
        the process is exiting anyway, and the driver reclaims the GPU
        memory when it dies.

        Returns True when the model was explicitly released.
        """
        if timeout is None:
            with self._lock:
                self._release_locked()
            return True
        if not self._lock.acquire(timeout=timeout):
            log.warning(
                "shutdown: model lock still held after %.0fs; skipping explicit "
                "unload (process exit reclaims device memory)",
                timeout,
            )
            return False
        try:
            self._release_locked()
            return True
        finally:
            self._lock.release()