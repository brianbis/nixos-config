{ ... }:

{
  networking.networkmanager.enable = true;

  services.tailscale = {
    enable = true;
    authKeyFile = "/run/secrets/tailscale/authkey";
  };
}