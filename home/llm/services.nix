# Headroom context-compression proxy systemd user services. Always-on so
# jailed agents' local llama.cpp (and cloud DeepSeek) traffic flows through the
# compression layer without any manual step.
{ lib, pkgs, shared, headroomDeepseekWrapper }:

let
  inherit (shared)
    headroomUpstreamUrl
    headroomPort
    headroomClaudePort
    headroomNinferUpstreamUrl
    headroomNinferPort;
in
{
  systemd.user.services.headroom-proxy = {
    Unit = {
      Description = "Headroom context-compression proxy (llama.cpp upstream)";
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

  # DSH-default-model-facing headroom proxy: routes the default agent model
  # (ninfer qwen3.8-27b on :8080) through the compression layer. --lossless
  # (marker-free compaction): DSH has no headroom_retrieve MCP tool, so default
  # CCR mode would inject markers it cannot redeem and corrupt its context.
  systemd.user.services.headroom-proxy-ninfer = {
    Unit = {
      Description = "Headroom context-compression proxy (NInfer upstream, lossless)";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${pkgs.headroom}/bin/headroom proxy " +
        "--openai-api-url ${headroomNinferUpstreamUrl} " +
        "--lossless " +
        "--host 127.0.0.1 --port ${toString headroomNinferPort}";
      Restart = "on-failure";
      RestartSec = "3";
      WorkingDirectory = "%h/.local/share/headroom";
      Environment = "HOME=%h";
    };

    Install.WantedBy = [ "default.target" ];
  };

  # Uses a wrapper that reads the API key from the agenix secret at service start.
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

  # llama.cpp serves /v1/messages via llama-server, so the same local upstream
  # works for both the OpenAI and Anthropic (Claude Code) formats.
  systemd.user.services.headroom-proxy-claude = {
    Unit = {
      Description = "Headroom context-compression proxy (Claude Code / llama.cpp upstream)";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${pkgs.headroom}/bin/headroom proxy " +
        "--anthropic-api-url ${headroomUpstreamUrl} " +
        "--host 127.0.0.1 --port ${toString headroomClaudePort}";
      Restart = "on-failure";
      RestartSec = "3";
      WorkingDirectory = "%h/.local/share/headroom";
      Environment = "HOME=%h";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
