# Shared home-manager options for the homes hosting jailed LLM tooling:
# b's home (user jails) and the llm agent user's home (system jails).
# Ensures bubblewrap mount points exist and renders per-tool configs so both homes stay identical in content.
{ config, lib, pkgs, shared, ... }:

let
  userHome = config.home.homeDirectory;
  tool-configs = import ./configs.nix { inherit shared userHome; };
  # The web-profile patch is one static file for both managed homes, so the three
  # paths that name a home (the graphify graph, graphlore's cwd, and its
  # GRAPHLORE_PROJECT_DIR) carry the @@HOME@@ token, replaced here with this home.
  dshWebProfilePatch =
    builtins.replaceStrings [ "@@HOME@@" ] [ userHome ]
      (builtins.readFile ../../dotfiles/dsh/cordis.patch.yml);
  # The home-level patch carries the same @@HOME@@ token (its MCP rows name this
  # home's graphify-out and graphlore root), so both patch layers are rendered
  # from one text with this home substituted.
  dshHomePatch =
    builtins.replaceStrings [ "@@HOME@@" ] [ userHome ]
      shared.dshHomePatch;
  searxngSearchProvider = builtins.readFile ../../dotfiles/dsh/searxng-search-provider.mjs;
  # dsh-crosstalk's compiled lib/: index.js imports its siblings by relative path,
  # so the whole module set is installed together (a partial tree fails at import).
  crosstalkLibDir = ../../dotfiles/dsh/crosstalk;
  crosstalkModules = [ "atomic" "deliver" "identity" "index" "message" "registry" "tools" "types" ];

  # Embed the content as one single-quoted shell word: each embedded
  # apostrophe becomes '\'' so free-form comment text can never break the
  # script's quoting.
  shellQuote = s: "'" + builtins.replaceStrings [ "'" ] [ "'\\''" ] s + "'";

  # One module of dsh-crosstalk's lib/: plain-file + cmp-guard write, same as
  # the other out-of-tree plugin files. Assumes <name>.js in dotfiles/dsh/crosstalk/.
  writeCrosstalkModule = n:
    let
      dest = "$HOME/.dsh/profiles/web/crosstalk/${n}.js";
      content = builtins.readFile (crosstalkLibDir + "/${n}.js");
    in ''
      $DRY_RUN_CMD printf '%s' ${shellQuote content} \
        > "${dest}.tmp"
      if [ -f "${dest}" ] \
        && cmp -s "${dest}.tmp" "${dest}"; then
        $DRY_RUN_CMD rm -f "${dest}.tmp"
      else
        $DRY_RUN_CMD mv -f "${dest}.tmp" "${dest}"
      fi
    '';
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
    ".dsh/.keep".text = "";
  };

  home.activation.writeLLMConfigs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p \
        "$HOME/.config/crush/hooks" \
        "$HOME/.config/opencode" \
        "$HOME/.local/share/opencode" \
        "$HOME/.config/headroom" \
        "$HOME/.local/share/headroom"

      # Crush rtk rewrite hook (used by the PreToolUse hook in crush.json)
      $DRY_RUN_CMD rm -f "$HOME/.config/crush/hooks/rtk-rewrite.sh"
      $DRY_RUN_CMD printf '%s\n' ${shellQuote shared.rtkRewriteHook} \
        > "$HOME/.config/crush/hooks/rtk-rewrite.sh"
      $DRY_RUN_CMD chmod +x "$HOME/.config/crush/hooks/rtk-rewrite.sh"

      # Aider
      $DRY_RUN_CMD rm -f "$HOME/.aider.conf.yml"
      $DRY_RUN_CMD printf '%s\n' ${shellQuote tool-configs.aiderConfig} > "$HOME/.aider.conf.yml"

      # Crush
      $DRY_RUN_CMD rm -f "$HOME/.config/crush/crush.json"
      $DRY_RUN_CMD printf '%s\n' ${shellQuote tool-configs.crushConfig} \
        > "$HOME/.config/crush/crush.json"

      # OpenCode
      $DRY_RUN_CMD rm -f "$HOME/.config/opencode/opencode.json"
      $DRY_RUN_CMD printf '%s\n' ${shellQuote tool-configs.opencodeConfig} \
        > "$HOME/.config/opencode/opencode.json"
    '';

  home.activation.writeDshHomePatch =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p "$HOME/.dsh"

      $DRY_RUN_CMD printf '%s' ${shellQuote dshHomePatch} \
        > "$HOME/.dsh/cordis.patch.yml.tmp"
      $DRY_RUN_CMD chmod 600 "$HOME/.dsh/cordis.patch.yml.tmp"
      if [ -f "$HOME/.dsh/cordis.patch.yml" ] \
        && cmp -s "$HOME/.dsh/cordis.patch.yml.tmp" "$HOME/.dsh/cordis.patch.yml"; then
        $DRY_RUN_CMD rm -f "$HOME/.dsh/cordis.patch.yml.tmp"
      else
        $DRY_RUN_CMD mv -f "$HOME/.dsh/cordis.patch.yml.tmp" "$HOME/.dsh/cordis.patch.yml"
      fi
      $DRY_RUN_CMD rm -f "$HOME/.dsh/settings.yaml"
    '';

  # dsh's web-profile patch layer: watched at runtime, and dsh creates the file
  # only when missing (this activation owns it outright). Plain-file + cmp-guard
  # write (as in writeDshHomePatch) keeps unchanged activations a filesystem no-op.
  home.activation.writeDshWebProfilePatch =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p "$HOME/.dsh/profiles/web"

      $DRY_RUN_CMD printf '%s' ${shellQuote dshWebProfilePatch} \
        > "$HOME/.dsh/profiles/web/cordis.patch.yml.tmp"
      if [ -f "$HOME/.dsh/profiles/web/cordis.patch.yml" ] \
        && cmp -s "$HOME/.dsh/profiles/web/cordis.patch.yml.tmp" "$HOME/.dsh/profiles/web/cordis.patch.yml"; then
        $DRY_RUN_CMD rm -f "$HOME/.dsh/profiles/web/cordis.patch.yml.tmp"
      else
        $DRY_RUN_CMD mv -f "$HOME/.dsh/profiles/web/cordis.patch.yml.tmp" "$HOME/.dsh/profiles/web/cordis.patch.yml"
      fi
    '';

  # The out-of-tree SearXNG search provider. Plain-file + cmp-guard write (as in
  # writeDshWebProfilePatch); the .mjs extension forces ESM regardless of the
  # profile package.json's `type`. Not watched at runtime — a dsh restart loads it.
  home.activation.writeDshSearxngSearchProvider =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p "$HOME/.dsh/profiles/web"

      $DRY_RUN_CMD printf '%s' ${shellQuote searxngSearchProvider} \
        > "$HOME/.dsh/profiles/web/searxng-search-provider.mjs.tmp"
      if [ -f "$HOME/.dsh/profiles/web/searxng-search-provider.mjs" ] \
        && cmp -s "$HOME/.dsh/profiles/web/searxng-search-provider.mjs.tmp" "$HOME/.dsh/profiles/web/searxng-search-provider.mjs"; then
        $DRY_RUN_CMD rm -f "$HOME/.dsh/profiles/web/searxng-search-provider.mjs.tmp"
      else
        $DRY_RUN_CMD mv -f "$HOME/.dsh/profiles/web/searxng-search-provider.mjs.tmp" "$HOME/.dsh/profiles/web/searxng-search-provider.mjs"
      fi
    '';

  # dsh-crosstalk's compiled lib/ (see the crosstalk row in the web profile patch):
  # plain-file + cmp-guard writes, same as the other out-of-tree plugin. Not watched
  # at runtime — the patch layer that mounts it is, so a rebuild lands on the next
  # dsh start.
  home.activation.writeDshCrosstalkLib =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p "$HOME/.dsh/profiles/web/crosstalk"

      ${builtins.concatStringsSep "\n" (map writeCrosstalkModule crosstalkModules)}
    '';
}
