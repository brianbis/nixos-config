# Shared home-manager options for homes that host jailed LLM tooling: b's home
# (user jails) and the llm agent user's home (system jails, run as llm via
# `sudo -u llm`). Ensures the bubblewrap mount points exist and renders the
# per-tool configs from the shared catalog, so both homes stay identical in
# content. Imported by ./llm.nix (b) and ./agent-home.nix (llm).
{ config, lib, shared, ... }:

let
  userHome = config.home.homeDirectory;
  tool-configs = import ./configs.nix { inherit shared userHome; };
in
{
  # Ensure the jailed agents' writable dirs exist as tracked empty files so
  # home-manager creates the parent directories for us (bubblewrap mount points).
  home.file = {
    ".config/crush/.keep".text = "";
    ".local/share/crush/.keep".text = "";
    ".config/opencode/.keep".text = "";
    ".local/share/opencode/.keep".text = "";
    ".local/state/opencode/.keep".text = "";
    ".claude/.keep".text = "";
    ".dsh/.keep".text = "";
  };

  # Write the per-tool configs into $HOME. The crush config's data_directory
  # and hook paths are keyed off $HOME (see configs.nix), so the same content
  # is correct in both b's home and the llm agent user's home.
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
      $DRY_RUN_CMD printf '%s\n' '${tool-configs.crushConfig}' \
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

  # dsh's user-settings document: the llm-pi-ai provider routes rendered from
  # the shared model catalog (local backends + ninfer + DeepSeek via the
  # headroom proxies). Written as a plain file by this activation instead of a
  # home-manager store symlink: dsh's settings-file writer renames a temp file
  # over this path as a 0600 regular file, and while the path is a symlink,
  # home-manager's rename-away during activation opens a window in which dsh's
  # re-read hits ENOENT; dsh then renders only the namespace it is persisting
  # and clobbers the llm-pi-ai routes out of the file (model picker falls back
  # to deepseek-official only). A plain file that is only ever temp+renamed
  # never disappears, so dsh's reads always see a complete document and its
  # own writes preserve the routes. The cmp guard skips the rename when the
  # content is unchanged so dsh's hot-reload watcher stays quiet.
  home.activation.writeDshSettings =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p $HOME/.dsh

      $DRY_RUN_CMD printf '%s\n' '${shared.dshSettings}' \
        > $HOME/.dsh/settings.yaml.tmp
      $DRY_RUN_CMD chmod 600 $HOME/.dsh/settings.yaml.tmp
      if [ -f $HOME/.dsh/settings.yaml ] \
        && cmp -s $HOME/.dsh/settings.yaml.tmp $HOME/.dsh/settings.yaml; then
        $DRY_RUN_CMD rm -f $HOME/.dsh/settings.yaml.tmp
      else
        $DRY_RUN_CMD mv -f $HOME/.dsh/settings.yaml.tmp $HOME/.dsh/settings.yaml
      fi
    '';
}