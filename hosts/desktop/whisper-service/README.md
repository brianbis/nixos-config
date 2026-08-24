# whisper-service

GPU-accelerated Whisper transcription service (faster-whisper / CTranslate2) with
**on-demand VRAM residency**: model weights are loaded into GPU memory only while
the service is actively transcribing, and are released back to the system once the
idle window expires. Nothing is loaded at process start.

With **socket activation + auto-stop** (the NixOS default) it goes one step
further: the whole process exits after the idle window, so between requests
neither VRAM nor host memory is held — the systemd socket unit keeps the port
bound (kernel-held, ~0 memory) and re-activates the service on the next
connection.

## How VRAM residency works

| Phase | VRAM usage |
|---|---|
| Process running, no model loaded (startup / after idle timeout) | **0** — only the small Python/CT2 runtime |
| `POST /load` or first transcription request | weights load into VRAM (large-v3 fp16 ≈ 3.1 GB) |
| Transcription in flight | resident |
| `WHISPER_IDLE_TIMEOUT` seconds after last use | model is unloaded, VRAM freed (a reaper thread polls every second) |
| `POST /unload` | immediate release |
| release + `WHISPER_AUTO_STOP=1` | **process exits (code 0)** — VRAM *and* host memory freed; the socket unit re-activates the service on the next request |

One-shot CLI mode (`whisper transcribe file.wav`) does the same thing in a single
process: load → transcribe → free → exit.

## Building (Nix flake)

```bash
nix build .#whisper-service
nix run .#whisper-service            # start the HTTP service
nix run .#whisper-cli -- transcribe audio.mp3   # one-shot transcription
```

The flake uses the official CTranslate2 4.8.1 wheel (CUDA-enabled; CUDA libraries
are `dlopen()`ed at runtime, so it also works on GPU-less machines) plus nixpkgs
`cudaPackages_12` for `libcudart`/`libcublas`/`libcurand`. The CUDA runtime
libraries carry the CUDA EULA and are "unfree" in nixpkgs, so the flake imports
the nixpkgs source with `config.allowUnfree = true` set explicitly (hermetic —
no `--impure` or `NIXPKGS_ALLOW_UNFREE` needed).

### NixOS module

`module.nix` installs a systemd **socket** unit (kernel-held, ~0 memory) plus the
service. The service is started on demand when a connection arrives and — with
`autoStop = true` (default) — exits after the idle window, leaving nothing
resident between requests. The service user gets the NVIDIA device nodes via
group membership (`gpuGroups`); the host driver's `libcuda.so.1` is put on the
service's `LD_LIBRARY_PATH` via `nvidiaDriver`:

```nix
# configuration.nix
inputs.whisper-service.url = "git+file:///path/to/whisper-service";  # in your flake

{
  imports = [ (inputs.whisper-service + "/module.nix") ];
  services.whisper-service = {
    enable = true;
    package = inputs.whisper-service.packages.${system}.whisper-service;
    model = "large-v3";
    port = 8790;
    idleTimeout = 120;
    autoStop = true;
    gpuGroups = [ "video" ];
    nvidiaDriver = config.hardware.nvidia.package;
  };
}
```

## GPU access

The service auto-detects the GPU: if `ctranslate2.get_cuda_device_count() > 0` it
uses `cuda` + `float16`, otherwise it falls back to `cpu` + `int8`.

If you run this inside a sandbox/container that lacks `/dev/nvidia*` device nodes
(even though the host has an NVIDIA driver), pass the devices through — e.g. for
a bubblewrap-style jail, add to the bwrap args:

```bash
sudo bwrap --bind /dev/nvidia0 /dev/nvidia0 \
           --bind /dev/nvidiactl /dev/nvidiactl \
           --bind /dev/nvidia-uvm /dev/nvidia-uvm \
           --bind /dev/nvidia-uvm-tools /dev/nvidia-uvm-tools \
           ... <your usual bwrap args>
```

(plus `--bind /dev/dri/renderD128 /dev/dri/renderD128` if using the DRM render node)

Verify with `GET /status` → `"cuda_devices_visible": 1` and `"nvidia_smi"` showing
the GPU. `GET /status` also reports process RSS so you can watch the model come
and go.

