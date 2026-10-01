# Gemma 4 26B AWQ fallback.
#
# Manual start: `just vllm-gemma4-awq` (service docker-vllm-gemma4-awq).
# Never started at boot; only ever run one vLLM container at a time (they
# fight over VRAM).
{ catalog, ... }:

let
  mkVllm = import ./lib.nix;

in
{
  virtualisation.oci-containers.containers.vllm-gemma4-awq = mkVllm {
    image = "docker.io/vllm/vllm-openai:v0.26.0";

    model = "cyankiwi/gemma-4-26B-A4B-it-AWQ-4bit";

    servedName = "gemma-4-awq";

    port = catalog.models.gemma4awq.port;

    maxModelLen = 262144;

    gpuMemoryUtilization = "0.90";

    # 262K-context model on a 32GB card. Keep CUDA graphs enabled so
    # vLLM frees capture scratch before KV cache allocation; eager mode
    # keeps peak memory high during init and OOMs on this card.
    extraArgs = [
      "--max-num-seqs"
      "1"
      "--max-num-batched-tokens"
      "8192"
    ];
  };
}
