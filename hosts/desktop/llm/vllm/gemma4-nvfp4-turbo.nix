# Gemma 4 31B NVFP4 Turbo (RTX 5090 / Blackwell target).
#
# Manual start: `just vllm-gemma4-nvfp4-turbo` (service
# docker-vllm-gemma4-nvfp4-turbo). Never started at boot; only ever run one
# vLLM container at a time (they fight over VRAM).
{ ... }:

let
  mkVllm = import ./lib.nix;

in
{
  virtualisation.oci-containers.containers.vllm-gemma4-nvfp4-turbo = mkVllm {
    image = "docker.io/vllm/vllm-openai:cu130-nightly";

    model = "LilaRest/gemma-4-31B-it-NVFP4-turbo";

    servedName = "gemma-4-nvfp4";

    port = 8021;

    maxModelLen = 32768;

    gpuMemoryUtilization = "0.95";

    quantization = "modelopt";

    kvCacheDtype = "fp8";

    # Single dedicated card (RTX 5090 / 32GB). One long generation at a
    # time. Keep CUDA graphs enabled; eager mode pins peak memory during KV
    # cache init and OOMs at 0.95 utilization.
    extraArgs = [
      "--trust-remote-code"
      "--max-num-seqs"
      "1"
      "--max-num-batched-tokens"
      "8192"
    ];
  };
}
