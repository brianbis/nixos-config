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
  # `defaultModel` is that same row in the per-tool shape (id, providerName,
  # url, context, …), so every consumer that wants "the default model" — dsh's
  # session starter, the graphify and recurse launchers, the docs — reads this
  # one binding instead of naming a row of its own.
  defaultModel = catalog.defaultModel;
  gateDefaultModel = defaultModel.id;

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
        } // lib.optionalAttrs (m.providerName == "llamacpp_bonsai" && m ? thinkingBudget) {
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
    model = "${defaultModel.providerName}/${defaultModel.id}";
    small_model = "${defaultModel.providerName}/${defaultModel.id}";
  };

  # The MCP servers every agent tool gets: the four tools that ship a stdio MCP
  # server (knife, graphify, graphlore, ripwire), declared ONCE here and rendered
  # into each client's shape below, so crush/opencode/claude/dsh all serve the same
  # set. `command`/`args` are what the client spawns; `cwd`/`env` pin the project
  # root for the servers that need one.
  #
  # The graph path is ABSOLUTE, not the servers' default `graphify-out/graph.json`
  # relative to cwd: a dsh-web MCP process runs with cwd `/` (hosts/desktop/dsh-web.nix
  # sets no WorkingDirectory, so systemd defaults `/`), and the agent builds the
  # graph into $HOME/graphify-out/ (AGENTS.md), so the home is threaded through here.
  # graphlore carries its project root in `env` as well as `cwd` because crush's
  # MCPConfig has no cwd field — env is the one shape all three clients honour.
  mcpServersFor = home: {
    knife = { command = "knife"; args = [ "mcp" ]; };
    graphify = { command = "graphify-mcp"; args = [ "${home}/graphify-out/graph.json" ]; };
    graphlore = {
      command = "graphlore";
      args = [ ];
      cwd = home;
      env = { GRAPHLORE_PROJECT_DIR = home; };
    };
    ripwire = { command = "ripwire"; args = [ "--mcp" ]; };
  };

  # crush and Claude Code read the same stdio shape (type/command/args/env).
  stdioMcpFor = home: lib.mapAttrs
    (_n: s: {
      type = "stdio";
      command = s.command;
      args = s.args;
    } // lib.optionalAttrs (s ? env) { inherit (s) env; })
    (mcpServersFor home);

  # opencode's local-server shape: type "local" + command as one argv array.
  opencodeMcpFor = home: lib.mapAttrs
    (_n: s: {
      type = "local";
      command = [ s.command ] ++ s.args;
      enabled = true;
    } // lib.optionalAttrs (s ? cwd) { inherit (s) cwd; } // lib.optionalAttrs (s ? env) { environment = s.env; })
    (mcpServersFor home);

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
      # The default selection reads the shared defaultModel binding at the top of
      # this file, so it cannot drift from the gate's row; the home layer still
      # wins over the base bundle's built-in default (deepseek-official).
      # dsh refuses an effort a model does not declare (llm-pi-ai's resolveReasoningLevel throws UNSUPPORTED_REASONING_EFFORT, and a row with no reasoningEfforts materializes as non-reasoning, where the only supported level is `off`), so the effort rides only on rows that declare levels.
      defaultEffort = lib.optionalString (defaultModel ? reasoningEfforts) "\n    reasoningEffort: low";
    in
    ''
      # Managed by home-manager (writeDshHomePatch); do not edit by hand.
      - id: llm-pi-ai
        config:
          providers: ${builtins.toJSON providers}
      - id: agent-default-model
        config:
          provider: ${defaultModel.providerName}
          model: ${defaultModel.id}${defaultEffort}

      # The four code-analysis MCP servers, in dsh's profile-patch row shape. These
      # carry the SAME ids as the web profile layer (dotfiles/dsh/cordis.patch.yml),
      # so the two layers manage one setting each instead of duplicating a serverName:
      # the home-level row makes the servers visible to every profile (the TUI jail
      # `dsh`/`dshs`), and the web layer keeps the web profile's copy explicit.
      # @@HOME@@ is replaced with config.home.homeDirectory by home/llm/jail-home.nix,
      # so each home points at its own graphify-out (b: /home/b, the llm agent: /home/llm).
      - insert:
          - id: mcp-knife
            name: "@deepseek-ai/dsh-mcp-client"
            config:
              serverName: knife
              transport: stdio
              command: knife
              args: [mcp]
              cwd: !!js process.cwd()
      - insert:
          - id: mcp-graphify
            name: "@deepseek-ai/dsh-mcp-client"
            config:
              serverName: graphify
              transport: stdio
              command: graphify-mcp
              args: ["@@HOME@@/graphify-out/graph.json"]
              cwd: !!js process.cwd()
      - insert:
          - id: mcp-graphlore
            name: "@deepseek-ai/dsh-mcp-client"
            config:
              serverName: graphlore
              transport: stdio
              command: graphlore
              args: []
              cwd: @@HOME@@
              env:
                GRAPHLORE_PROJECT_DIR: @@HOME@@
      - insert:
          - id: mcp-ripwire
            name: "@deepseek-ai/dsh-mcp-client"
            config:
              serverName: ripwire
              transport: stdio
              command: ripwire
              args: [--mcp]
              cwd: !!js process.cwd()
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

    # The four code-analysis MCP servers (knife / graphify / graphlore / ripwire)
    # plus the headroom retrieval server, all in crush's stdio shape. crush's MCPConfig
    # has no cwd field, so graphlore's project root rides in `env` (GRAPHLORE_PROJECT_DIR)
    # and the graphify graph path is absolute — see mcpServersFor above.
    mcp = (stdioMcpFor base) // {
      headroom = {
        type = "stdio";
        command = "headroom";
        args = [ "mcp" "serve" "--proxy-url" "${headroomProxyUrl}" ];
      };
    };

    # Language servers derived from the shared LSP catalog; each is annotated with file_types + root_markers so crush only initializes a server when that language appears in the mounted project.
    lsp = crushLspFor [ "nix" "go" "python" "typescript" "rust" "lua" "c_cpp" "bash" "json" "yaml" "markdown" "toml" "sql" ];

    # Providers derived from the shared model catalog, so crush exposes exactly the same models as opencode and aider.
    providers = crushProviders;
  };

  # Claude Code user settings (settings.json); the env block routes the agent
  # through the Claude-facing headroom proxy, which forwards to the boot-resident
  # Bonsai llama-server (the Anthropic face is a passthrough, so it cannot sit
  # on the gate), naming that engine's own thinking row.
  claudeConfig = builtins.toJSON {
    env = {
      ANTHROPIC_BASE_URL = headroomClaudeProxyUrl;
      ANTHROPIC_AUTH_TOKEN = "sk-local";
      # The face is a passthrough to its own engine, so Claude Code names that
      # engine's thinking row — the gate's default would not exist behind it.
      ANTHROPIC_MODEL = models.bonsai2_27b_pq2_thinking.id;
      ANTHROPIC_SMALL_FAST_MODEL = models.bonsai2_27b_pq2_thinking.id;
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
    headroomClaudeUpstreamUrl
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
    mcpServersFor
    stdioMcpFor
    opencodeMcpFor
    agentHome
    agentUsername
    crushConfigFor
    claudeConfig
    defaultModel
    gateDefaultModel
    ;
}
