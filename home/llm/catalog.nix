# Shared rendering for the jailed LLM tooling: single source of truth for the
# model/LSP catalogs, provider mapping, and config builders. Imported by the
# home-manager modules (user + system homes) and the doc build, so both stay identical.
{ lib, pkgs, jail-nix, ... }:

let
  jail = jail-nix.lib.init pkgs;
  users = import ../users.nix;
  # Context-compression proxy layering: local llama.cpp traffic from every
  # jailed agent (crush/opencode/aider) routes through the Headroom proxy,
  # which forwards upstream to llama-server on :8000.
  headroomPort = 8787;
  headroomProxyUrl = "http://127.0.0.1:${toString headroomPort}";
  headroomUpstreamUrl = "http://127.0.0.1:8000";

  # DeepSeek-facing headroom proxy (port 8788). Routes cloud traffic through
  # the same context-compression layer.
  headroomCloudPort = 8788;
  headroomCloudProxyUrl = "http://127.0.0.1:${toString headroomCloudPort}";
  headroomCloudUpstreamUrl = "https://api.deepseek.com/v1";

  # Claude Code-facing headroom proxy (port 8789): Claude Code speaks the
  # Anthropic Messages API, so this forwards to the local llama-server. The
  # OpenAI proxy on headroomPort can't be reused (would fall back to api.anthropic.com).
  headroomClaudePort = 8789;
  headroomClaudeProxyUrl = "http://127.0.0.1:${toString headroomClaudePort}";

  # Single source of truth for every LLM exposed to the jailed agents. Each
  # tool (crush / opencode / aider) derives its provider + model lists from
  # here, so a model edit hits all tools at once and every tool sees the same set.
  models = {
    # Local backends. Two engines, both serving the OpenAI-compatible API on
    # :8000, are mutually exclusive (start one at a time): vLLM (cached Gemma-4
    # AWQ/NVFP4 weights) and llama.cpp (Muse-Glimmer-30B GGUF).
    gemma4awq = {
      providerName = "vllm_awq";
      id = "gemma-4-awq";
      name = "Gemma 4 26B MoE AWQ";
      url = headroomProxyUrl;
      context = 262144;
      # Single-generation cap for a 32GB card. A request far beyond this
      # (e.g. 180k output) won't fit one run alongside the 17GB AWQ weights;
      # agents loop via tool calls instead.
      maxTok = 65536;
      reason = true;
      attachments = true;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    gemma4nvfp4 = {
      providerName = "vllm_nvfp4";
      id = "gemma-4-nvfp4";
      name = "Gemma 4 31B NVFP4";
      url = headroomProxyUrl;
      # Must match --max-model-len 32768 in hosts/desktop/vllm.nix.
      context = 32768;
      maxTok = 30000;
      reason = true;
      attachments = false;
      costIn = 0.14;
      costOut = 0.28;
      costInCached = 0.014;
      costOutCached = 0.28;
    };
    muse = {
      providerName = "llamacpp";
      id = "muse-glimmer-30B";
      name = "Muse-Glimmer-30B (kquant-dynamic GGUF)";
      url = headroomProxyUrl;
      # Repo advertises 131072-token context; the 18.3GiB weights on a 32GB
      # card cap effective context to ~32k with a single generation.
      context = 131072;
      maxTok = 8192;
      reason = true;
      attachments = true;
    };
    qwen38_thinking_xhigh = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-thinking-xhigh";
      name = "Qwen3.8-27B Q8_0 Thinking Xhigh";
      url = headroomProxyUrl;
      # Repo advertises 262144-token context; matches the llama.cpp router's
      # --ctx-size. The KV cache lives in system RAM (--no-kv-offload), so the
      # full context fits alongside the ~27 GiB weights on the 32 GB card.
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
    };

    qwen38_thinking_medium = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-thinking-medium";
      name = "Qwen3.8-27B Q8_0 Thinking Medium";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
    };

    qwen38_thinking_low = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-thinking-low";
      name = "Qwen3.8-27B Q8_0 Thinking Low";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
    };

    qwen38_thinking_none = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-thinking-none";
      name = "Qwen3.8-27B Q8_0 Thinking None";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
    };

    qwen38_instruct_xhigh = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-instruct-xhigh";
      name = "Qwen3.8-27B Q8_0 Instruct Xhigh";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
    };

    qwen38_instruct_medium = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-instruct-medium";
      name = "Qwen3.8-27B Q8_0 Instruct Medium";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
    };

    qwen38_instruct_low = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-instruct-low";
      name = "Qwen3.8-27B Q8_0 Instruct Low";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
    };

    qwen38_instruct_none = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-instruct-none";
      name = "Qwen3.8-27B Q8_0 Instruct None";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
    };

    qwen38heretic_q6k = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-heretic-q6_k";
      name = "Qwen3.8-27B Heretic RVN Abliterated Uncensored Q6_K";
      url = headroomProxyUrl;
      # RVN-Q6_K.gguf is ~20.6 GiB; like the base Qwen it keeps KV in system
      # RAM (no-kv-offload) so the 131072 context fits on the 32 GB card.
      context = 131072;
      maxTok = 80000;
      reason = true;
      attachments = true;
    };
    qwen38_nvfp4_ninfer = {
      providerName = "ninfer";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer";
      url = "http://127.0.0.1:8080";
      context = 240000;
      maxTok = 200000;
      reason = false;
      attachments = false;
      # Thinking levels the Qwen3.8-27B chat template supports (low/medium/xhigh).
      # Declaring them makes dsh materialize the model as a reasoning model (web
      # UI effort selector); a selected level is sent as reasoning_effort, overriding the serve default.
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
    };
    qwen36_a3b_ninfer = {
      providerName = "ninfer_a3b";
      id = "qwen3.6-35b-a3b";
      name = "Qwen3.6-35B-A3B NInfer";
      url = "http://127.0.0.1:8082";
      context = 262144;
      maxTok = 200000;
      reason = false;
      attachments = true;
      # No reasoningEfforts: the A3B chat template does not support a
      # reasoning-effort control (the engine rejects it), so the model is
      # materialized as a plain non-reasoning model.
    };
    deepseekPro = {
      providerName = "deepseek";
      id = "deepseek-v4-pro";
      name = "DeepSeek-V4-Pro";
      url = headroomCloudProxyUrl;
      context = 1048576;
      maxTok = 32768;
      reason = true;
    };
    deepseekFlash = {
      providerName = "deepseek";
      id = "deepseek-v4-flash";
      name = "DeepSeek-V4-Flash";
      url = headroomCloudProxyUrl;
      context = 1048576;
      maxTok = 32768;
      reason = true;
    };
  };

  # Map providerName (from the catalog) to the label/style each tool config
  # needs. Used only to render per-tool configs consistently.
  providerLabel = {
    llamacpp.name = "llama.cpp (local)";
    llamacpp.type = "openai-compat";
    llamacpp.api_key = "sk-local";
    vllm_awq.name = "vLLM AWQ (local)";
    vllm_awq.type = "openai-compat";
    vllm_awq.api_key = "sk-local";
    vllm_nvfp4.name = "vLLM NVFP4 (local)";
    vllm_nvfp4.type = "openai-compat";
    vllm_nvfp4.api_key = "sk-local";
    ninfer.name = "NInfer (local)";
    ninfer.type = "openai-compat";
    ninfer.api_key = "sk-local";
    ninfer_a3b.name = "NInfer A3B (local)";
    ninfer_a3b.type = "openai-compat";
    ninfer_a3b.api_key = "sk-local";
    deepseek.name = "DeepSeek";
    deepseek.type = "openai-compat";
    deepseek.api_key = "sk-local";
  };

  # LSP catalog, keyed by crush language name. Single source of truth for which
  # language server each language uses, the package to mount (host copy, shared
  # with home/packages.nix), and the file types / root markers for init.
  lsps = with pkgs; {
    nix = {
      pkg = nil;
      command = "nil";
      args = [ "--stdio" ];
      fileTypes = [ "nix" ];
      rootMarkers = [ "flake.nix" "shell.nix" "default.nix" ];
      # probe.sh sits next to .nix files and crush opens it in this workspace;
      # without this exclusion nil parses it as Nix and floods diagnostics.
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

  # Mount the host-installed LSP copies (shared with home/packages.nix) inside
  # every jail once, instead of bundling the full per-tool closure.
  lspAdds = with jail.combinators; [ (add-pkg-deps (lib.unique (map (l: l.pkg) (lib.attrValues lsps)))) ];
  # Version of the crush lsp map restricted to the languages a given tool
  # actually needs. file_types + root_markers make crush start a server only
  # when that language shows up in the mounted project.
  crushLspFor = toolLsps: lib.mapAttrs' (lang: entry:
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

  # Render a catalog model into the per-model object crush's openai-compat
  # providers expect. Optional fields (costs, attachments) are only included
  # when the catalog model defines them, so cloud models stay lean.
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

  # One crush provider per distinct upstream in the catalog, carrying that
  # upstream's base_url, key and full model list. Drives providers.deepseek
  # etc. so crush exposes exactly the catalog's models.
  crushProviders = builtins.foldl' (acc: m:
    let
      p = providerLabel.${m.providerName};
    in
    lib.recursiveUpdate acc {
      ${m.providerName} = {
        name = p.name;
        type = p.type;
        base_url = "${m.url}/v1";
        api_key = p.api_key;
        models = (acc.${m.providerName}.models or []) ++ [ (crushModelEntry m) ];
      } // lib.optionalAttrs (m.providerName == "llamacpp" && m ? thinkingBudget) {
        extra_body = { thinking_budget_tokens = m.thinkingBudget; };
      };
    }) { } allModels;

  # opencode nests providers under provider.<name> with each model keyed by id.
  # Reuse the catalog so opencode carries the same models as crush and aider.
  opencodeProvider = pname:
    let nms = byProvider pname; in
    {
      npm = "@ai-sdk/openai-compatible";
      name = providerLabel.${pname}.name;
      options.baseURL = "${(builtins.head nms).url}/v1";
      models = builtins.listToAttrs (map (m: {
        name = m.id;
        value.name = m.name;
      }) nms);
    };
  opencodeProviders = {
    provider = {
      llamacpp = opencodeProvider "llamacpp";
      vllm_awq = opencodeProvider "vllm_awq";
      vllm_nvfp4 = opencodeProvider "vllm_nvfp4";
      ninfer = opencodeProvider "ninfer";
      ninfer_a3b = opencodeProvider "ninfer_a3b";
      deepseek = opencodeProvider "deepseek";
    };
    model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
    small_model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
  };

  # dsh's user-settings document ($DSH_HOME/settings.yaml, hot-reloaded). Every
  # route names DEEPSEEK_API_KEY: pi-ai's openai-completions insists on a
  # credential even for local endpoints (which ignore the header).
  dshSettings = builtins.toJSON {
    "llm-pi-ai" = {
      providers = lib.mapAttrs' (pname: ms:
        lib.nameValuePair pname {
          displayName = providerLabel.${pname}.name;
          apiKeyEnv = "DEEPSEEK_API_KEY";
          api = "openai-completions";
          baseURL = "${(builtins.head ms).url}/v1";
          models = map (m:
             let
               # Base local-gateway compat pair (every non-deepseek route).
               # Reasoning models additionally select the deepseek wire format:
               # the only openai-completions shape that emits a top-level `reasoning_effort` (the field ninfer parses).
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
               # Expose the declared thinking levels so dsh materializes the
               # model as a reasoning model (the web UI's effort selector
               # reads this).
               reasoningEfforts = m.reasoningEfforts;
             }
           ) ms;
        })
        (lib.groupBy (m: m.providerName) allModels);
    };
    # Default agent model (dsh-agent-default-model section). This user-settings
    # layer is read live and wins over the built-in default, so new sessions
    # start on the local NVFP4 route. reasoningEffort mirrors the live settings.yaml; without it the next activation would drop the field.
    "agent-default-model" = {
      provider = models.qwen38_nvfp4_ninfer.providerName;
      model = models.qwen38_nvfp4_ninfer.id;
      reasoningEffort = "low";
    };
    # No `agent-presets` section: the user preset root cannot shadow the shipped
    # `standard` preset (first-root-wins, shipped root first), so the bundled
    # composition is patched at build time instead.
  };

  # The dsh web profile's patch layer ($DSH_HOME/profiles/web/cordis.patch.yml)
  # is a static dotfile - dotfiles/dsh/cordis.patch.yml, installed by
  # home/llm/jail-home.nix (writeDshWebProfilePatch); see its header for the why.

  # Crush PreToolUse hook that rewrites bash commands to use rtk for token
  # savings, transparently (the model still sees its original command). Requires
  # rtk and jq, both in commonPkgs so they exist inside every jailed agent.
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

  # Identity of the llm agent user (single source of truth: home/users.nix).
  # The "system" jail variants run as this user via `sudo -u llm` instead of as
  # root, keeping their config + writable state in /home/llm and editing /etc/nixos.
  agentHome = users.llm.homeDirectory;
  agentUsername = users.llm.username;

  # Render the crush config for a given state root. The user variants live
  # under $HOME (b); the system variants under the llm agent user's home.
  # Both are produced from the same shared catalogs, so content stays identical.
  crushConfigFor = base: builtins.toJSON {
    "$schema" = "https://charm.land/crush.json";

    # Force the per-project data dir out of the working directory: the system
    # jail runs crush from /etc/nixos, so without this crush would mkdir
    # /etc/nixos/.crush and the justfile's auto-stage would sweep the state into git.
    options.data_directory = "${base}/.local/share/crush";
    options.context_paths = [ "AGENTS.md" ];
    options.tui.transparent = true;
    options.tui.compact_mode = true;
    options.tui.scrollbar = "never";

    # Rewrite bash tool calls through rtk to compress token-heavy command
    # output before it reaches the model.
    hooks.PreToolUse = [
      {
        name = "rtk-rewrite";
        matcher = "^bash$";
        command = "${base}/.config/crush/hooks/rtk-rewrite.sh";
        timeout = 10;
      }
    ];

    # Headroom MCP server: exposes headroom_retrieve (plus headroom_compress /
    # headroom_stats) as callable tools so the model can turn the proxy's
    # hash= compression markers back into original content.
    mcp.headroom = {
      type = "stdio";
      command = "headroom";
      args = [ "mcp" "serve" "--proxy-url" "${headroomProxyUrl}" ];
    };

    # Language servers derived from the shared LSP catalog. Each server is
    # annotated with its file_types + root_markers, so crush only initializes a
    # server when that language actually appears in the mounted project.
    lsp = crushLspFor [ "nix" "go" "python" "typescript" "rust" "lua" "c_cpp" "bash" "json" "yaml" "markdown" "toml" "sql" ];

    # Providers derived from the shared model catalog (see `models` above), so
    # crush exposes exactly the same models as opencode and aider.
    providers = crushProviders;
  };

  # Claude Code user settings (settings.json). The env block routes the agent
  # through the Claude-facing headroom proxy to the local llama.cpp, using the
  # catalog's default local model.
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
    headroomPort
    headroomProxyUrl
    headroomUpstreamUrl
    headroomCloudPort
    headroomCloudProxyUrl
    headroomCloudUpstreamUrl
    headroomClaudePort
    headroomClaudeProxyUrl
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
    dshSettings
    rtkRewriteHook
    agentHome
    agentUsername
    crushConfigFor
    claudeConfig
    ;
}
