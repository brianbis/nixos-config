# Headroom context-compression proxy systemd user services. Always-on so
# jailed agents' local vLLM (and cloud DeepSeek) traffic flows through the
# compression layer without any manual step.
{ lib, pkgs, shared, headroomDeepseekWrapper }:

let
  inherit (shared) headroomUpstreamUrl headroomPort;
in
{
  # headroom proxy for the local vLLM upstream.
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

  # headroom proxy for DeepSeek (cloud). Uses a wrapper that reads the API key
  # from the agenix secret at service start.
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
