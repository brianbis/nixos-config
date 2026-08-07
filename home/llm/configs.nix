# Renders the per-user (non-sudo) tool configs from the shared catalog:
# crash.json, opencode.json, and aider's .aider.conf.yml. The root-only system
# config is seeded separately by the host module (hosts/desktop/crush-system.nix)
# from the same catalog, so user and system configs stay identical in content.
{ shared, userHome }:

let
  inherit (shared)
    headroomProxyUrl
    headroomCloudProxyUrl
    providerLabel
    models
    opencodeProviders
    crushConfigFor
    ;

  # Per-user crash config (read by the non-sudo jail variants).
  userCrushConfig = crushConfigFor userHome;

  opencodeConfig = builtins.toJSON (opencodeProviders // {
    "$schema" = "https://opencode.ai/config.json";
  });

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
in
{
  inherit userCrushConfig opencodeConfig aiderConfig;
}
