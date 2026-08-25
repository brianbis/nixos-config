# Shared home-manager options for the homes hosting jailed LLM tooling:
# b's home (user jails) and the llm agent user's home (system jails).
# Ensures bubblewrap mount points exist and renders per-tool configs so both homes stay identical in content.
{ config, lib, shared, ... }:

let
  userHome = config.home.homeDirectory;
  tool-configs = import ./configs.nix { inherit shared userHome; };
  dshWebProfilePatch = builtins.readFile ../../dotfiles/dsh/cordis.patch.yml;
  searxngSearchProvider = builtins.readFile ../../dotfiles/dsh/searxng-search-provider.mjs;
  # Embed the content as one single-quoted shell word: each embedded
  # apostrophe becomes '\'' so free-form comment text can never break the
  # script's quoting.
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

  # dsh watches this file at runtime and publishes empty settings while it is
  # missing, so the cmp guard keeps an unchanged activation a filesystem no-op
  # instead of a delete/add swap that would churn dsh's settings state.
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

  # dsh's web-profile patch layer: watched at runtime, and dsh creates the file
  # only when missing (this activation owns it outright). Plain-file + cmp-guard
  # write (as in writeDshSettings) keeps unchanged activations a filesystem no-op.
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

  # The out-of-tree SearXNG search provider. Plain-file + cmp-guard write (as in
  # writeDshWebProfilePatch); the .mjs extension forces ESM regardless of the
  # profile package.json's `type`. Not watched at runtime — a dsh restart loads it.
  home.activation.writeDshSearxngSearchProvider =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p $HOME/.dsh/profiles/web

      $DRY_RUN_CMD printf '%s' ${shellQuote searxngSearchProvider} \
        > $HOME/.dsh/profiles/web/searxng-search-provider.mjs.tmp
      if [ -f $HOME/.dsh/profiles/web/searxng-search-provider.mjs ] \
        && cmp -s $HOME/.dsh/profiles/web/searxng-search-provider.mjs.tmp \
          $HOME/.dsh/profiles/web/searxng-search-provider.mjs; then
        $DRY_RUN_CMD rm -f $HOME/.dsh/profiles/web/searxng-search-provider.mjs.tmp
      else
        $DRY_RUN_CMD mv -f $HOME/.dsh/profiles/web/searxng-search-provider.mjs.tmp \
          $HOME/.dsh/profiles/web/searxng-search-provider.mjs
      fi
    '';
}
