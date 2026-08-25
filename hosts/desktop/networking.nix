{ config, lib, pkgs, ... }:

{
  networking.networkmanager.enable = true;

  services.tailscale = {
    enable = true;
    # agenix decrypts the secret to /run/agenix/, not /run/secrets/ — track
    # the config path so authKeyFile follows agenix.
    authKeyFile = config.age.secrets."tailscale-authkey".path;

    # Tailscale Services require a tagged node. Tags are advertised via
    # `tailscale up --advertise-tags`, and extraUpFlags runs only at (re-)auth,
    # so the oneshot below applies the tag at boot for a connected node.
    extraUpFlags = [ "--advertise-tags=tag:devices" ];
  };

  # `tailscale up --advertise-tags` on a running node is a runtime EditPrefs
  # (no restart, no re-auth). One-time prerequisite: the tag must exist in
  # tailnet policy with a tagOwners entry for this user, or it is rejected.
  systemd.services.tailscale-advertise-tags = {
    description = "Tailscale: advertise tag:devices on this node (service host requirement)";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
    wants = [ "tailscaled.service" "tailscaled-autoconnect.service" ];
    path = [ config.services.tailscale.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      tailscale up --advertise-tags=tag:devices
    '';
  };

  # CLI, not the declarative serve module: `set-config` can't produce a TLS
  # listener for an http:// upstream (tailscale/tailscale#18381). One-time
  # console prereqs: tag:devices in policy with tagOwners, host approved.
  systemd.services.tailscale-serve = {
    description = "Tailscale Serve: apply the dsh GUI service (svc:dsh, HTTPS)";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" "tailscaled-autoconnect.service" "tailscale-advertise-tags.service" "dsh-web.service" ];
    wants = [ "tailscaled.service" "tailscale-advertise-tags.service" "dsh-web.service" ];
    startLimitIntervalSec = 900;
    startLimitBurst = 15;
    path = [ config.services.tailscale.package pkgs.jq pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "2min";
    };
    script = ''
      # Wait for the control plane to apply the node tag (up to 60s).
      tagged() {
        tailscale status --json | jq -e '.Self.Tags // [] | index("tag:devices") != null' > /dev/null 2>&1
      }
      for _ in $(seq 1 30); do
        tagged && break
        sleep 2
      done
      if ! tagged; then
        echo "tag:devices not applied to this node within 60s; check the tailnet policy tagOwners / the console Tags pane" >&2
        exit 1
      fi
      # Clear any stale/conflicting serve config (e.g. a leftover
      # plain-HTTP listener on 443 from the buggy set-config path),
      # then apply the HTTPS endpoint. Reset is a no-op when clean.
      tailscale serve reset
      tailscale serve --service=svc:dsh --yes --https=443 http://127.0.0.1:3080
    '';
  };

  # With the firewall on, the only inbound accepted is loopback (always
  # trusted) plus the Serve ports on tailscale0 below.
  networking.firewall.enable = true;

  # The firewall trusts only loopback, so tailnet traffic to the Tailscale IP
  # is dropped unless allowed — open exactly the Serve ports on tailscale0
  # (443 + the 80 -> 443 redirect; Tailscale SSH/cp also use 443).
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 443 ];

  # mymachines is first in the hosts chain by default and claims all .local
  # names; putting files first makes /etc/hosts authoritative for the .local
  # names in networking.hosts.
  system.nssDatabases.hosts = lib.mkForce [ "files" "mymachines" "myhostname" "dns" ];
}