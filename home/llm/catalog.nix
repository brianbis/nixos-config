# Shared rendering for the jailed LLM tooling. The catalog itself is DATA: the fleet table lives in ../../catalog/default.nix and the helpers that turn it into per-consumer shapes live in ../../catalog/lib.nix. This file only renders the per-tool configs (crush / opencode / aider / dsh) from that data, so a model, a port, or a systemd unit name is declared exactly once.
# Imported by the home-manager modules (user + system homes) and the doc build, so both stay identical.
{ lib, pkgs, jail-nix, ... }:

let
  jail = jail-nix.lib.init pkgs;
  users = import ../users.nix;

  # Single source of truth. ../../catalog/default.nix is pure data (the port
  # ledger, provider groups, one row per model, the gate policy);
  # ../../catalog/lib.nix is pure functions over it. Change a model, a port,
  # or a unit name THERE, never here.
  catalog = import ../../catalog/lib.nix lib (import ../../catalog/default.nix);

  # The historical per-model shape the renderers below read (providerName,
  # url, costIn/costOut/...). Every local model's `url` is now the ONE public
  # face — the gate on the ledger's gate port — instead of a per-engine port.
  models = catalog.legacyModels;
  providerLabel = catalog.providerLabel;
  providerNames = catalog.providerNames;

  # The context-compression fronts (Headroom) and the gate face, kept under
  # their historical names because home/llm/services.nix, agents-manifest.nix
  # and the tool configs below all read them.
  inherit (catalog)
    gatePort
    gateUrl
    headroomPort
    headroomProxyUrl
    headroomUpstreamUrl
    headroomCloudPort
    headroomCloudProxyUrl
    headroomCloudUpstreamUrl
    headroomClaudePort
    headroomClaudeProxyUrl
    headroomClaudeUpstreamUrl
    headroomNinferPort
    headroomNinferProxyUrl
    headroomNinferUpstreamUrl
    headroomNvidiaPort
    headroomNvidiaProxyUrl
    headroomNvidiaUpstreamUrl
    ;

  # The default row the gate loads when nothing is resident and a request names
  # no model — exposed so docs/consumers can name it without repeating an id.
  gateDefaultModel = catalog.gate.default.id;

  # LSP catalog, keyed by crush language name: which language server each language uses, the package to mount (host copy, shared with home/packages.nix), and the file types / root markers for init.
  lsps = with pkgs; {
    nix = {
      pkg = nil;
      command = "nil";
      args = [ "--stdio" ];
      fileTypes = [ "nix" ];
      rootMarkers = [ "flake.nix" "shell.nix" "default.nix" ];
      # probe.sh sits next to .nix files and crush opens it in this workspace; without this exclusion nil parses it as Nix and floods diagnostics.
      initOptions = {
        nil = {
          diagnostics.excludedFiles = [ "hosts/desktop/hushmic/probe.sh" ];
        };
      };
    };
    go = {
      pkg = gopls;
      command = "gopls";
      fileTypes = [ "go" ];
      rootMarkers = [ "go.mod" "go.work" "Godeps" ];
    };
    python = {
      pkg = pyright;
      command = "pyright-langserver";
      args = [ "--stdio" ];
      fileTypes = [ "py" "pyi" ];
      rootMarkers = [ "pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile" ".venv" ];
    };
    typescript = {
      pkg = typescript-language-server;
      command = "typescript-language-server";
      args = [ "--stdio" ];
      fileTypes = [ "ts" "tsx" "js" "jsx" ];
      rootMarkers = [ "package.json" "tsconfig.json" "jsconfig.json" ];
    };
    rust = {
      pkg = rust-analyzer;
      command = "rust-analyzer";
      fileTypes = [ "rs" ];
      rootMarkers = [ "Cargo.toml" ];
    };
    lua = {
      pkg = lua-language-server;
      command = "lua-language-server";
      fileTypes = [ "lua" ];
      rootMarkers = [ ".luarc.json" ".luacheckrc" ];
    };
    c_cpp = {
      pkg = clang-tools;
      command = "clangd";
      fileTypes = [ "c" "cc" "cpp" "h" "hpp" ];
      rootMarkers = [ "CMakeLists.txt" "compile_commands.json" "Makefile" ];
    };
    bash = {
      pkg = bash-language-server;
      command = "bash-language-server";
      args = [ "start" ];
      fileTypes = [ "sh" "bash" ];
      rootMarkers = [ ".bashrc" ".bash_profile" ];
    };
    json = {
      pkg = vscode-langservers-extracted;
      command = "vscode-json-language-server";
      args = [ "--stdio" ];
      fileTypes = [ "json" "jsonc" ];
      rootMarkers = [ "package.json" "tsconfig.json" "composer.json" ];
    };
    yaml = {
      pkg = vscode-langservers-extracted;
      command = "yaml-language-server";
      args = [ "--stdio" ];
      fileTypes = [ "yaml" "yml" ];
      rootMarkers = [ ".yamllint" ];
    };
    markdown = {
      pkg = marksman;
      command = "marksman";
      args = [ "server" ];
      fileTypes = [ "md" "mdx" ];
      rootMarkers = [ ".marksman.toml" ];
    };
    toml = {
      pkg = taplo;
      command = "taplo";
      args = [ "lsp" "stdio" ];
      fileTypes = [ "toml" ];
      rootMarkers = [ ".taplo.toml" ];
    };
    sql = {
      pkg = sqls;
      command = "sqls";
      fileTypes = [ "sql" ];
      rootMarkers = [ ".sqls.json" ];
    };
  };

  # Mount the host-installed LSP copies (shared with home/packages.nix) inside every jail once, instead of bundling the full per-tool closure.
  lspAdds = with jail.combinators; [ (add-pkg-deps (lib.unique (map (l: l.pkg) (lib.attrValues lsps)))) ];
  # The crush lsp map restricted to the languages a given tool needs; file_types + root_markers make crush start a server only when that language shows up in the mounted project.
  crushLspFor = toolLsps: lib.mapAttrs'
    (lang: entry:
      lib.nameValuePair lang ({
        inherit (entry) command;
        file_types = entry.fileTypes;
        root_markers = entry.rootMarkers;
      }
      // lib.optionalAttrs (entry ? args) { inherit (entry) args; }
      // lib.optionalAttrs (entry ? initOptions) { init_options = entry.initOptions; }))
    (lib.filterAttrs (lang: _: builtins.elem lang toolLsps) lsps);

  allModels = lib.attrValues models;
  byProvider = name: lib.filter (m: m.providerName == name) allModels;

  # Render a catalog model into the per-model object crush's openai-compat providers expect; optional fields (costs, attachments) are only included when defined, so cloud models stay lean.
  crushModelEntry = m:
    {
      id = m.id;
      name = m.name;
      context_window = m.context;
      default_max_tokens = m.maxTok;
      can_reason = m.reason;
    } // lib.optionalAttrs (m ? attachments) { supports_attachments = m.attachments; }
    // lib.optionalAttrs (m ? costIn) {
      cost_per_1m_in = m.costIn;
      cost_per_1m_out = m.costOut;
      cost_per_1m_in_cached = m.costInCached;
      cost_per_1m_out_cached = m.costOutCached;
    };

  # One crush provider per distinct upstream in the catalog (base_url, key, full model list), so crush exposes exactly the catalog's models.
  crushProviders = builtins.foldl'
    (acc: m:
      let
        p = providerLabel.${m.providerName};
      in
      lib.recursiveUpdate acc {
        ${m.providerName} = {
          name = p.name;
          type = p.type;
          base_url = "${m.url}/v1";
          api_key = p.api_key;
          models = (acc.${m.providerName}.models or [ ]) ++ [ (crushModelEntry m) ];
        } // lib.optionalAttrs (m.providerName == "llamacpp" && m ? thinkingBudget) {
          extra_body = { thinking_budget_tokens = m.thinkingBudget; };
        };
      })
    { }
    allModels;

  # opencode nests providers under provider.<name> with each model keyed by id; reuse the catalog so opencode carries the same models as crush and aider.
  opencodeProvider = pname:
    let nms = byProvider pname; in
    {
      npm = "@ai-sdk/openai-compatible";
      name = providerLabel.${pname}.name;
      options.baseURL = "${(builtins.head nms).url}/v1";
      models = builtins.listToAttrs (map
        (m: {
          name = m.id;
          value.name = m.name;
        })
        nms);
    };
  opencodeProviders = {
    # Every provider group the table uses, derived — a new engine needs no edit
    # here. (The old hand-list omitted strata_coder and carried a
    # `vllm_dflash2_direct` twin that only existed to dodge opencode's
    # one-baseURL-per-provider rule; the gate makes that twin unnecessary.)
    provider = lib.genAttrs providerNames (opencodeProvider);
    model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
    small_model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
  };

  # dsh's home user layer ($DSH_HOME/cordis.patch.yml, hot-reloaded). rc.2 removed the standalone user-settings document ($DSH_HOME/settings.yaml): user settings now live in the profile patch layers, and this home-level layer applies above every profile (web/tui/headless), so one file serves them all. Every route names DEEPSEEK_API_KEY: pi-ai's openai-completions insists on a credential even for local endpoints.
  dshHomePatch =
    let
      providers = lib.mapAttrs'
        (pname: ms:
          lib.nameValuePair pname {
            displayName = providerLabel.${pname}.name;
            apiKeyEnv = "DEEPSEEK_API_KEY";
            api = "openai-completions";
            baseURL = "${(builtins.head ms).url}/v1";
            models = map
              (m:
                let
                  # Base local-gateway compat pair (every non-deepseek route); reasoning models additionally select the deepseek wire format (the only openai-completions shape that emits a top-level `reasoning_effort`).
                  compat =
                    (if pname == "deepseek" then { } else {
                      supportsDeveloperRole = false;
                      maxTokensField = "max_tokens";
                    })
                    // (if m ? reasoningEfforts then {
                      thinkingFormat = "deepseek";
                      supportsReasoningEffort = true;
                    } else { });
                in
                {
                  id = m.id;
                  name = m.name;
                  contextWindow = m.context;
                  maxTokens = m.maxTok;
                }
                // lib.optionalAttrs (compat != { }) { inherit compat; }
                // lib.optionalAttrs (m ? reasoningEfforts) {
                  # Expose the declared thinking levels so dsh materializes the model as a reasoning model (the web UI's effort selector reads this).
                  reasoningEfforts = m.reasoningEfforts;
                }
              )
              ms;
          })
        (lib.groupBy (m: m.providerName) allModels);
      # Default agent model: the home layer wins over the base bundle's built-in default (deepseek-official), so new sessions start on the local NVFP4 route.
      defaultModel = models.qwen38_nvfp4_ninfer;
    in
    ''
      # Managed by home-manager (writeDshHomePatch); do not edit by hand.
      - id: llm-pi-ai
        config:
          providers: ${builtins.toJSON providers}
      - id: agent-default-model
        config:
          provider: ${defaultModel.providerName}
          model: ${defaultModel.id}
          reasoningEffort: low
    '';

  # The dsh web profile's patch layer ($DSH_HOME/profiles/web/cordis.patch.yml) is a static dotfile (dotfiles/dsh/cordis.patch.yml), installed by home/llm/jail-home.nix (writeDshWebProfilePatch).

  # Crush PreToolUse hook that rewrites bash commands to use rtk for token savings, transparently (the model still sees its original command); requires rtk and jq, both in commonPkgs.
  rtkRewriteHook = ''
    #!/usr/bin/env bash
    set -euo pipefail

    if ! command -v jq &>/dev/null; then
      exit 0
    fi
    if ! command -v rtk &>/dev/null; then
      exit 0
    fi
    CMD="''${CRUSH_TOOL_INPUT_COMMAND:-}"
    if [ -z "$CMD" ]; then
      exit 0
    fi

    REWRITTEN=$(rtk rewrite "$CMD" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?

    case $EXIT_CODE in
    0 | 3)
      [ "$CMD" = "$REWRITTEN" ] && exit 0
      jq -n --arg cmd "$REWRITTEN" \
        "{\"decision\":\"allow\",\"updated_input\":({\"command\":\$cmd}|tostring)}"
      ;;
    *)
      exit 0
      ;;
    esac
  '';

  # Identity of the llm agent user (single source of truth: home/users.nix); the "system" jail variants run as this user via `sudo -u llm` instead of root.
  agentHome = users.llm.homeDirectory;
  agentUsername = users.llm.username;

  # Render the crush config for a given state root (user variants under $HOME, system variants under the llm agent user's home); both from the same shared catalogs, so content stays identical.
  crushConfigFor = base: builtins.toJSON {
    "$schema" = "https://charm.land/crush.json";

    # Force the per-project data dir out of the working directory: the system jail runs crush from /etc/nixos, so without this it would mkdir /etc/nixos/.crush and the justfile's auto-stage would sweep the state into git.
    options.data_directory = "${base}/.local/share/crush";
    options.context_paths = [ "AGENTS.md" ];
    options.tui.transparent = true;
    options.tui.compact_mode = true;
    options.tui.scrollbar = "never";

    # Rewrite bash tool calls through rtk to compress token-heavy command output before it reaches the model.
    hooks.PreToolUse = [
      {
        name = "rtk-rewrite";
        matcher = "^bash$";
        command = "${base}/.config/crush/hooks/rtk-rewrite.sh";
        timeout = 10;
      }
    ];

    # Headroom MCP server: exposes headroom_retrieve (plus headroom_compress / headroom_stats) as callable tools so the model can turn the proxy's hash= compression markers back into original content.
    mcp.headroom = {
      type = "stdio";
      command = "headroom";
      args = [ "mcp" "serve" "--proxy-url" "${headroomProxyUrl}" ];
    };

    # Language servers derived from the shared LSP catalog; each is annotated with file_types + root_markers so crush only initializes a server when that language appears in the mounted project.
    lsp = crushLspFor [ "nix" "go" "python" "typescript" "rust" "lua" "c_cpp" "bash" "json" "yaml" "markdown" "toml" "sql" ];

    # Providers derived from the shared model catalog, so crush exposes exactly the same models as opencode and aider.
    providers = crushProviders;
  };

  # Claude Code user settings (settings.json); the env block routes the agent through the Claude-facing headroom proxy to the local llama.cpp, using the catalog's default local model.
  claudeConfig = builtins.toJSON {
    env = {
      ANTHROPIC_BASE_URL = headroomClaudeProxyUrl;
      ANTHROPIC_AUTH_TOKEN = "sk-local";
      ANTHROPIC_MODEL = models.gemma4awq.id;
      ANTHROPIC_SMALL_FAST_MODEL = models.gemma4awq.id;
    };
  };

in
{
  inherit
    gatePort
    gateUrl
    headroomPort
    headroomProxyUrl
    headroomUpstreamUrl
    headroomCloudPort
    headroomCloudProxyUrl
    headroomCloudUpstreamUrl
    headroomClaudePort
    headroomClaudeProxyUrl
    headroomNinferPort
    headroomNinferProxyUrl
    headroomNinferUpstreamUrl
    headroomNvidiaPort
    headroomNvidiaProxyUrl
    headroomNvidiaUpstreamUrl
    models
    providerLabel
    lsps
    lspAdds
    crushLspFor
    allModels
    byProvider
    crushModelEntry
    crushProviders
    opencodeProvider
    opencodeProviders
    dshHomePatch
    rtkRewriteHook
    agentHome
    agentUsername
    crushConfigFor
    claudeConfig
    gateDefaultModel
    ;
}
