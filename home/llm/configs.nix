# Renders the per-user tool configs from the shared catalog, called once per
# managed home. The crush config's data_directory/hook paths are keyed off the
# given home, so both homes get identical content with correct paths.
{ shared, userHome }:

let
  inherit (shared)
    gateUrl
    headroomCloudProxyUrl
    providerLabel
    models
    defaultModel
    opencodeProviders
    crushConfigFor
    claudeConfig
    stdioMcpFor
    opencodeMcpFor
    ;

  crushConfig = crushConfigFor userHome;

  # opencode's mcp section: the same four code-analysis servers crush and claude
  # get, in opencode's local-server shape (type "local" + one argv array).
  opencodeConfig = builtins.toJSON (opencodeProviders // {
    "$schema" = "https://opencode.ai/config.json";
    mcp = opencodeMcpFor userHome;
  });

  # Claude Code reads user-scope MCP servers from the top-level mcpServers key of
  # ~/.claude.json (settings.json has no such key), so jail-home.nix merges this
  # object into that file rather than owning it.
  claudeMcpServers = builtins.toJSON (stdioMcpFor userHome);

  aiderConfig = ''
    # The single LLM door: the availability gate loads/redirects whichever local
    # engine fits and relays through the headroom compression front, so aider
    # sees every local model instead of only the resident engine's.
    openai-api-base: ${gateUrl}/v1
    openai-api-key: ${providerLabel.${defaultModel.providerName}.api_key}

    # DeepSeek cloud endpoint via the Headroom proxy
    deepseek-api-base: ${headroomCloudProxyUrl}/v1
    deepseek-api-key: ${providerLabel.deepseek.api_key}

    # Model shortcuts (from the shared model catalog). Only the model served
    # by the backend you actually started is reachable.
    alias:
      bonsai: "${models.bonsai2_27b_pq2_instruct.providerName}/${models.bonsai2_27b_pq2_instruct.id}"
      pro: "${models.deepseekPro.providerName}/${models.deepseekPro.id}"
      flash: "${models.deepseekFlash.providerName}/${models.deepseekFlash.id}"
      strata: "${models.strata_qwen38.providerName}/${models.strata_qwen38.id}"

    # Better autonomous coding workflow
    auto-commits: true
    dirty-commits: true

    # Avoid attribution noise
    attribute-author: false
    attribute-committer: false
  '';
in
{
  inherit crushConfig opencodeConfig aiderConfig claudeConfig claudeMcpServers;
}
