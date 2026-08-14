# Shared rendering for the jailed LLM tooling. Single source of truth for the
# model catalog, LSP catalog, provider mapping, and the crush config builder.
# Imported by both home/llm/default.nix (to render the per-user crush config)
# and the NixOS host module hosts/desktop/crush-system.nix (to seed the
# root-only /var/lib/crush-system state for the root-run "system" jail
# variants). Keeping this here means the user and system configs stay identical
# in content.
{ lib, pkgs, jail-nix, ... }:

let
  jail = jail-nix.lib.init pkgs;
  # Context-compression proxy layering. local llama.cpp traffic from every
  # jailed agent (crush/opencode/aider) is routed through the Headroom proxy,
  # which forwards upstream to llama-server on :8000. headroom listens on :8787.
  headroomPort = 8787;
  headroomProxyUrl = "http://127.0.0.1:${toString headroomPort}";
  headroomUpstreamUrl = "http://127.0.0.1:8000";

  # DeepSeek-facing headroom proxy (port 8788). Routes cloud traffic through
  # the same context-compression layer.
  headroomCloudPort = 8788;
  headroomCloudProxyUrl = "http://127.0.0.1:${toString headroomCloudPort}";
  headroomCloudUpstreamUrl = "https://api.deepseek.com/v1";

  # Claude Code-facing headroom proxy (port 8789). Claude Code speaks the
  # Anthropic Messages API (POST /v1/messages), so this instance forwards
  # Anthropic-format traffic to the local llama-server, which serves that endpoint
  # natively. The OpenAI-format proxy on headroomPort can't be reused: its
  # Anthropic route would fall back to api.anthropic.com.
  headroomClaudePort = 8789;
  headroomClaudeProxyUrl = "http://127.0.0.1:${toString headroomClaudePort}";

  # Single source of truth for every LLM exposed to the jailed agents. Each of
  # the three tools (crush / opencode / aider) derives its provider + model
  # lists from this catalog, so a model edit hits all tools at once (DRY) and
  # every tool always sees the same set (parity). Local models route through
  # headroomProxyUrl (llama.cpp upstream); cloud through headroomCloudProxyUrl.
  models = {
    # Local backends. Two engines, both serving the OpenAI-compatible API on
    # :8000, are mutually exclusive (start one at a time):
    #   - vLLM (hosts/desktop/vllm.nix): cached Gemma-4 AWQ/NVFP4 weights, no
    #     download needed.
    #   - llama.cpp (hosts/desktop/llamacpp.nix): Muse-Glimmer-30B GGUF.
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
    qwen38 = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0";
      name = "Qwen3.8-27B Q8_0 (GGUF)";
      url = headroomProxyUrl;
      # Repo advertises 262144-token context.
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
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
    deepseek.name = "DeepSeek";
    deepseek.type = "openai-compat";
    deepseek.api_key = "sk-local";
  };

  # LSP catalog, keyed by crush language name. Single source of truth for
  # which language server each language uses, the package to mount (host copy,
  # shared with home/packages.nix), and the file types / root markers that
  # tell crush when to actually initialize the server.
  lsps = with pkgs; {
    nix = {
      pkg = nil;
      command = "nil";
      args = [ "--stdio" ];
      fileTypes = [ "nix" ];
      rootMarkers = [ "flake.nix" "shell.nix" "default.nix" ];
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
    } // lib.optionalAttrs (entry ? args) { inherit (entry) args; }))
    (lib.filterAttrs (lang: _: builtins.elem lang toolLsps) lsps);

  # Convenience: every catalog model, and model lists filtered by upstream.
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
      deepseek = opencodeProvider "deepseek";
    };
    model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
    small_model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
  };

  # Crush PreToolUse hook that rewrites bash commands to use rtk for token
  # savings, transparently (the model still sees its original command; crush
  # substitutes the rtk-aware form before execution). Mirrors crush's official
  # docs/hooks/examples/rtk-rewrite.sh. Requires rtk >= 0.23 and jq, both of
  # which are in commonPkgs so they exist inside every jailed agent.
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

  # Root-owned state root for the "system" jail variants (run as root via
  # sudo). bwrap-as-root cannot traverse the user's 700 home dirs (e.g.
  # /home/b/.config) to bind-mount them, so the system variants keep their
  # config + data under this root-readable tree instead, seeded by the NixOS
  # host (root) so it can be root-only. Both the user and system configs are
  # rendered from the same catalogs below, so content stays identical.
  systemStateDir = "/var/lib/crush-system";

  # Render the crush config for a given state root. The user variants live
  # under $HOME; the system variants (run as root) under systemStateDir. Both
  # are produced from the same shared catalogs, so content stays identical.
  crushConfigFor = base: builtins.toJSON {
    "$schema" = "https://charm.land/crush.json";

    # Force the per-project data dir out of the working directory. The system
    # jail runs crush from /etc/nixos, which is root-owned; without this crash
    # tries to mkdir /etc/nixos/.crush and fails with "permission denied".
    # Putting state under the (rw-overlaid) state root keeps it writable in
    # both the user and system jails, and also gives each editable copy of the
    # tree a distinct data dir keyed by cwd.
    options.data_directory = "${base}/.local/share/crush";
    options.context_paths = [ "agents.md" ];

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
    # hash= compression markers back into original content. Spawned as a stdio
    # server per Crush session; connects out to the llama.cpp proxy on 8787,
    # whose compression store holds the compressed content.
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
  # catalog's default local model. Identical content is seeded for the user
  # and root-run system jail variants.
  claudeConfig = builtins.toJSON {
    env = {
      ANTHROPIC_BASE_URL = headroomClaudeProxyUrl;
      ANTHROPIC_AUTH_TOKEN = "sk-local";
      ANTHROPIC_MODEL = models.gemma4awq.id;
      ANTHROPIC_SMALL_FAST_MODEL = models.gemma4awq.id;
    };
  };

  # Per-system crush config (read by the root-run "system" jail variants).
  systemCrushConfig = crushConfigFor systemStateDir;

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
    rtkRewriteHook
    systemStateDir
    crushConfigFor
    claudeConfig
    systemCrushConfig
    ;
}
