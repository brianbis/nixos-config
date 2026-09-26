# DeepSeek Harness web GUI as a systemd service: `dsh --profile web` on
# 127.0.0.1:3080, fronted locally by Caddy (dsh.local) and on the tailnet by
# `tailscale serve` (dsh.tail835824.ts.net). Runs as the llm user.
{ config, lib, pkgs, inputs, jail-nix, llm-agents, ... }:

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
    nvidiaSecret = config.age.secrets.nvidia-api-key.path;
    inherit shared;
    userHome = users.b.homeDirectory;
    # Same flakeless dsh input the home-manager modules use, so the service's
    # dshPatched is the same store path as the interactive one.
    dshSrc = inputs.dsh;
  };
in
{
  systemd.services.dsh-web = {
    description = "DeepSeek Harness web GUI (jailed dsh, as llm)";

    # Auto-start at boot. After=agenix-install-secrets orders this after the
    # agenix oneshot that decrypts /run/agenix/deepseek-api-key; After=dsh-open.socket
    # orders it after the socket unit that creates /run/dsh-open (jail bind-mount).
    wantedBy = [ "multi-user.target" ];
    after = [ "agenix-install-secrets.service" "dsh-open.socket" ];

    serviceConfig = {
      Type = "simple";
      User = users.llm.username;

      # Group-writable agent files: the agent creates its state under
      # /home/llm (group `llm` 0770). systemd's default umask is 0022, which
      # would make created files/dirs group-readable but NOT group-writable,
      # so b (in the llm group) could read but not edit them. Force 0002 so b
      # can write the whole agent home without sudo. (The interactive `dshs`/
      # `jcs` wrappers reach llm via sudo; their umask is set by the
      # `Defaults>llm` sudoers rule in security.nix.)
      UMask = "0002";

      # Delegate=yes: the jail's bwrap mounts cgroup2 inside it, which the
      # kernel allows only from a process that can write its own cgroup.procs;
      # systemd grants that only when Delegate= is set (else the jail dies).
      Delegate = "yes";

      # Runs the same bubblewrap "system" jail the interactive `dshs` wrapper
      # execs (home/llm/jails.nix), so the service has the same sandbox as a
      # manual `dshs --profile web`.
      #
      # --trusted-host: the GUI's browser-trust fence accepts only loopback
      # Hosts by default; the tailnet door (tailscale serve) presents
      # dsh.tail835824.ts.net, so declare it trusted. Privileged methods stay loopback-only.
      ExecStart =
        "${jails.jailsByTool."dsh-jail-system"}/bin/jailed-dsh-system --profile web --trusted-host dsh.tail835824.ts.net";
      Restart = "on-failure";
      RestartSec = "3";
    };
  };
}
