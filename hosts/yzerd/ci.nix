{ config, lib, pkgs, ... }:

# ci — the box half of the CI/CD loop (runner script: ./ci-runner.sh;
# the door and the loop are documented in README.md, section CI box).
#
# Chicken-and-egg stated honestly: declaring experimental-features here lands
# in the generation being built, so the FIRST flake-eval on a fresh box cannot
# come from this file — it comes from the install flow (the live stick's nix
# already speaks flakes). After the generation that carries this line boots,
# the box evaluates and builds its own repo natively, and `ci` — installed in
# the same generation — can do the work.

{
  # flake CLI + flakes for every later nix call on the box (same option
  # hosts/desktop/host.nix pins).
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Persistent daemon-side build cap, sized for THIS box (32 cores / ~125 GB,
  # NO swap — the desktop's 4/4 is a small-box OOM fix, not a fact here; the
  # strata coder is VRAM-resident on the 4090 and does not fight these jobs).
  nix.settings.max-jobs = 8;

  # Tools the runner needs, measured absent on the running box's PATH
  # (2026-10-29 probe over the LAN ssh door: git and jq missing; curl, patch,
  # diff, tar already present — python3 deliberately not installed, the loop
  # is bash+jq).
  environment.systemPackages = [
    pkgs.git
    pkgs.jq
    # The runner reads straight from the repo, so the script is a repo
    # artifact: edit ./ci-runner.sh, the generation follows. writeShellScriptBin
    # prepends a store-bash shebang (verified in the rendered output), so the
    # interpreter never depends on what /bin/sh or PATH happens to be.
    (pkgs.writeShellScriptBin "ci" (builtins.readFile ./ci-runner.sh))
  ];

  # State dir: gate logs + the last-green CD pointer. Owner b (uid 1000, wheel
  # with NOPASSWD sudo) — the runner runs as b, so the checkout's git ownership
  # and the profile's writer agree. Nothing here is ever executed by the CI
  # itself: deploying last-green is the human door (README).
  systemd.tmpfiles.rules = [
    "d /var/lib/nixos-ci 0775 b - -"
  ];
}
