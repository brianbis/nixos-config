# Factory for the on-demand vLLM containers (see ./default.nix).
#
# Each container is a NixOS oci-containers definition (docker backend) that is
# not started at boot: the gemma containers are started manually (`just
# vllm-gemma4-*`), and the DFlash2 container is started by its socket-activated
# idle wrapper (../idle-wrapper/vllm_wrapper.py) on the first request.
{
  image
, model
, servedName
, port
, maxModelLen
, gpuMemoryUtilization ? null
, quantization ? null
, kvCacheDtype ? null
, extraArgs ? [ ]
  # Parsers default to gemma4 (the existing containers); the DFlash2
  # container passes the qwen3 / qwen3_coder parsers.
, toolCallParser ? "gemma4"
, reasoningParser ? "gemma4"
  # Docker `--pull` policy. "missing" (the default) pulls only when the image
  # is absent locally — a last-resort safety net for containers whose image
  # is pulled at activation time.
, pull ? "missing"
  # Extra volumes. When empty, the shared hf-cache mount is used (the gemma
  # containers); the DFlash2 container supplies its own mount set.
, volumes ? [ ]
  # Extra environment, merged over the base.
, environment ? { }
  # Optional --chat-template (container path) and --speculative-config
  # (JSON string).
, chatTemplate ? null
, speculativeConfig ? null
, shmSize ? "32g"
,
}:

let
  quantArgs =
    if quantization != null
    then [
      "--quantization"
      quantization
    ]
    else [ ];

  kvArgs =
    if kvCacheDtype != null
    then [
      "--kv-cache-dtype"
      kvCacheDtype
    ]
    else [ ];

  gpuMemArgs =
    if gpuMemoryUtilization != null
    then [
      "--gpu-memory-utilization"
      gpuMemoryUtilization
    ]
    else [ ];

  chatArgs =
    if chatTemplate != null
    then [
      "--chat-template"
      chatTemplate
    ]
    else [ ];

  specArgs =
    if speculativeConfig != null
    then [
      "--speculative-config"
      speculativeConfig
    ]
    else [ ];

  effectiveVolumes =
    if volumes == [ ]
    then [
      "/var/lib/vllm/hf-cache:/root/.cache/huggingface"
    ]
    else volumes;

in
{
  inherit image pull;

  autoStart = false;

  volumes = effectiveVolumes;

  ports = [
    "127.0.0.1:${toString port}:8000"
  ];

  environment = {
    PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";
  }
  // environment;

  # The hf-token secret is a bare token value (not KEY=VALUE), so pointing
  # environmentFiles directly at it would set no HF_TOKEN and the container
  # would run unauthenticated. The activation script writes a
  # properly-formatted HF_TOKEN=… env file; point at that instead.
  environmentFiles = [
    "/run/vllm/hf-token.env"
  ];

  cmd =
    [
      "--model"
      model
      "--served-model-name"
      servedName

      "--max-model-len"
      (toString maxModelLen)

      "--enable-prefix-caching"

      "--enable-auto-tool-choice"
      "--tool-call-parser"
      toolCallParser
      "--reasoning-parser"
      reasoningParser

      "--host"
      "0.0.0.0"
      "--port"
      "8000"
    ]
    ++ gpuMemArgs
    ++ quantArgs
    ++ kvArgs
    ++ chatArgs
    ++ specArgs
    ++ extraArgs;

  # --shm-size, not --ipc=host: vLLM passes tensors between engine
  # processes via /dev/shm (Docker's 64m default is too small); a
  # private shm avoids sharing the host IPC namespace.
  extraOptions = [
    "--device=nvidia.com/gpu=all"
    "--shm-size=${shmSize}"
  ];
}