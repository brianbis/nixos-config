{ config, lib, pkgs, jail-nix, llm-agents, deepseekSecret, ... }:

let
    jail = jail-nix.lib.init pkgs;

  # Context-compression proxy layering. local vLLM traffic from every jailed
  # agent (crush/opencode/aider) is routed through the Headroom proxy, which
  # forwards upstream to vLLM on :8000. headroom listens on :8787.
  headroomPort = 8787;
  headroomProxyUrl = "http://127.0.0.1:${toString headroomPort}";
  headroomUpstreamUrl = "http://127.0.0.1:8000";

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

    (python3.withPackages (ps: [
      ps.cryptography
      ps.dnslib
      ps.requests
    ]))
  ];

  # Base jail options: user (cwd, no /etc/nixos) vs system (/etc/nixos rw).
  baseJailOptions = system: with jail.combinators; [
    network
    time-zone
    no-new-session
  ] ++ (if system
    then [ (readwrite "/etc/nixos") ]
    else [ mount-cwd ]) ++ [ (readonly "/run/agenix/deepseek-api-key") ];

  # Common libs/CLI tools injected into every jail.
  mkToolJail = { name, pkg, dirs, system }:
    jail "jailed-${name}${if system then "-system" else ""}"
      pkg
      (with jail.combinators;
        baseJailOptions system ++
        dirs ++
        [ (add-pkg-deps commonPkgs) ]);

  # Per-tool read/write dirs.
  aiderDirs = with jail.combinators; [
    (readwrite (noescape "~/.config/aider"))
    (readwrite (noescape "~/.aider.conf.yml"))
    (readwrite (noescape "~/.gitconfig"))
  ];
  crushDirs = with jail.combinators; [
    (readwrite (noescape "~/.config/crush"))
    (readwrite (noescape "~/.local/share/crush"))
  ];
  opencodeDirs = with jail.combinators; [
    (readwrite (noescape "~/.config/opencode"))
    (readwrite (noescape "~/.local/share/opencode"))
    (readwrite (noescape "~/.local/state/opencode"))
  ];

  agent = n: llm-agents.packages.${pkgs.system}.${n};

  # Build a (user, system) jail pair for a tool.
  # tool = { name, pkg, dirs, systemDirs ? [ ] }
  makeTool = { name, pkg, dirs, systemDirs ? [ ] }:
    [
      (mkToolJail { inherit name pkg dirs; system = false; })
      (mkToolJail { inherit name pkg; dirs = dirs ++ systemDirs; system = true; })
    ];

  jails =
    makeTool { name = "aider"; pkg = pkgs.aider-chat; dirs = aiderDirs;
               systemDirs = [ (with jail.combinators; (readonly deepseekSecret)) ]; }
    ++ makeTool {
         name = "crush";
         pkg = withDeepSeekKey (agent "crush") "crush";
         dirs = crushDirs;
       }
    ++ makeTool { name = "opencode"; pkg = withDeepSeekKey (agent "opencode") "opencode"; dirs = opencodeDirs; };
  aiderConfig = ''
      # Local vLLM OpenAI-compatible endpoint via the Headroom proxy
      openai-api-base: ${headroomProxyUrl}/v1
      openai-api-key: sk-local

      # Convenient shortcuts for your local models
      alias:
        awq: "vllm/gemma-4-awq"
        nvfp4: "vllm/gemma-4-nvfp4"

      # Better autonomous coding workflow
      auto-commits: true
      dirty-commits: true

      # Avoid attribution noise
      attribute-author: false
      attribute-committer: false
    '';


  crushConfig = builtins.toJSON {
    "$schema" = "https://charm.land/crush.json";

    # Rewrite bash tool calls through rtk to compress token-heavy command
    # output before it reaches the model.
    hooks.PreToolUse = [
      {
        name = "rtk-rewrite";
        matcher = "^bash$";
        command = "${config.home.homeDirectory}/.config/crush/hooks/rtk-rewrite.sh";
        timeout = 10;
      }
    ];

    providers = {
      vllm = {
        name = "vLLM (local)";
        type = "openai-compat";
        base_url = "${headroomProxyUrl}/v1";
        api_key = "sk-local";
        models = [
          {
            id = "gemma-4-awq";
            name = "Gemma 4 26B MoE AWQ";
            cost_per_1m_in = 0;
            cost_per_1m_out = 0;
            cost_per_1m_in_cached = 0;
            cost_per_1m_out_cached = 0;
            context_window = 262144;
            default_max_tokens = 196608;
            can_reason = true;
            supports_attachments = true;
          }
        ];
      };

      vllm_nvfp4 = {
        name = "vLLM NVFP4 (local)";
        type = "openai-compat";
        base_url = "${headroomProxyUrl}/v1";
        api_key = "sk-local";
        models = [
          {
            id = "gemma-4-nvfp4";
            name = "Gemma 4 31B NVFP4 Turbo";
            cost_per_1m_in = 0.14;
            cost_per_1m_out = 0.28;
            cost_per_1m_in_cached = 0.014;
            cost_per_1m_out_cached = 0.28;
            context_window = 98304;
            default_max_tokens = 90000;
            can_reason = true;
            supports_attachments = false;
          }
        ];
      };

      deepseek = {
        name = "DeepSeek";
        type = "openai-compat";
        base_url = "https://api.deepseek.com";
        api_key = "";
        models = [
          {
            id = "deepseek-v4-pro";
            name = "DeepSeek-V4-Pro";
            context_window = 1048576;
            default_max_tokens = 32768;
            can_reason = true;
          }
          {
            id = "deepseek-v4-flash";
            name = "DeepSeek-V4-Flash";
            context_window = 1048576;
            default_max_tokens = 32768;
            can_reason = true;
          }
        ];
      };
    };
  };

  opencodeConfig = builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";


    provider.vllm = {
      npm = "@ai-sdk/openai-compatible";
      name = "vLLM (local)";

      options.baseURL = "${headroomProxyUrl}/v1";

      models."gemma-4-awq".name =
        "Gemma 4 26B MoE AWQ";
    };


    provider.vllm_nvfp4 = {
      npm = "@ai-sdk/openai-compatible";
      name = "vLLM NVFP4 (local)";

      options.baseURL = "${headroomProxyUrl}/v1";

      models."gemma-4-nvfp4".name =
        "Gemma 4 31B NVFP4 Turbo";
    };


    provider.deepseek = {
      npm = "@ai-sdk/openai-compatible";
      name = "DeepSeek";

      options.baseURL = "https://api.deepseek.com/v1";

      models."deepseek-v4-flash".name =
        "DeepSeek V4 Flash";
    };


    model = "vllm/gemma-4-awq";
    small_model = "vllm/gemma-4-awq";
  };


  opencodeAuth = builtins.toJSON {
    vllm.type = "api";
    vllm.key = "sk-local";

    vllm_nvfp4.type = "api";
    vllm_nvfp4.key = "sk-local";

    deepseek.type = "api";
    deepseek.key = "";
  };

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

      # Crush rtk rewrite hook (used by the PreToolUse hook in crush.json)
      $DRY_RUN_CMD rm -f $HOME/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD printf '%s\n' '${rtkRewriteHook}' \
        > $HOME/.config/crush/hooks/rtk-rewrite.sh
      $DRY_RUN_CMD chmod +x $HOME/.config/crush/hooks/rtk-rewrite.sh

      # Aider
      $DRY_RUN_CMD rm -f $HOME/.aider.conf.yml
      $DRY_RUN_CMD printf '%s\n' '${aiderConfig}' > $HOME/.aider.conf.yml


      # Crush
      $DRY_RUN_CMD rm -f $HOME/.config/crush/crush.json
      $DRY_RUN_CMD printf '%s\n' '${crushConfig}' \
        > $HOME/.config/crush/crush.json

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
}
