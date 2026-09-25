# K2-Horizon-MoVA-36B-A4B NVFP4 (RTX 5090 / Blackwell target). Manual start:
# `just vllm-k2horizon-nvfp4` (service docker-vllm-k2horizon-nvfp4). Never
# started at boot; only ever run one vLLM container at a time (they fight over
# VRAM).
#
# The k2_horizon architecture (K2HorizonForCausalLM) merged into vLLM main on
# 2026-09-03 (PR #55063) but is not in a release yet, so this pins the exact
# nightly the NVFP4 checkpoint was validated on. The checkpoint is plain
# compressed-tensors NVFP4 (the 13,500 routed expert projections are NVFP4;
# everything else stays BF16), so vLLM auto-detects the quantization (no
# --quantization flag). The model is a 36B MoE / 4B-active Mixture-of-Values
# model; the ~19 GiB NVFP4 weights fit the single 32 GB card.
#
# The checkpoint is fetched declaratively (pkgs.fetchurl, pinned sha256 per
# file) and assembled into a store dir the container mounts read-only — so the
# source tree fully describes the input and there is no runtime HF download
# inside the container (the same pattern as the Bonsai model).
#
# Note: the checkpoint README's `docker run` example omits the `cu129-` prefix
# from the nightly tag; the real Docker Hub tag is the prefixed one below.
{ pkgs, ... }:

let
  mkVllm = import ./lib.nix;

  repo = "primitive-ai/K2-Horizon-MoVA-36B-A4B-NVFP4";

  # Every file in the checkpoint, pinned by sha256 (the HF LFS sha256 for the
  # safetensors / tokenizer; the plain-git sha256 for the small config /
  # modeling / chat-template files).
  files = [
    { name = "model-00001-of-00008.safetensors"; sha256 = "1e49f4c3ba5e73d5e487d38d25950b775a877e5e7e5c01da6448e6f1cb135368"; }
    { name = "model-00002-of-00008.safetensors"; sha256 = "de2b25faa0b371a6fa113e1cf35e2ae88a8364381d02e085741945c8e1cfb501"; }
    { name = "model-00003-of-00008.safetensors"; sha256 = "121b0683c8af953cd667ac749caccdbf9c8e50ef3d8713c493e7426bb0ca0d43"; }
    { name = "model-00004-of-00008.safetensors"; sha256 = "22b6dfc7b3614e622b7554e9a44c453e89519aa8586e8d0a1f90d7480b0ffde9"; }
    { name = "model-00005-of-00008.safetensors"; sha256 = "9aa065012dd4a1a0e9d5d336bb55b2fdee921261b29ade17fd96a7f208ab68ee"; }
    { name = "model-00006-of-00008.safetensors"; sha256 = "3a246a6acf7587587dd7266905a19bef0ce8d12d4a83486faab2911d4f85d099"; }
    { name = "model-00007-of-00008.safetensors"; sha256 = "5852223b353001902a4ff00c623c505939c925288f465c6680a179e26427711f"; }
    { name = "model-00008-of-00008.safetensors"; sha256 = "4ec0d8a8c40fdceca9116a2c772b7cff4d191fe11f7ee8fcb97fef5e0a3ce7d8"; }
    { name = "model.safetensors.index.json"; sha256 = "10b378b3ffbcc6d0829e2d43695d523db43b39d661677095d3bfddb0d1dd46fa"; }
    { name = "config.json"; sha256 = "3b6e89146072ec2dd986818bf95f2cb957c23e640d7c2c9b573a08610e69caa8"; }
    { name = "configuration_k2_horizon.py"; sha256 = "5c2f993c1053d9462ebea6dea416c897fddfbb4a5edd904e486936b20d4badc5"; }
    { name = "generation_config.json"; sha256 = "ead28160201f3e3fbdc4ecaf6aab431807a7fb7eea1747fb1735e7cfc0a5f6a2"; }
    { name = "modeling_k2_horizon.py"; sha256 = "fb09e010956bd51cfa7d4055b4381cff34c9e06164066b49e3546f38b2e6242f"; }
    { name = "special_tokens_map.json"; sha256 = "e9be461abfcb63da71fb65db470e075682e7573e469cc658aeeb6632a6144ae1"; }
    { name = "tokenizer.json"; sha256 = "53d6dc22c1d38cb292e09784f7d40a7ec8706dc4532f3eed3f5fcdccd929f977"; }
    { name = "tokenizer_config.json"; sha256 = "068cfdcf2bcef44fd77f935a9fb41b4d45af547fd41b95079817bd40b24fe518"; }
    { name = "chat_template.jinja"; sha256 = "a892cd0b0195599f283a8c706787520d9a6747640efb2f4dec4144b0abb62590"; }
  ];

  # Fixed-output fetch per file (pinned sha256), then assemble the store dir
  # with the exact basenames vLLM expects.
  fetch = f: pkgs.fetchurl {
    url = "https://huggingface.co/${repo}/resolve/main/${f.name}";
    sha256 = f.sha256;
    name = f.name;
  };

  modelsDir = pkgs.runCommand "k2horizon-nvfp4-models" { } (
    "mkdir -p $out\n"
    + builtins.concatStringsSep "" (map (f: "cp ${fetch f} $out/${f.name}\n") files)
    + "chmod 0644 $out/*\n"
  );

in
{
  virtualisation.oci-containers.containers.vllm-k2horizon-nvfp4 = mkVllm {
    image = "docker.io/vllm/vllm-openai:cu129-nightly-8a728663c1c3eeace834a95f5654fa653cc1998c";

    # Local dir (the mounted store dir), not an HF repo name — no runtime
    # download.
    model = "/models/k2horizon";

    servedName = "k2-horizon-mova-36b-a4b-nvfp4";

    port = 8020;

    maxModelLen = 80000;

    gpuMemoryUtilization = "0.85";

    # K2-Horizon reasoning + tool-call parsers (the model card's recommended
    # parsers; the BF16 vLLM example uses both).
    reasoningParser = "k2_horizon";
    toolCallParser = "k2_horizon";

    # Mount the declaratively-fetched store dir read-only; replaces the shared
    # HF-cache volume (no runtime HF download).
    volumes = [ "${modelsDir}:/models/k2horizon:ro" ];

    extraArgs = [
      "--trust-remote-code"
      "--max-num-seqs"
      "1"
      "--max-num-batched-tokens"
      "8192"
      # The NVFP4 weights are 35 GiB — larger than the 32 GB card — so spill
      # expert weights to system RAM. 16 GiB offloaded leaves ~19 GiB on-GPU
      # (within the 0.85 budget) with headroom for the CUDA context + KV cache.
      "--cpu-offload-gb"
      "44"
    ];
  };
}
