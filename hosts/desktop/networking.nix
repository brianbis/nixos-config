{ config, lib, pkgs, ... }:

{
  networking.networkmanager.enable = true;

  services.tailscale = {
    enable = true;
    authKeyFile = "/run/secrets/tailscale/authkey";

    # Tailscale Services (svc:dsh, below) can only be hosted by tagged
    # nodes ("service hosts must be tagged nodes"). Tags are requested
    # with `tailscale up --advertise-tags` — `tailscale set` (the
    # extraSetFlags vehicle) registers no tag flag in this CLI version
    # (1.102.2: cmd/tailscale/cli/set.go has no tag option), and `up`
    # is frozen but is still the tag mechanism.
    #
    # extraUpFlags only reaches `tailscale up` when the node (re-)authenticates
    # (tailscaled-autoconnect runs it only in NeedsLogin/NeedsMachineAuth/
    # Stopped states), so it covers future re-auths only. For the
    # already-connected case, the tailscale-advertise-tags oneshot below
    # applies the tag at every boot (a no-op once tagged).
    extraUpFlags = [ "--advertise-tags=tag:devices" ];
  };

  # Apply the node tag at boot for an already-connected node:
  # `tailscale up --advertise-tags=...` on a running node is a runtime
  # EditPrefs (no restart, no re-auth). One-time prerequisite: the tag
  # must exist in the tailnet policy with a tagOwners entry for this
  # node's user (admin console -> Access Controls), or the control plane
  # rejects the tag request. Note: once tagged, the node's identity for
  # ACL purposes becomes the tag instead of the user.
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

  # Serve the DeepSeek Harness GUI (dsh-web.service, 127.0.0.1:3080) as
  # Tailscale Service svc:dsh — https://dsh.tail835824.ts.net. The service
  # name determines the subdomain, NOT the node's MagicDNS name
  # (nixos.tail835824.ts.net, which only the unnamed default serve uses).
  # Tailscale's control plane provisions a Let's Encrypt certificate for
  # the service name (requires "HTTPS certificates" enabled in the
  # tailnet's admin console), so tailnet devices — iOS/Android included —
  # reach the GUI with a publicly trusted certificate: no /etc/hosts
  # entry, no locally issued CA to install or re-push after rebuilds.
  # Tailnet-only (no funnel): the GUI never leaves the tailnet.
  #
  # Requirements (both one-time, admin console):
  #   - the hosting node must be a tagged node: the
  #     tailscale-advertise-tags oneshot above requests tag:devices at
  #     boot, which requires the tag to exist in the tailnet policy with
  #     a tagOwners entry for this node's user (Access Controls ->
  #     policy file);
  #   - the service host must be approved: Services page -> dsh ->
  #     "Service hosts" -> Approve. Until then the MagicDNS name is not
  #     published and no listener comes up.
  #
  # Applied via the CLI, NOT the declarative services.tailscale.serve
  # module: `tailscale serve set-config` infers the listener type from the
  # endpoint target scheme, so an http:// upstream always ends up as a
  # plain-HTTP listener and no TLS listener ever comes up
  # (tailscale/tailscale#18381, open). The CLI takes an explicit --https
  # flag and is the documented method for Tailscale Services (it also
  # advertises the service host). Re-running with identical values is a
  # no-op; the serve config persists in tailscaled's state, and this
  # oneshot re-applies it at boot.
  #
  # Ordered after tailscale-advertise-tags.service so the tag is
  # requested before the service is (re-)advertised. The control plane
  # applies the tag asynchronously — `tailscale up` returns as soon as
  # the prefs change is acked, but the node's tags (what `tailscale
  # serve --service` checks for "service hosts must be tagged nodes")
  # update a moment later — so the script polls `tailscale status` for
  # up to 60s before serving. On failure the unit retries every 30s
  # (15 starts per 15min), so a slow tag propagation at boot
  # self-heals without a manual restart.
  #
  # The script also runs `tailscale serve reset` before applying: the
  # serve config persists in tailscaled's state, and a stale *plain-HTTP*
  # listener on 443 (left by the buggy declarative set-config path,
  # #18381) makes the HTTPS apply fail with "port 443 is already serving
  # 'http'". Resetting first (a no-op when the config is already clean)
  # guarantees a clean slate, so a conflicted state self-heals on the
  # next retry instead of failing forever.
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

  # The default NixOS firewall trusts only loopback, so every new tailnet
  # connection to the Tailscale IP would be dropped — including the Serve
  # listener above. Open exactly the Serve ports on tailscale0 (443 + the
  # 80 -> 443 redirect; Tailscale SSH/cp also use 443). If the whole tailnet
  # should reach all host ports (e.g. for tailnet SSH), replace this with
  # networking.firewall.trustedInterfaces = [ "tailscale0" ].
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 443 ];

  # systemd's `mymachines` NSS module is placed first in the hosts chain by
  # default (see system.nssDatabases in nixos/modules/system/boot/systemd.nix).
  # It claims all .local names and queries systemd-resolved; since resolved
  # is not running on this machine, it aborts the whole lookup before
  # /etc/hosts is ever consulted (nsswitch(5): "unavail" stops the chain).
  # That made the friendly .local names from networking.hosts unresolvable
  # for browsers and curl. Putting files first makes /etc/hosts
  # authoritative; mymachines still handles any .local name not listed there
  # once systemd-resolved is enabled.
  system.nssDatabases.hosts = lib.mkForce [ "files" "mymachines" "myhostname" "dns" ];
}