## HTTP API

| Endpoint | Description |
|---|---|
| `POST /v1/audio/transcriptions` | OpenAI-compatible. Fields: `file` (any PyAV-decodable audio), `model`, `language`, `prompt`, `response_format` (`json`\|`verbose_json`\|`text`\|`srt`\|`vtt`), `vad_filter`, `temperature`, `beam_size` |
| `POST /audio/transcriptions` | Alias of the above — use base URL `http://host:8790` or `http://host:8790/v1` in OpenAI-compatible clients; both work |
| `GET /v1/models` | List default + locally cached models |
| `GET /status` | Residency status: loaded model, device, idle seconds, RSS, nvidia-smi line |
| `POST /load` | Pre-warm: load model into VRAM now (`model` field optional) |
| `POST /unload` | Release the model immediately |
| `GET /health` | Liveness + device summary |

Example:

```bash
curl -s http://127.0.0.1:8790/v1/audio/transcriptions \
  -F file=@audio.mp3 -F model=large-v3 -F response_format=srt
```

## CLI

```bash
whisper transcribe a.mp3 b.wav --model large-v3 --language en --format srt
whisper serve --port 8790
whisper status
whisper load --model large-v3
whisper unload
whisper fetch-model large-v3     # pre-download model into the cache
```

## Configuration (env vars)

| Var | Default | Meaning |
|---|---|---|
| `WHISPER_MODEL` | `large-v3` | default model (tiny/base/small/medium/large-v3/distil-large-v3, or a local dir) |
| `WHISPER_MODEL_DIR` | `~/.cache/whisper-service/models` | local model dir (first use downloads + converts into the HF cache) |
| `WHISPER_HF_HOME` | `~/.cache/whisper-service/hf` | HuggingFace cache root |
| `WHISPER_DEVICE` | `auto` | `auto` \| `cuda` \| `cpu` |
| `WHISPER_COMPUTE_TYPE` | `auto` | `auto` → `float16` on GPU, `int8` on CPU; or explicit |
| `WHISPER_CPU_THREADS` | `0` (auto) | CPU thread count |
| `WHISPER_IDLE_TIMEOUT` | `120` | seconds of idle before the model is unloaded (0 = never) |
| `WHISPER_KEEP_LOADED` | `false` | disable auto-unload |
| `WHISPER_AUTO_STOP` | `false` | exit the whole process (code 0) when the model is released (idle reaper or `/unload`); with systemd socket activation the service re-activates on the next request |
| `WHISPER_HOST` / `WHISPER_PORT` | `0.0.0.0` / `8790` | bind address |
| `WHISPER_MAX_CONCURRENT` | `1` | concurrent transcription slots |
| `WHISPER_MAX_UPLOAD_MB` | `2048` | upload size limit |

## Models

First transcription with a given model downloads it from HuggingFace
(`Systran/faster-whisper-<name>`, pre-converted CTranslate2 weights) into the
cache under `WHISPER_HF_HOME`. Sizes: tiny ≈ 75 MB, base ≈ 145 MB, small ≈ 485 MB,
medium ≈ 1.5 GB, large-v3 ≈ 3 GB (disk); VRAM: large-v3 fp16 ≈ 3.1 GB.

## Verified end-to-end (nix-built binaries, CPU path)

All of the following were exercised against the `nix build .#whisper-service`
output (no local Python environment involved):

- `POST /v1/audio/transcriptions` — 11 s JFK test clip, `tiny`/int8/CPU: correct
  transcript in ~1.8 s; model loaded on demand (RSS 70 MB → 263 MB, load 0.6 s)
- idle reaper — with `WHISPER_IDLE_TIMEOUT=15` the model was auto-released 16 s
  after the last use (RSS back down to ~197 MB)
- `POST /load` / `POST /unload` — explicit pre-warm and immediate release
- `whisper transcribe testdata/jfk.wav --model tiny` — one-shot CLI: load →
  transcribe → release → exit
- `whisper status` / `whisper load` / `whisper unload` — HTTP client subcommands

The GPU (CUDA) path is device-agnostic in the code and is selected automatically
when `ctranslate2.get_cuda_device_count() > 0`; it needs `/dev/nvidia*`
passthrough to verify (see above).