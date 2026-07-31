let
  adminKey = "age13vhqfs4f288fl2haqsr6g8nd2r0e7e0sjy2a7jr94dhvu6p8cpyq2a9hz6";
  userKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIJZqPbOZSZovS3Jp1KPYwngTNX3jvIj62XgiYpp5Zw2";
  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBECw8P+Ds3ZDoTgIItkrVOsQTUcmM9PfdXmPKYrsDIX root@nixos";
in
{
  "secrets/tailscale-authkey.age".publicKeys = [ adminKey ];
}