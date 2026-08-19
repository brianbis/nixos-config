{ config, ... }:

let
  mkVllm = {
    image,
    model,
    servedName,
    port,
    maxModelLen,
    gpuMemoryUtilization ? "0.90",
    quantization ? null,
    kvCacheDtype ? null,
    extraArgs ? [],
  }:

  let
    quantArgs =
      if quantization != null
      then [
        "--quantization" quantization
      ]
      else [];

    kvArgs =
      if kvCacheDtype != null
      then [
        "--kv-cache-dtype" kvCacheDtype
      ]
      else [];

  in {
    inherit image;

    autoStart = false;

    volumes = [
      "/var/lib/vllm/hf-cache:/root/.cache/huggingface"
    ];

    ports = [
      "127.0.0.1:${toString port}:8000"
    ];

    environment = {
      PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";
    };

    environmentFiles = [
      config.age.secrets.hf-token.path
    ];

    cmd =
      [
        "--model" model
        "--served-model-name" servedName

        "--max-model-len" (toString maxModelLen)
        "--gpu-memory-utilization" gpuMemoryUtilization

        "--enable-prefix-caching"

        "--enable-auto-tool-choice"
        "--tool-call-parser" "gemma4"
        "--reasoning-parser" "gemma4"

        "--host" "0.0.0.0"
        "--port" "8000"
      ]
      ++ quantArgs
      ++ kvArgs
      ++ extraArgs;

    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--ipc=host"
      "--shm-size=32g"
    ];
  };

in
{
  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  systemd.tmpfiles.rules = [
    "d /var/lib/vllm 0755 root root -"
    "d /var/lib/vllm/hf-cache 0755 root root -"
  ];

  virtualisation.oci-containers.backend = "docker";

  virtualisation.oci-containers.containers = {

    # Gemma 4 31B NVFP4 Turbo (RTX 5090 / Blackwell target)
    vllm-gemma4-nvfp4-turbo = mkVllm {
      image = "docker.io/vllm/vllm-openai:cu130-nightly";

      model = "LilaRest/gemma-4-31B-it-NVFP4-turbo";

      servedName = "gemma-4-nvfp4";

      port = 8000;

      maxModelLen = 32768;

      gpuMemoryUtilization = "0.95";

      quantization = "modelopt";

      kvCacheDtype = "fp8";

      # Single dedicated card (RTX 5090 / 32GB). One long generation at a
      # time. Keep CUDA graphs enabled; eager mode pins peak memory during KV
      # cache init and OOMs at 0.95 utilization.
      extraArgs = [
        "--trust-remote-code"
        "--max-num-seqs" "1"
        "--max-num-batched-tokens" "8192"
      ];
    };


    # Gemma 4 26B AWQ fallback
    vllm-gemma4-awq = mkVllm {
      image = "docker.io/vllm/vllm-openai:v0.26.0";

      model = "cyankiwi/gemma-4-26B-A4B-it-AWQ-4bit";

      servedName = "gemma-4-awq";

      port = 8000;

      maxModelLen = 262144;

      gpuMemoryUtilization = "0.90";

      # 262K-context model on a 32GB card. Keep CUDA graphs enabled so
      # vLLM frees capture scratch before KV cache allocation; eager mode
      # keeps peak memory high during init and OOMs on this card.
      extraArgs = [
        "--max-num-seqs" "1"
        "--max-num-batched-tokens" "8192"
      ];
    };

  };
}