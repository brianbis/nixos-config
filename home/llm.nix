{ config, lib, pkgs, jail-nix, llm-agents, deepseekSecret, ... }:

let
    jail = jail-nix.lib.init pkgs;

  # The user's real home directory, pinned at build time. The jails must not
  # depend on the runtime $HOME because the "system" variants are run via sudo
  # for /etc/nixos write access, and sudo resets $HOME to /root. If we let
  # bind mounts resolve ~ at runtime they'd all point at /root and bwrap would
  # fail ("Can't find source path /root/.config/crush"). Hardcoding the real
  # home here means every jailed tool sees the same config regardless of how
  # it's invoked.
  userHome = config.home.homeDirectory;

  # Root-owned state root for the "system" jail variants (run as root via
  # sudo). bwrap-as-root cannot traverse the user's 700 home dirs (e.g.
  # /home/b/.config) to bind-mount them, so the system variants keep their
  # config + data under this root-readable tree instead. The configs are all
  # rendered from the same shared catalogs below, so this copy stays identical
  # in content to the per-user one under $HOME.
  systemStateDir = "/var/lib/crush-system";

  # Context-compression proxy layering. local vLLM traffic from every jailed
  # agent (crush/opencode/aider) is routed through the Headroom proxy, which
  # forwards upstream to vLLM on :8000. headroom listens on :8787.
  # vLLM-facing headroom proxy (port 8787) -- local model only.
  headroomPort = 8787;
  headroomProxyUrl = "http://127.0.0.1:${toString headroomPort}";
  headroomUpstreamUrl = "http://127.0.0.1:8000";

  # DeepSeek-facing headroom proxy (port 8788). Routes cloud traffic through
  # the same context-compression layer; API key is injected at the proxy from
  # the agenix secret, so jailed agents never hold the cloud key.
  headroomCloudPort = 8788;
  headroomCloudProxyUrl = "http://127.0.0.1:${toString headroomCloudPort}";
  headroomCloudUpstreamUrl = "https://api.deepseek.com/v1";

  # Single source of truth for every LLM exposed to the jailed agents. Each of
  # the three tools (crush / opencode / aider) derives its provider + model
  # lists from this catalog, so a model edit hits all tools at once (DRY) and
  # every tool always sees the same set (parity). Local models route through
  # headroomProxyUrl (vLLM upstream); cloud through headroomCloudProxyUrl.
  models = {
    gemma4awq = {
      providerName = "vllm";
      id = "gemma-4-awq";
      name = "Gemma 4 26B MoE AWQ";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 196608;
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
      name = "Gemma 4 31B NVFP4 Turbo";
      url = headroomProxyUrl;
      context = 98304;
      maxTok = 90000;
      reason = true;
      attachments = false;
      costIn = 0.14;
      costOut = 0.28;
      costInCached = 0.014;
      costOutCached = 0.28;
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
    vllm.name = "vLLM (local)";
    vllm.type = "openai-compat";
    vllm.api_key = "sk-local";
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
  # tell crush when to actually initialize the server. Each jailed agent on
  # startup only initializes servers whose language is present in the mounted
  # project, so we don't eagerly boot every language server.
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
  # every jail once, instead of bundling the full per-tool closure. Each tool
  # derives from the same base so the LSP set stays in one place.
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
      vllm = opencodeProvider "vllm";
      vllm_nvfp4 = opencodeProvider "vllm_nvfp4";
      deepseek = opencodeProvider "deepseek";
    };
    model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
    small_model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
  };

  # Wrapper that reads the DeepSeek key from the agenix secret at runtime and
  # hands it to headroom via the extra-headers option.
  headroomDeepseekWrapper = pkgs.writeShellScriptBin "headroom-deepseek" ''
    KEY="''$(cat ${deepseekSecret} | tr -d '\n')"
    HEADER="{\"Authorization\":\"Bearer $KEY\"}"
    exec ${pkgs.headroom}/bin/headroom proxy \
      --openai-api-url ${headroomCloudUpstreamUrl} \
      --openai-extra-headers "$HEADER" \
      --host 127.0.0.1 --port ${toString headroomCloudPort}
  '';

  withDeepSeekKey = pkg: name:
    pkgs.writeShellScriptBin name ''
      export DEEPSEEK_API_KEY="$(cat /run/agenix/deepseek-api-key)"
      export OPENAI_API_KEY="$DEEPSEEK_API_KEY"
      exec ${pkg}/bin/${name} "$@"
    '';

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
  commonPkgs = with pkgs; [
    bashInteractive
    curl
    wget
    jq
    git
    which
    ripgrep
    gnugrep
    gawkInteractive
    ps
    findutils
    gzip
    unzip
    gnutar
    diffutils
    strace
    openssl
    cfr
    tcpdump
    mitmproxy
    jdk21

    # rtk: Rust Token Killer, compresses noisy command output before it hits
    # the context window, usable by any jailed agent (in nixpkgs).
    rtk
    # headroom: context optimization layer that compresses everything an agent
    # reads. Not in nixpkgs / llm-agents; built from ./packages/headroom.nix.
    headroom

    # Database CLI clients shared by every jailed tool.
    sqlite
    postgresql
    mariadb.client

    (python3.withPackages (ps: [
      ps.cryptography
      ps.dnslib
      ps.requests
    ]))
  ];

  # Base jail options: user (cwd, no /etc/nixos) vs system (/etc/nixos rw).
  # The shared LSP set (host-installed copies, from the `lsps` catalog) is
  # mounted here, once per jail, so we don't bundle a fresh per-tool closure.
  baseJailOptions = system: with jail.combinators; [
    network
    time-zone
    no-new-session
    # Pin HOME to the user's real home (not the invoking shell's $HOME, which
    # sudo would reset to /root). This keeps fwd-env HOME and all the ~/ bind
    # mounts below in agreement no matter how the jail is launched.
    (set-env "HOME" (if system then systemStateDir else userHome))
  ] ++ (if system
    then [ (readwrite "/etc/nixos") (readwrite systemStateDir) ]
    else [ mount-cwd ]) ++ [ (readonly "/run/agenix/deepseek-api-key") ] ++ lspAdds;

  # Common libs/CLI tools injected into every jail.
  mkToolJail = { name, pkg, dirs, system }:
    jail "jailed-${name}${if system then "-system" else ""}"
      pkg
      (with jail.combinators;
        baseJailOptions system ++
        dirs ++
        [ (add-pkg-deps commonPkgs) ]);

  # Per-tool read/write dirs. Paths are absolute under userHome because
  # us-and-sudo must see identical mounts; a runtime ~ would diverge (sudo
  # resets $HOME to /root).
  mkDirs = paths: map (with jail.combinators; p: readwrite p) paths;
  aiderDirs = mkDirs [
    "${userHome}/.config/aider"
    "${userHome}/.aider.conf.yml"
    "${userHome}/.gitconfig"
  ];
  crushDirs = mkDirs [
    "${userHome}/.config/crush"
    "${userHome}/.local/share/crush"
  ];
  opencodeDirs = mkDirs [
    "${userHome}/.config/opencode"
    "${userHome}/.local/share/opencode"
    "${userHome}/.local/state/opencode"
  ];

  # System (root-run) variants keep their writable state under systemStateDir
  # instead of the user's home, because bwrap-as-root cannot traverse the
  # user's 700 home dirs to bind-mount them here. The configs/data are seeded
  # there by the home activation (see writeLLMConfigs).
  systemCrushDirs = mkDirs [
    "${systemStateDir}/.config"
    "${systemStateDir}/.local/share"
  ];

  agent = n: llm-agents.packages.${pkgs.system}.${n};

  # Jailed crush is already sandboxed by bubblewrap, so strip the hardcoded
  # network/download + network-config command bans from bash.go. The jail is
  # the real security boundary; the blocklist is redundant here and blocks
  # legitimate local work (curl health checks, service probes, etc.).
  crushUnbanned = (agent "crush").overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      sed -i \
        -e '/"alias",/d' -e '/"aria2c",/d' -e '/"axel",/d' -e '/"chrome",/d' \
        -e '/"curl",/d' -e '/"curlie",/d' -e '/"firefox",/d' \
        -e '/"http-prompt",/d' -e '/"httpie",/d' -e '/"links",/d' \
        -e '/"lynx",/d' -e '/"nc",/d' -e '/"safari",/d' -e '/"scp",/d' \
        -e '/"ssh",/d' -e '/"telnet",/d' -e '/"w3m",/d' -e '/"wget",/d' \
        -e '/"xh",/d' -e '/"firewall-cmd",/d' -e '/"ifconfig",/d' \
        -e '/"ip",/d' -e '/"iptables",/d' -e '/"netstat",/d' \
        -e '/"pfctl",/d' -e '/"route",/d' -e '/"ufw",/d' \
        internal/agent/tools/bash.go
      # Hardcoded in the system prompt template (tool_usage), separate from the
      # bash.go blocklist. Remove the stale "never use curl in bash" instruction
      # too, since the jail is the real boundary and we allow curl.
      sed -i \
        -e '/Never use `curl` through the bash tool/d' \
        internal/agent/templates/coder.md.tpl
    '';
  });

  # Build a (user, system) jail pair for a tool.
  # tool = { name, pkg, dirs, systemDirs ? [ ] }
  # When systemDirs is given it replaces the user's home dirs (so bwrap-as-root
  # never has to traverse $HOME, which is 700); otherwise the system variant
  # reuses the same dirs as the user variant.
  makeTool = { name, pkg, dirs, systemDirs ? [ ] }:
    [
      (mkToolJail { inherit name pkg dirs; system = false; })
      (mkToolJail { inherit name pkg; dirs = if systemDirs == [ ] then dirs else systemDirs; system = true; })
    ];

  jails =
    makeTool { name = "aider"; pkg = pkgs.aider-chat; dirs = aiderDirs;
               systemDirs = [ (with jail.combinators; (readonly deepseekSecret)) ]; }
    ++ makeTool {
         name = "crush";
         pkg = withDeepSeekKey crushUnbanned "crush";
         dirs = crushDirs;
         systemDirs = systemCrushDirs;
       }
    ++ makeTool { name = "opencode"; pkg = withDeepSeekKey (agent "opencode") "opencode"; dirs = opencodeDirs; };
  aiderConfig = ''
      # Local vLLM OpenAI-compatible endpoint via the Headroom proxy
      openai-api-base: ${headroomProxyUrl}/v1
      openai-api-key: ${providerLabel.${models.gemma4awq.providerName}.api_key}

      # Convenient local model shortcuts (from the shared model catalog)
      alias:
        awq: "${models.gemma4awq.providerName}/${models.gemma4awq.id}"
        nvfp4: "${models.gemma4nvfp4.providerName}/${models.gemma4nvfp4.id}"

      # DeepSeek cloud endpoint via the Headroom proxy
      deepseek-api-base: ${headroomCloudProxyUrl}/v1
      deepseek-api-key: ${providerLabel.deepseek.api_key}

      # Cloud model shortcuts (from the shared model catalog)
      alias:
        pro: "${models.deepseekPro.providerName}/${models.deepseekPro.id}"
        flash: "${models.deepseekFlash.providerName}/${models.deepseekFlash.id}"

      # Better autonomous coding workflow
      auto-commits: true
      dirty-commits: true

      # Avoid attribution noise
      attribute-author: false
      attribute-committer: false
    '';


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
    # server per Crush session; connects out to the vLLM proxy on 8787, whose
    # compression store holds the compressed content. Crush will surface the
    # tools as mcp__headroom__headroom_retrieve, etc.
    mcp.headroom = {
      type = "stdio";
      command = "headroom";
      args = [ "mcp" "serve" "--proxy-url" "${headroomProxyUrl}" ];
    };

    # Language servers derived from the shared LSP catalog. Each server is
    # annotated with its file_types + root_markers, so crush only initializes a
    # server when that language actually appears in the mounted project (no
    # eager start of every language server on launch).
    lsp = crushLspFor [ "nix" "go" "python" "typescript" "rust" "lua" "c_cpp" "bash" "json" "yaml" "markdown" "toml" "sql" ];

    # Providers derived from the shared model catalog (see `models` above), so
    # crush exposes exactly the same models as opencode and aider.
    providers = crushProviders;
  };

  # Per-user crush config (read by the non-sudo jail variants).
  userCrushConfig = crushConfigFor userHome;

  # Per-system crush config (read by the root-run "system" jail variants).
  systemCrushConfig = crushConfigFor systemStateDir;

  opencodeConfig = builtins.toJSON (opencodeProviders // {
    "$schema" = "https://opencode.ai/config.json";
  });

