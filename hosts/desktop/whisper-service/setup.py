from setuptools import find_packages, setup

setup(
    name="whisper-service",
    version="1.0.0",
    description="GPU-accelerated Whisper transcription service with lazy VRAM residency",
    packages=find_packages(include=["whisper_service", "whisper_service.*"]),
    python_requires=">=3.10",
    entry_points={
        "console_scripts": [
            "whisper = whisper_service.cli:main",
            "whisper-serve = whisper_service.cli:serve_main",
        ],
    },
)
