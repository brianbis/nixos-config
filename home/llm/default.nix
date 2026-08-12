# Jailed LLM tooling (crush/opencode/aider) home-manager module. Assembles the
# jail packages, the per-user tool configs, the user-level activation that
# writes configs into $HOME, and the headroom proxy user services.
#
# The shared model/LSP catalog lives in ./catalog.nix (single source of truth,
# also used by hosts/desktop/crush-system.nix to seed the root-only
# /var/lib/crush-system state for the sudo-run "system" jail variants).
{ config, lib, pkgs, jail-nix, llm-agents, deepseekSecret, shared, ... }:

let
  userHome = config.home.homeDirectory;

  jail-config = import ./jails.nix {
    inherit lib pkgs jail-nix llm-agents deepseekSecret shared userHome;
  };
  tool-configs = import ./configs.nix {
    inherit shared userHome;
  };
  services = import ./services.nix {
    inherit lib pkgs shared;
    headroomDeepseekWrapper = jail-config.headroomDeepseekWrapper;
  };
in
{
  home.packages = jail-config.jails;

  # Ensure the jailed agents' writable dirs exist as tracked empty files so
  # home-manager creates the parent directories for us (bubblewrap mount points).
  home.file = {
    ".config/crush/.keep".text = "";
    ".local/share/crush/.keep".text = "";
    ".config/opencode/.keep".text = "";
    ".local/share/opencode/.keep".text = "";
    ".local/state/opencode/.keep".text = "";
    ".claude/.keep".text = "";
  };

  # Write the per-user (non-sudo) crush/aider/opencode/claude configs only. The
  # root-only /var/lib/crush-system tree is seeded separately by the NixOS
  # host module (hosts/desktop/crush-system.nix), so a user-level activation
  # never needs to write into root-owned state.
  home.activation.writeLLMConfigs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p \
        $HOME/.config/crush/hooks \
        $HOME/.config/opencode \
        $HOME/.local/share/opencode \
        $HOME/.config/headroom \
        $HOME/.local/share/headroom \
        $HOME/.claude

      # Crush rtk rewrite hook (used by the PreToolUse hook in crush.json)
      $DRY_RUN_CMD rm -f $HOME/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD printf '%s\n' '${shared.rtkRewriteHook}' \
        > $HOME/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD chmod +x $HOME/.config/crush/hooks/rtk-rewrite.sh

      # Aider
      $DRY_RUN_CMD rm -f $HOME/.aider.conf.yml
      $DRY_RUN_CMD printf '%s\n' '${tool-configs.aiderConfig}' > $HOME/.aider.conf.yml

      # Crush
      $DRY_RUN_CMD rm -f $HOME/.config/crush/crush.json
      $DRY_RUN_CMD printf '%s\n' '${tool-configs.userCrushConfig}' \
        > $HOME/.config/crush/crush.json

      # OpenCode
      $DRY_RUN_CMD rm -f $HOME/.config/opencode/opencode.json
      $DRY_RUN_CMD printf '%s\n' '${tool-configs.opencodeConfig}' \
        > $HOME/.config/opencode/opencode.json

      # Claude Code (settings.json routes it through the Claude-facing
      # headroom proxy to local llama.cpp; state file only created if missing so
      # session history survives re-activation)
      $DRY_RUN_CMD [ -f $HOME/.claude.json ] || printf '{}\n' > $HOME/.claude.json
      $DRY_RUN_CMD rm -f $HOME/.claude/settings.json
      $DRY_RUN_CMD printf '%s\n' '${tool-configs.claudeConfig}' \
        > $HOME/.claude/settings.json
  '';

  systemd.user.services = services.systemd.user.services;
}
