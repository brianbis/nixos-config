"""GPU-accelerated Whisper transcription service with lazy VRAM residency.

Weights are loaded into GPU memory only while the service is actively
transcribing (plus a configurable idle window), and are released back to
the system when idle.
"""

__version__ = "1.0.0"
