# Shared home-manager options for homes that host jailed LLM tooling: b's home
# (user jails) and the llm agent user's home (system jails, run as llm via
# `sudo -u llm`). Ensures the bubblewrap mount points exist and renders the
# per-tool configs from the shared catalog, so both homes stay identical in
# content. Imported by ./llm.nix (b) and ./agent-home.nix (llm).
{ config, lib, shared, ... }:

let
  userHome = config.home.homeDirectory;
  tool-configs = import ./configs.nix { inherit shared userHome; };
  # dsh web profile's patch layer: static dotfile content (see the file
  # header for the why), installed by writeDshWebProfilePatch below.
  dshWebProfilePatch = builtins.readFile ../../dotfiles/dsh/cordis.patch.yml;
  # dsh's locally-authored agent preset: a whole copy of the shipped
  # `standard` preset with the compaction summarizer's output budget raised
  # to 32768 tokens (see the dotfile header for the why). The user preset
  # root is scanned after the shipped root (first-root-wins per id), so the
  # copy cannot shadow `standard`; the default switch lives in catalog.nix's
  # dshSettings (agent-presets namespace). Installed by writeDshAgentPreset.
  dshAgentPresetFiles = {
    "agent.cordis.yml" = builtins.readFile ../../dotfiles/dsh/agent-presets/standard-compact32k/agent.cordis.yml;
    "preset.yml" = builtins.readFile ../../dotfiles/dsh/agent-presets/standard-compact32k/preset.yml;
  };
  # Embed the content as one single-quoted shell word: each embedded
  # apostrophe becomes '\'' so free-form comment text can never break the
  # script's quoting (a bare '...' embedding died on the first apostrophe).
  shellQuote = s: "'" + builtins.replaceStrings [ "'" ] [ "'\\''" ] s + "'";
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

  # dsh's web-profile patch layer ($HOME/.dsh/profiles/web/cordis.patch.yml):
  # the per-profile user layer of dsh's patch composition (bundle layers ->
  # this file -> $HOME/.dsh/cordis.patch.yml -> --patch overlays). It disables
  # the client's model-settings plugin - see the dotfile header
  # (dotfiles/dsh/cordis.patch.yml) for the why. Plain-file + cmp-guard write
  # (as in writeDshSettings): dsh
  # hot-reloads this file through its HMR watcher (which watches the nearest
  # existing ancestor, so it also picks up the file if this activation lands
  # before dsh has ever booted), and the guard keeps the watcher quiet when
  # the content is unchanged. dsh bootstraps the rest of the profile dir
  # (package.json, pnpm-workspace.yaml) on first boot and creates the patch
  # file only when missing, so this activation owns the file outright.
  home.activation.writeDshWebProfilePatch =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p $HOME/.dsh/profiles/web

      $DRY_RUN_CMD printf '%s' ${shellQuote dshWebProfilePatch} \
        > $HOME/.dsh/profiles/web/cordis.patch.yml.tmp
      if [ -f $HOME/.dsh/profiles/web/cordis.patch.yml ] \
        && cmp -s $HOME/.dsh/profiles/web/cordis.patch.yml.tmp \
          $HOME/.dsh/profiles/web/cordis.patch.yml; then
        $DRY_RUN_CMD rm -f $HOME/.dsh/profiles/web/cordis.patch.yml.tmp
      else
        $DRY_RUN_CMD mv -f $HOME/.dsh/profiles/web/cordis.patch.yml.tmp \
          $HOME/.dsh/profiles/web/cordis.patch.yml
      fi
    '';

  # dsh's locally-authored agent preset ($HOME/.dsh/.agent-presets/standard-compact32k/):
  # the user preset root dsh's roster scans for locally authored presets
  # (discovery re-reads the roots on every resolve, so no restart is needed for
  # a new session to see it). Plain-file + cmp-guard write (as in
  # writeDshSettings / writeDshWebProfilePatch): the standing preset mount
  # watches the composition file's stamp, so an unchanged-content swap would
  # churn the watcher and re-mount the preset for nothing. The preset id is a
  # directory name (PRESET_ID: lowercase alnum + dashes); the copy cannot
  # shadow the shipped `standard` (first-root-wins, shipped root first), so
  # the default switch is the agent-presets settings namespace in dshSettings.
  home.activation.writeDshAgentPreset =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p $HOME/.dsh/.agent-presets/standard-compact32k

      $DRY_RUN_CMD printf '%s' ${shellQuote dshAgentPresetFiles."agent.cordis.yml"} \
        > $HOME/.dsh/.agent-presets/standard-compact32k/agent.cordis.yml.tmp
      if [ -f $HOME/.dsh/.agent-presets/standard-compact32k/agent.cordis.yml ] \
        && cmp -s $HOME/.dsh/.agent-presets/standard-compact32k/agent.cordis.yml.tmp \
          $HOME/.dsh/.agent-presets/standard-compact32k/agent.cordis.yml; then
        $DRY_RUN_CMD rm -f $HOME/.dsh/.agent-presets/standard-compact32k/agent.cordis.yml.tmp
      else
        $DRY_RUN_CMD mv -f $HOME/.dsh/.agent-presets/standard-compact32k/agent.cordis.yml.tmp \
          $HOME/.dsh/.agent-presets/standard-compact32k/agent.cordis.yml
      fi

      $DRY_RUN_CMD printf '%s' ${shellQuote dshAgentPresetFiles."preset.yml"} \
        > $HOME/.dsh/.agent-presets/standard-compact32k/preset.yml.tmp
      if [ -f $HOME/.dsh/.agent-presets/standard-compact32k/preset.yml ] \
        && cmp -s $HOME/.dsh/.agent-presets/standard-compact32k/preset.yml.tmp \
          $HOME/.dsh/.agent-presets/standard-compact32k/preset.yml; then
        $DRY_RUN_CMD rm -f $HOME/.dsh/.agent-presets/standard-compact32k/preset.yml.tmp
      else
        $DRY_RUN_CMD mv -f $HOME/.dsh/.agent-presets/standard-compact32k/preset.yml.tmp \
          $HOME/.dsh/.agent-presets/standard-compact32k/preset.yml
      fi
    '';
}