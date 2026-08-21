# Seeds and hardens the root-only state tree for the "system" jail variants.
#
# The `-system` jail binaries are meant to be run via `sudo` (e.g. `sudo
# jailed-crush-system`) so they can read/write /etc/nixos. bwrap-as-root cannot
# traverse the user's 700 home dirs to bind-mount a config, so these jails keep
# their config + writable state under /var/lib/crush-system instead. That tree
# is owned by root and seeded here at build/switch time (as root), so the user's
# home activation never needs to write into root-owned state. Ordering is thus
# trivial: root seeds at switch, root-run jails read/write at runtime.
{ lib, pkgs, jail-nix, ... }:

let
  shared = import ../../home/llm/catalog.nix { inherit lib pkgs jail-nix; };
  inherit (shared) systemStateDir systemCrushConfig claudeConfig rtkRewriteHook dshSettings;
in
{
  # Root-only, root-owned state tree. Permission 0755 keeps it readable (and the
  # hook executable) but only root can create/modify files inside.
  systemd.tmpfiles.rules = [
    "d ${systemStateDir} 0755 root root - -"
    "d ${systemStateDir}/.config 0755 root root - -"
    "d ${systemStateDir}/.config/crush 0755 root root - -"
    "d ${systemStateDir}/.config/crush/hooks 0755 root root - -"
    "d ${systemStateDir}/.local 0755 root root - -"
    "d ${systemStateDir}/.local/share 0755 root root - -"
    "d ${systemStateDir}/.local/share/crush 0755 root root - -"
    "d ${systemStateDir}/.claude 0755 root root - -"
    "d ${systemStateDir}/.dsh 0755 root root - -"
  ];

  # Seed the root-owned crush.json + rtk hook at every switch, before any jail
  # runs. Runs as root because system-level activation.
  system.activationScripts.crushSystemState.text = ''
    mkdir -p \
      ${systemStateDir}/.config/crush/hooks \
      ${systemStateDir}/.local/share/crush \
      ${systemStateDir}/.claude \
      ${systemStateDir}/.dsh

    # Claude Code state file: only created if missing so session history
    # survives re-activation.
    [ -f ${systemStateDir}/.claude.json ] || echo '{}' > ${systemStateDir}/.claude.json

    cat > ${systemStateDir}/.claude/settings.json <<'CLAUDE_EOF'
    ${claudeConfig}
    CLAUDE_EOF

    cat > ${systemStateDir}/.config/crush/crush.json <<'CRUSH_EOF'
    ${systemCrushConfig}
    CRUSH_EOF

    cat > ${systemStateDir}/.config/crush/hooks/rtk-rewrite.sh <<'RTK_EOF'
    ${rtkRewriteHook}
    RTK_EOF
    chmod 0755 ${systemStateDir}/.config/crush/hooks/rtk-rewrite.sh

    # dsh user-settings document (llm-pi-ai provider routes from the shared
    # model catalog), same content as the user's ~/.dsh/settings.yaml.
    cat > ${systemStateDir}/.dsh/settings.yaml <<'DSH_EOF'
    ${dshSettings}
    DSH_EOF
  '';
}
