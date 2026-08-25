"""Environment-driven configuration for the whisper service."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default).strip()


def _cache_root() -> Path:
    """Writable cache root (models + HF cache). Defaults under XDG cache dir."""
    base = os.environ.get("XDG_CACHE_HOME", "").strip() or str(Path.home() / ".cache")
    return Path(base) / "whisper-service"


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        return default


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name, "").strip().lower()
    if not raw:
        return default
    return raw in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Config:
    # Model
    model: str = field(default_factory=lambda: _env("WHISPER_MODEL", "large-v3"))
    model_dir: Path = field(
        default_factory=lambda: Path(_env("WHISPER_MODEL_DIR", str(_cache_root() / "models")))
    )
    hf_home: Path = field(
        default_factory=lambda: Path(_env("WHISPER_HF_HOME", str(_cache_root() / "hf")))
    )

    # Device
    device: str = field(default_factory=lambda: _env("WHISPER_DEVICE", "auto"))  # auto|cuda|cpu
    compute_type: str = field(default_factory=lambda: _env("WHISPER_COMPUTE_TYPE", "auto"))
    cpu_threads: int = field(default_factory=lambda: _env_int("WHISPER_CPU_THREADS", 0))

    # VRAM residency
    idle_timeout: float = field(
        default_factory=lambda: _env_float("WHISPER_IDLE_TIMEOUT", 120.0)
    )  # seconds; 0 disables auto-unload
    keep_loaded: bool = field(default_factory=lambda: _env_bool("WHISPER_KEEP_LOADED", False))

    # Process lifetime: once the model is released (idle reaper or explicit
    # /unload), exit the whole process (code 0) instead of keeping ~GBs of
    # host memory resident; socket activation re-activates on the next request.
    auto_stop: bool = field(default_factory=lambda: _env_bool("WHISPER_AUTO_STOP", False))

    # Server
    host: str = field(default_factory=lambda: _env("WHISPER_HOST", "0.0.0.0"))
    port: int = field(default_factory=lambda: _env_int("WHISPER_PORT", 8790))
    max_concurrent: int = field(default_factory=lambda: _env_int("WHISPER_MAX_CONCURRENT", 1))
    max_upload_mb: int = field(default_factory=lambda: _env_int("WHISPER_MAX_UPLOAD_MB", 2048))

    @property
    def device_allowed(self) -> str:
        return self.device if self.device in ("auto", "cuda", "cpu") else "auto"

    def __post_init__(self) -> None:
        # Point huggingface_hub at the project-local cache *before* any
        # download happens, so model weights live under the project dir.
        os.environ.setdefault("HF_HOME", str(self.hf_home))
        os.environ.setdefault("HF_HUB_CACHE", str(self.hf_home / "hub"))
        # ctranslate2 CUDA builds need the pip-provided CUDA runtime libs.
        self._extend_ld_library_path()

    @staticmethod
    def _extend_ld_library_path() -> None:
        """Add pip nvidia-* package lib dirs (libcudart/libcublas) to LD_LIBRARY_PATH."""
        import site

        candidates: list[str] = []
        for sp in site.getsitepackages():
            nvidia_dir = Path(sp) / "nvidia"
            if nvidia_dir.is_dir():
                candidates.extend(str(p) for p in sorted(nvidia_dir.glob("*/lib")))
        if not candidates:
            return
        existing = os.environ.get("LD_LIBRARY_PATH", "")
        parts = existing.split(":") if existing else []
        for c in candidates:
            if c not in parts:
                parts.append(c)
        os.environ["LD_LIBRARY_PATH"] = ":".join(parts)


def load_config() -> Config:
    return Config()