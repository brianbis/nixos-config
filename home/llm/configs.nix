# Renders the per-user tool configs from the shared catalog: crush.json,
# opencode.json, and aider's .aider.conf.yml. Called once per managed home
# (b's home for the user jails, the llm agent user's home for the system
# jails); the crush config's data_directory/hook paths are keyed off the
# given home, so both homes get identical content with correct paths.
{ shared, userHome }:

let
  inherit (shared)
    headroomProxyUrl
    headroomCloudProxyUrl
    providerLabel
    models
    opencodeProviders
    crushConfigFor
    claudeConfig
    ;

  # Crush config for the home being managed (read by that home's jail variants).
  crushConfig = crushConfigFor userHome;

  opencodeConfig = builtins.toJSON (opencodeProviders // {
    "$schema" = "https://opencode.ai/config.json";
  });

  aiderConfig = ''
      # Local OpenAI-compatible endpoint via the Headroom proxy (whichever
      # local backend is currently serving :8000: vLLM or llama.cpp)
      openai-api-base: ${headroomProxyUrl}/v1
      openai-api-key: ${providerLabel.${models.gemma4awq.providerName}.api_key}

      # Convenient local model shortcuts (from the shared model catalog). Only
      # the model served by the backend you actually started is reachable.
      alias:
        awq: "${models.gemma4awq.providerName}/${models.gemma4awq.id}"
        nvfp4: "${models.gemma4nvfp4.providerName}/${models.gemma4nvfp4.id}"
        muse: "${models.muse.providerName}/${models.muse.id}"

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
in
{
  inherit crushConfig opencodeConfig aiderConfig claudeConfig;
}
