{ config, pkgs, ... }:
{
  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  systemd.tmpfiles.rules = [
    "d /var/lib/vllm 0755 root root -"
    "d /var/lib/vllm/hf-cache 0755 root root -"
  ];

  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers.vllm-gemma4 = {
    image = "docker.io/vllm/vllm-openai:v0.26.0";
    autoStart = true;

    volumes = [
      "/var/lib/vllm/hf-cache:/root/.cache/huggingface"
    ];

    ports = [ "127.0.0.1:8000:8000" ];

    environment = {
      PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";
    };

    environmentFiles = [ config.age.secrets.hf-token.path ];

    cmd = [
      "--model" "cyankiwi/gemma-4-26B-A4B-it-AWQ-4bit"
      "--served-model-name" "gemma-4-26b-a4b"
      "--max-model-len" "131072"
      "--gpu-memory-utilization" "0.90"
      "--cpu-offload-gb" "0"                  # Reduced from 30; AWQ fits much better in VRAM
      "--enforce-eager"
      "--enable-prefix-caching"
      "--enable-auto-tool-choice"
      "--tool-call-parser" "gemma4"
      "--reasoning-parser" "gemma4"
      "--host" "0.0.0.0"
      "--port" "8000"
    ];

    extraOptions = [
      "--device=nvidia.com/gpu=all"
      "--ipc=host"
    ];
  };
}