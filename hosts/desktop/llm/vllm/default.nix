# vLLM model servers: one module per model checkpoint.
#
#   gemma4-nvfp4-turbo.nix  Gemma 4 31B NVFP4 Turbo (docker, manual start)
#   gemma4-awq.nix          Gemma 4 26B AWQ fallback (docker, manual start)
#   qwen38-dflash2.nix      Qwen3.8-27B NVFP4 + DFlash2 K7 (NATIVE process,
#                           socket-activated on-demand; pinned release
#                           artifacts)
#   k2horizon-nvfp4.nix     K2-Horizon-MoVA-36B-A4B NVFP4 (docker, manual
#                           start; pinned vLLM nightly — k2_horizon is not in
#                           a release yet)
#   lensvlm.nix             LensVLM-9B bf16 (docker, manual start; bare
#                           apple/LensVLM-9B repo, full-size weights)
#
# The Gemma and K2-Horizon checkpoints run as docker containers (docker
# enable, nvidia-container-toolkit, the oci-containers backend). The DFlash2
# engine is a native process (see ./qwen38-dflash2.nix + ./dflash2-package.nix)
# and needs no container runtime. The shared /var/lib/vllm cache dirs and the
# ephemeral HF_TOKEN env file live here; per-model checkpoints and services
# live in the per-model files.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./gemma4-nvfp4-turbo.nix
    ./gemma4-awq.nix
    ./qwen38-dflash2.nix
    ./k2horizon-nvfp4.nix
    ./lensvlm.nix
  ];

  # Docker is still required for the Gemma containers.
  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.oci-containers.backend = "docker";

  systemd.tmpfiles.rules = [
    "d /var/lib/vllm 0755 root root -"
    # Shared HF + vLLM/Triton caches. Every consumer now runs as root: the
    # Gemma docker containers run as root, and the native DFlash2 process runs
    # as root (the old DFlash2 container ran as the image's uid 2000 and needed
    # the 2000:0 re-ownership dance; that is gone with the container). root
    # ownership works for all of them.
    "d /var/lib/vllm/hf-cache 0755 root root -"
    "d /var/lib/vllm/vllm-cache 0755 root root -"
    # Ephemeral (tmpfs) home for the runtime HF_TOKEN env file. The secret is
    # already decrypted to tmpfs by agenix; this derived file is no more
    # persistent than that.
    "d /run/vllm 0755 root root -"
  ];

  # The hf-token secret is a bare token value (e.g. "hf_…"), not KEY=VALUE, so
  # environmentFiles (which only parses KEY=VALUE lines) would apply nothing
  # and the consumers would run unauthenticated. Re-format it as HF_TOKEN=…
  # into an ephemeral env file the download services / native service point at.
  # 0600 root: the secret is already on tmpfs via agenix, so this adds no new
  # exposure. Re-written at every activation (idempotent).
  system.activationScripts.vllmHfTokenEnv.text = ''
    set -euo pipefail
    mkdir -p /run/vllm
    printf 'HF_TOKEN=%s\n' "$(cat ${config.age.secrets.hf-token.path} | tr -d '\n')" > /run/vllm/hf-token.env
    chmod 0600 /run/vllm/hf-token.env
  '';
}
