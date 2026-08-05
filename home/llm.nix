{ config, lib, pkgs, ... }:

let
  crushConfig = builtins.toJSON {
    "$schema" = "https://charm.land/crush.json";

    providers.vllm = {
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

    providers.vllm_nvfp4 = {
      name = "vLLM NVFP4 (local)";
      type = "openai-compat";
      base_url = "http://127.0.0.1:8000/v1";
      api_key = "sk-local";

      models = [
        {
          id = "gemma-4-nvfp4";
          name = "Gemma 4 31B NVFP4 Turbo";
          cost_per_1m_in = 0;
          cost_per_1m_out = 0;
          cost_per_1m_in_cached = 0;
          cost_per_1m_out_cached = 0;
          context_window = 262144;
          default_max_tokens = 262144;
          can_reason = true;
          supports_attachments = true;
        }
      ];
    };
  };


  opencodeConfig = builtins.toJSON {
    "$schema" = "https://opencode.ai/config.json";

    provider.vllm = {
      npm = "@ai-sdk/openai-compatible";
      name = "vLLM (local)";
      options.baseURL = "http://127.0.0.1:8000/v1";

      models."gemma-4-awq".name = "Gemma 4 26B MoE AWQ";
    };

    provider.vllm_nvfp4 = {
      npm = "@ai-sdk/openai-compatible";
      name = "vLLM NVFP4 (local)";
      options.baseURL = "http://127.0.0.1:8000/v1";

      models."gemma-4-nvfp4".name = "Gemma 4 31B NVFP4 Turbo";
    };


    # AWQ default
    model = "vllm/gemma-4-awq";
    small_model = "vllm/gemma-4-awq";
  };


  opencodeAuth = builtins.toJSON {
    vllm.type = "api";
    vllm.key = "sk-local";

    vllm_nvfp4.type = "api";
    vllm_nvfp4.key = "sk-local";
  };

in
{
  home.activation.writeJailSafeConfigs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    $DRY_RUN_CMD mkdir -p \
      $HOME/.config/crush \
      $HOME/.config/opencode \
      $HOME/.local/share/opencode

    $DRY_RUN_CMD rm -f $HOME/.config/crush/crush.json
    $DRY_RUN_CMD cat << 'EOF' > $HOME/.config/crush/crush.json
    ${crushConfig}
    EOF

    $DRY_RUN_CMD rm -f $HOME/.config/opencode/opencode.json
    $DRY_RUN_CMD cat << 'EOF' > $HOME/.config/opencode/opencode.json
    ${opencodeConfig}
    EOF

    $DRY_RUN_CMD rm -f $HOME/.local/share/opencode/auth.json
    $DRY_RUN_CMD cat << 'EOF' > $HOME/.local/share/opencode/auth.json
    ${opencodeAuth}
    EOF
  '';
}