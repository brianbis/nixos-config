{ config, lib, pkgs, jail-nix, llm-agents, deepseekSecret, ... }:

let
    jail = jail-nix.lib.init pkgs;
  withDeepSeekKey = pkg: name:
  pkgs.writeShellScriptBin name ''
    export DEEPSEEK_API_KEY="$(cat ${deepseekSecret})"
    exec ${pkg}/bin/${name} "$@"
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

    (python3.withPackages (ps: [
      ps.cryptography
      ps.dnslib
      ps.requests
    ]))
  ];

  userJailOptions = with jail.combinators; [
    network
    time-zone
    no-new-session
    mount-cwd
    (readonly deepseekSecret)
  ];

  systemJailOptions = with jail.combinators; [
    network
    time-zone
    no-new-session
    (readwrite "/etc/nixos")
    (readonly deepseekSecret)
  ];

  makeJailedAider = { extraPkgs ? [ ] }:
    jail "jailed-aider"
      pkgs.aider-chat
      (with jail.combinators;
        userJailOptions ++ [
          (readwrite (noescape "~/.config/aider"))
          (readwrite (noescape "~/.aider.conf.yml"))
          (readwrite (noescape "~/.gitconfig"))

          (add-pkg-deps commonPkgs)
          (add-pkg-deps extraPkgs)
        ]);

  makeJailedAiderSystem = { extraPkgs ? [ ] }:
    jail "jailed-aider-system"
      pkgs.aider-chat
      (with jail.combinators;
        systemJailOptions ++ [
          (readwrite (noescape "~/.config/aider"))
          (readwrite (noescape "~/.aider.conf.yml"))
          (readwrite (noescape "~/.gitconfig"))
          (readonly deepseekSecret)
          (add-pkg-deps commonPkgs)
          (add-pkg-deps extraPkgs)
        ]);

  makeJailedCrush = { extraPkgs ? [ ] }:
  jail "jailed-crush"
    (withDeepSeekKey
      llm-agents.packages.${pkgs.system}.crush
      "crush")
    (with jail.combinators;
      userJailOptions ++ [
        (readwrite (noescape "~/.config/crush"))
        (readwrite (noescape "~/.local/share/crush"))

        (add-pkg-deps commonPkgs)
        (add-pkg-deps extraPkgs)
      ]);

  makeJailedCrushSystem = { extraPkgs ? [ ] }:
    jail "jailed-crush-system"
       (withDeepSeekKey
      llm-agents.packages.${pkgs.system}.crush
      "crush")
      (with jail.combinators;
        systemJailOptions ++ [
          (readwrite (noescape "~/.config/crush"))
          (readwrite (noescape "~/.local/share/crush"))

          (add-pkg-deps commonPkgs)
          (add-pkg-deps extraPkgs)
        ]);

  makeJailedOpencode = { extraPkgs ? [ ] }:
    jail "jailed-opencode"
      (withDeepSeekKey
        llm-agents.packages.${pkgs.system}.opencode
        "opencode")
      (with jail.combinators;
        userJailOptions ++ [
          (readwrite (noescape "~/.config/opencode"))
          (readwrite (noescape "~/.local/share/opencode"))
          (readwrite (noescape "~/.local/state/opencode"))

          (add-pkg-deps commonPkgs)
          (add-pkg-deps extraPkgs)
        ]);

  makeJailedOpencodeSystem = { extraPkgs ? [ ] }:
    jail "jailed-opencode-system"
      (withDeepSeekKey
        llm-agents.packages.${pkgs.system}.opencode
        "opencode")
      (with jail.combinators;
        systemJailOptions ++ [
          (readwrite (noescape "~/.config/opencode"))
          (readwrite (noescape "~/.local/share/opencode"))
          (readwrite (noescape "~/.local/state/opencode"))

          (add-pkg-deps commonPkgs)
          (add-pkg-deps extraPkgs)
        ]);
  aiderConfig = ''
      # Local vLLM OpenAI-compatible endpoint
      openai-api-base: http://127.0.0.1:8000/v1
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
    
    providers = {
      vllm = {
        name = "vLLM (local)";
        type = "openai-compat";
        base_url = "http://127.0.0.1:8000/v1";
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
        base_url = "http://127.0.0.1:8000/v1";
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
        # ✅ Added 'name' field (like your other providers)
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

      options.baseURL = "http://127.0.0.1:8000/v1";

      models."gemma-4-awq".name =
        "Gemma 4 26B MoE AWQ";
    };


    provider.vllm_nvfp4 = {
      npm = "@ai-sdk/openai-compatible";
      name = "vLLM NVFP4 (local)";

      options.baseURL = "http://127.0.0.1:8000/v1";

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
  home.packages = [
    (makeJailedAider { })
    (makeJailedAiderSystem { })

    (makeJailedCrush { })
    (makeJailedCrushSystem { })

    (makeJailedOpencode { })
    (makeJailedOpencodeSystem { })
  ];
    home.activation.writeLLMConfigs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD mkdir -p \
        $HOME/.config/crush \
        $HOME/.config/opencode \
        $HOME/.local/share/opencode


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
}