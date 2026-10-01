# LensVLM-9B (RTX 5090 / Blackwell target). Manual start: `just vllm-lensvlm`
# (service docker-vllm-lensvlm). Never started at boot; only ever run one vLLM
# container at a time (they fight over VRAM).
#
# LensVLM is Apple's 9B vision-language model (a finetune of Qwen3.5-9B,
# qwen3_5 architecture) for selective context expansion over compressed
# document images. Served from the BARE apple/LensVLM-9B repo — full bf16
# weights (18.8 GiB), no quantization.
#
# The checkpoint is fetched declaratively (pkgs.fetchurl, pinned sha256 per
# file) and assembled into a store dir the container mounts read-only — so the
# source tree fully describes the input and there is no runtime HF download
# inside the container (the same pattern as K2-Horizon / Bonsai). The image is
# pinned by manifest digest (the cu130-nightly tag is a rolling tag; the digest
# makes the pull reproducible).
#
# VRAM math on the single 32 GB card: 18.8 GiB bf16 weights + ~1.5 GiB CUDA
# context leaves ~10 GiB for the KV cache at 0.95 utilization. The KV is fp8
# (64 KB/token: 2 x 32 layers x 4 KV heads x 256 head-dim x 1 byte), so the
# 131072 context fits with headroom; the model's full 262144 would need ~16 GiB
# of fp8 KV and is not guaranteed.
{ pkgs, catalog, ... }:

let
  mkVllm = import ./lib.nix;

  repo = "apple/LensVLM-9B";

  # Every file vLLM needs from the checkpoint, pinned by sha256 (the HF LFS
  # sha256 for the safetensors / tokenizer; the plain sha256 for the small
  # config / chat-template files).
  files = [
    { name = "model.safetensors"; sha256 = "fc6305126b47349db0c14061200e6bc1b930c3a19eee7338921eaca2b28f1e87"; }
    { name = "tokenizer.json"; sha256 = "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"; }
    { name = "config.json"; sha256 = "017d47371f51fd9fb9e5c9fac53e818a9f21054f1575762136e83ff8a29400af"; }
    { name = "generation_config.json"; sha256 = "387c1eac8643dd3ec2cffd5d644dda9db9ef6bd57b4d90e727c263230aafe6fa"; }
    { name = "processor_config.json"; sha256 = "e1dc40819c68945b2d6f2416f52a05c68b2d1d14ba31cadf71942cc467cc2438"; }
    { name = "tokenizer_config.json"; sha256 = "1c165873046362b4da3716131a1077dfc4c0403185def25e24902be8a48e9845"; }
    { name = "chat_template.jinja"; sha256 = "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"; }
  ];

  # Fixed-output fetch per file (pinned sha256), then assemble the store dir
  # with the exact basenames vLLM expects.
  fetch = f: pkgs.fetchurl {
    url = "https://huggingface.co/${repo}/resolve/main/${f.name}";
    sha256 = f.sha256;
    name = f.name;
  };

  modelsDir = pkgs.runCommand "lensvlm-9b-models" { } (
    "mkdir -p $out\n"
    + builtins.concatStringsSep "" (map (f: "cp ${fetch f} $out/${f.name}\n") files)
    + "chmod 0644 $out/*\n"
  );

in
{
  virtualisation.oci-containers.containers.vllm-lensvlm = mkVllm {
    # Pinned by manifest digest (Docker Hub tag cu130-nightly, fetched
    # 2026-07-08): the tag is rolling, the digest is not.
    image = "docker.io/vllm/vllm-openai@sha256:3dbe092ec5b2cef63b6104d33fa75d6ce53a7870962529ada69f78bbbc38e776";

    # Local dir (the mounted store dir), not an HF repo name — no runtime
    # download.
    model = "/models/lensvlm";

    servedName = "lensvlm-9b";

    port = catalog.models.lensvlm.port;

    maxModelLen = 131072;

    gpuMemoryUtilization = "0.95";

    kvCacheDtype = "fp8";

    # Qwen3.5 parsers (the model card's base architecture; the Qwen3.5-9B vLLM
    # recipe uses --reasoning-parser qwen3).
    reasoningParser = "qwen3";
    toolCallParser = "qwen3_coder";

    # Mount the declaratively-fetched store dir read-only; replaces the shared
    # HF-cache volume (no runtime HF download).
    volumes = [ "${modelsDir}:/models/lensvlm:ro" ];

    # Single dedicated card. One long generation at a time.
    extraArgs = [
      "--trust-remote-code"
      "--max-num-seqs"
      "1"
      "--max-num-batched-tokens"
      "8192"
    ];
  };
}
