# vLLM containers (docker backend): one module per model checkpoint.
#
#   gemma4-nvfp4-turbo.nix  Gemma 4 31B NVFP4 Turbo (manual start)
#   gemma4-awq.nix          Gemma 4 26B AWQ fallback (manual start)
#   qwen38-dflash2.nix      Qwen3.8-27B NVFP4 + DFlash2 K7 (socket-activated
#                           on-demand start; pinned release artifacts)
#
# Shared bits (docker enable, nvidia-container-toolkit, the /var/lib/vllm
# cache dirs, the ephemeral HF_TOKEN env file) live here; per-model
# checkpoints, containers, and services live in the per-model files.
{ config, lib, pkgs, ... }:

{
  imports = [
    ./gemma4-nvfp4-turbo.nix
    ./gemma4-awq.nix
    ./qwen38-dflash2.nix
  ];

  virtualisation.docker.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  virtualisation.oci-containers.backend = "docker";

  systemd.tmpfiles.rules = [
    "d /var/lib/vllm 0755 root root -"
    # The gemma containers (root) and the DFlash2 container (uid 2000) both
    # use the shared hf-cache; 2000:0 works for both (root can write anything).
    #
    # The DFlash2 container runs as uid 2000 (the image's vllm user) and must
    # WRITE its HF and vLLM/Triton caches. Docker auto-creates a missing
    # bind-mount source as root:root, and the `d` type does not re-own a
    # directory that already exists — so a root-owned dir left behind by an
    # earlier run makes the container's cache writes fail with EACCES (seen as
    # PermissionError on …/.cache/vllm/triton at startup). These tmpfiles rules
    # create the dirs at boot (`d`) and re-own any pre-existing root-owned dir
    # to uid 2000, gid 0 (`z`); they run at boot, not on every activation. Note
    # tmpfiles.d takes user and group as SEPARATE fields, so the rule reads
    # `2000 0` — writing `2000:0` makes systemd try to resolve a *username*
    # "2000:0" and fail ("Failed to resolve user '2000:0'"), silently leaving the
    # dir un-owned-by-2000. The start-time guarantee — the one that actually
    # matters for this on-demand container — is the ExecStartPre in
    # ./qwen38-dflash2.nix, which re-owns the dirs as root immediately before
    # every `docker run`.
    "d /var/lib/vllm/hf-cache 0755 2000 0 -"
    "z /var/lib/vllm/hf-cache 0755 2000 0 -"
    "d /var/lib/vllm/vllm-cache 0755 2000 0 -"
    "z /var/lib/vllm/vllm-cache 0755 2000 0 -"
    # Ephemeral (tmpfs) home for the runtime HF_TOKEN env file. The secret is
    # already decrypted to tmpfs by agenix; this derived file is no more
    # persistent than that.
    "d /run/vllm 0755 root root -"
  ];

  # The hf-token secret is a bare token value (e.g. "hf_…"), not KEY=VALUE, so
  # environmentFiles (which only parses KEY=VALUE lines) would apply nothing
  # and the containers would run unauthenticated. Re-format it as HF_TOKEN=…
  # into an ephemeral env file the containers' environmentFiles points at.
  # 0600 root: the secret is already on tmpfs via agenix, so this adds no new
  # exposure. Re-written at every activation (idempotent).
  system.activationScripts.vllmHfTokenEnv.text = ''
    set -euo pipefail
    mkdir -p /run/vllm
    printf 'HF_TOKEN=%s\n' "$(cat ${config.age.secrets.hf-token.path} | tr -d '\n')" > /run/vllm/hf-token.env
    chmod 0600 /run/vllm/hf-token.env
  '';
}
