{ config, lib, pkgs, ... }:

{
  ### Tailnet door (2026-10-31): the front gate IS Tailscale.
  #
  # The family door chose the wheel that already exists: no nginx, no caddy,
  # no htpasswd of our own — signing in means the member's device is enrolled
  # in the tailnet under their own tailnet account, and the URL they are
  # handed is a per-member Tailscale **Serve** hostname on this node
  # (`<member>.tail835824.ts.net`, one Serve service per member). Serve is
  # tailnet-only: no public funnel URL exists, and the firewall never
  # exposes the dsh ports themselves (they stay loopback-bound in
  # ./dsh-family.nix).
  #
  # Join half of the door. The per-member Serve units — and the firewall row
  # that admits tailnet traffic to the Serve ports — live in ./dsh-family.nix.
  #
  # Mirrors hosts/desktop/networking.nix with ONE deliberate difference: this
  # box has no agenix layer, so authKeyFile is not set. The join is a human
  # ceremony over LAN ssh (README.md, "The family door over the tailnet"):
  # `tailscale up` from a terminal on the box, consent opened in any browser.
  # After that first human auth the node stays connected; nothing here needs
  # the authkey in the repo.
  services.tailscale = {
    enable = true;

    # Same tag the desktop node carries. tag:devices already exists in the
    # tailnet policy with tagOwners that cover the family identity, so this
    # node reuses an established policy row instead of asking for a new one
    # (a made-up tag is simply rejected: see the desktop unit's note).
    extraUpFlags = [ "--advertise-tags=tag:devices" ];
  };

  # The desktop precedent's tag applier, verbatim in shape: extraUpFlags runs
  # only at (re-)auth, so a connected node needs one boot-time EditPrefs call.
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
}
