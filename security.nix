{ ... }:

{
  sops = {
    defaultSopsFile = ./secrets.yaml;

    age.keyFile = "/home/b/.config/sops/age/keys.txt";

    secrets."tailscale/authkey" = {};
  };
}