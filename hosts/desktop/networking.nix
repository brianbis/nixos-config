{ lib, ... }:

{
  networking.networkmanager.enable = true;

  services.tailscale = {
    enable = true;
    authKeyFile = "/run/secrets/tailscale/authkey";
  };

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