# Headroom context-compression proxy systemd user services. Always-on so
# jailed agents' local-model (and cloud DeepSeek) traffic flows through the
# compression layer without any manual step.
{ lib, pkgs, shared, headroomDeepseekWrapper, headroomNvidiaWrapper }:

let
  inherit (shared)
    headroomUpstreamUrl
    headroomPort
    headroomClaudePort
    headroomClaudeUpstreamUrl
    headroomNvidiaUpstreamUrl
    headroomNvidiaPort
    headroomNinferUpstreamUrl
    headroomNinferPort;
in
{
  systemd.user.services.headroom-proxy = {
    Unit = {
      Description = "Headroom context-compression proxy (gate upstream)";
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

  # The compression front for the ninfer rows (served id qwen3.8-27b): the gate
  # relays every one of them through here, so the engine's own :8081 stays private
  # plumbing. This is the model dsh names as its default.
  # --lossless (marker-free compaction): DSH has no headroom_retrieve MCP tool, so
  # default CCR mode would inject markers it cannot redeem and corrupt its context.
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

  # NVIDIA NIM (Build) cloud proxy (Kimi K3): the wrapper reads the NVIDIA API key
  # from the agenix secret at service start and injects it into upstream requests,
  # so the agent's dsh only ever carries a dummy credential.
  systemd.user.services.headroom-proxy-nvidia = {
    Unit = {
      Description = "Headroom context-compression proxy (NVIDIA NIM upstream)";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${headroomNvidiaWrapper}/bin/headroom-nvidia";
      Restart = "on-failure";
      RestartSec = "3";
      WorkingDirectory = "%h/.local/share/headroom";
      Environment = "HOME=%h";
    };

    Install.WantedBy = [ "default.target" ];
  };

  # The Anthropic-shaped face over the boot-resident Bonsai llama-server:
  # llama-server serves /v1/messages natively, so this face needs an engine as
  # its upstream — the gate speaks only the OpenAI wire format.
  #
  # --lossless, not CCR: Claude Code registers no headroom MCP server (see
  # claudeConfig in ./catalog.nix), so it has no headroom_retrieve tool to redeem
  # a <<ccr:...>> marker with — proactive compression would leave markers the model
  # cannot expand, corrupting its own context. Same reason the ninfer face at 8791
  # is lossless. The crush-facing face at 8787 keeps CCR because crush does
  # register the retrieve tool.
  systemd.user.services.headroom-proxy-claude = {
    Unit = {
      Description = "Headroom context-compression proxy (Claude Code / llama.cpp upstream)";
      After = [ "network.target" ];
    };

    Service = {
      ExecStart = "${pkgs.headroom}/bin/headroom proxy " +
        "--anthropic-api-url ${headroomClaudeUpstreamUrl} --lossless " +
        "--host 127.0.0.1 --port ${toString headroomClaudePort}";
      Restart = "on-failure";
      RestartSec = "3";
      WorkingDirectory = "%h/.local/share/headroom";
      Environment = "HOME=%h";
    };

    Install.WantedBy = [ "default.target" ];
  };
}