in
{
  home.packages = jails;
    home.activation.writeLLMConfigs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p \
        $HOME/.config/crush/hooks \
        $HOME/.config/opencode \
        $HOME/.local/share/opencode \
        $HOME/.config/headroom \
        $HOME/.local/share/headroom

      # Also seed the root-readable system-state tree (see systemStateDir).
      # It is owned by the user (tmpfiles rule in hosts/desktop/default.nix)
      # so this user-level activation can write it, yet it lives under
      # /var/lib so bwrap-as-root can mount it without traversing $HOME.
      $DRY_RUN_CMD mkdir -p \
        ${systemStateDir}/.config/crush/hooks \
        ${systemStateDir}/.local/share/crush

      # Crush rtk rewrite hook (used by the PreToolUse hook in crush.json)
      $DRY_RUN_CMD rm -f $HOME/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD printf '%s\n' '${rtkRewriteHook}' \
        > $HOME/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD chmod +x $HOME/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD rm -f ${systemStateDir}/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD printf '%s\n' '${rtkRewriteHook}' \
        > ${systemStateDir}/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD chmod +x ${systemStateDir}/.config/crush/hooks/rtk-rewrite.sh

      # Aider
      $DRY_RUN_CMD rm -f $HOME/.aider.conf.yml
      $DRY_RUN_CMD printf '%s\n' '${aiderConfig}' > $HOME/.aider.conf.yml


      # Crush
      $DRY_RUN_CMD rm -f $HOME/.config/crush/crush.json
      $DRY_RUN_CMD printf '%s\n' '${userCrushConfig}' \
        > $HOME/.config/crush/crush.json
      $DRY_RUN_CMD rm -f ${systemStateDir}/.config/crush/crush.json
      $DRY_RUN_CMD printf '%s\n' '${systemCrushConfig}' \
        > ${systemStateDir}/.config/crush/crush.json

      # OpenCode
      $DRY_RUN_CMD rm -f $HOME/.config/opencode/opencode.json
      $DRY_RUN_CMD printf '%s\n' '${opencodeConfig}' \
        > $HOME/.config/opencode/opencode.json
  '';

  # headroom context-compression proxy. Always-on so jailed agents'
  # local vLLM traffic flows through it without any manual step.
  systemd.user.services.headroom-proxy = {
    Unit = {
      Description = "Headroom context-compression proxy (vLLM upstream)";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${pkgs.headroom}/bin/headroom proxy " +
        "--openai-api-url ${headroomUpstreamUrl} " +
        "--host 127.0.0.1 --port ${toString headroomPort}";
      Restart = "on-failure";
      RestartSec = "3";
      WorkingDirectory = "%h/.local/share/headroom";
      Environment = "HOME=%h";
    };

    Install.WantedBy = [ "default.target" ];
  };

  # headroom context-compression proxy for DeepSeek (cloud). Uses a wrapper
  # that reads the API key from the agenix secret at service start.
  systemd.user.services.headroom-proxy-deepseek = {
    Unit = {
      Description = "Headroom context-compression proxy (DeepSeek upstream)";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${headroomDeepseekWrapper}/bin/headroom-deepseek";
      Restart = "on-failure";
      RestartSec = "3";
      WorkingDirectory = "%h/.local/share/headroom";
      Environment = "HOME=%h";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
