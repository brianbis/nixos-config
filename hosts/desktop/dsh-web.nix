# DeepSeek Harness web GUI as a systemd service: `dsh --profile web` on
# 127.0.0.1:3080, with two front doors:
#   - local:   Caddy serves https://dsh.local (caddy.nix / local-ca.nix own
#     the name -> port mapping; local CA, regenerated per rebuild);
#   - tailnet: `tailscale serve` (networking.nix) serves
#     https://dsh.tail835824.ts.net with a Let's Encrypt certificate
#     provisioned by the Tailscale control plane — tailnet devices need
#     no hosts entry and no locally issued CA. Note: the service NAME
#     (svc:dsh, applied by the tailscale-serve oneshot in networking.nix)
#     determines the subdomain; the node's own MagicDNS name
#     (nixos.tail835824.ts.net) is only used by the unnamed default serve.
#
# The unit runs the same bubblewrap "system" jail the interactive `dshs`
# wrapper execs (home/llm/jails.nix), so the service has exactly the same
# sandbox as a manual `dshs --profile web`: HOME pinned to /home/llm,
# ~/.dsh and /etc/nixos read-write, the DeepSeek agenix secret read-only,
# DEEPSEEK_API_KEY exported by the jail's dsh wrapper. It runs as the llm
# agent user directly (no `sudo -u llm`: the unit already is that user).
{ config, lib, pkgs, jail-nix, llm-agents, ... }:

let
  users = import ../../home/users.nix;

  # Same shared catalog + jail definitions the home-manager modules consume
  # (home/llm/llm.nix, home/llm/agent-home.nix), so the service's jail is
  # the same derivation (same store path) as the interactive one.
  shared = import ../../home/llm/catalog.nix {
    inherit lib pkgs jail-nix;
  };

  jails = import ../../home/llm/jails.nix {
    inherit lib pkgs jail-nix llm-agents;
    deepseekSecret = config.age.secrets.deepseek-api-key.path;
    inherit shared;
    userHome = users.b.homeDirectory;
  };
in {
  systemd.services.dsh-web = {
    description = "DeepSeek Harness web GUI (jailed dsh, as llm)";

    # Auto-start at boot. The agenix oneshot (sysinit.target) decrypts
    # /run/agenix/deepseek-api-key before any multi-user service starts;
    # the explicit After= keeps that dependency visible.
    wantedBy = [ "multi-user.target" ];
    after = [ "agenix-install-secrets.service" ];

    serviceConfig = {
      Type = "simple";
      User = users.llm.username;

      # The jail's bwrap unshares the cgroup namespace and mounts cgroup2
      # inside it; the kernel only allows that mount from a process that can
      # write its own cgroup's cgroup.procs. systemd chowns and opens the
      # service cgroup to the service user only when Delegate= is set, so
      # without it the jail dies at startup ("Failed to mount cgroup2").
      Delegate = "yes";

      # --trusted-host: the GUI's /api browser-trust fence accepts only
      # loopback Hosts by default; the tailnet front door (tailscale serve,
      # networking.nix) presents the serve name dsh.tail835824.ts.net
      # (derived from the svc:dsh service name), so declare it as a
      # trusted authority. The fence's privileged methods (settings /
      # credentials / agent-preset authoring, host file actions) stay
      # loopback-only regardless of trustedHosts — by design, until a real
      # authentication layer exists.
      ExecStart =
        "${jails.jailsByTool."dsh-jail-system"}/bin/jailed-dsh-system --profile web --trusted-host dsh.tail835824.ts.net";
      Restart = "on-failure";
      RestartSec = "3";
    };
  };
}