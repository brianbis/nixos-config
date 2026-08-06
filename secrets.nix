let
  adminPubKey = "age13vhqfs4f288fl2haqsr6g8nd2r0e7e0sjy2a7jr94dhvu6p8cpyq2a9hz6";
  userPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIJZqPbOZSZovS3Jp1KPYwngTNX3jvIj62XgiYpp5Zw2";
  hostPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBECw8P+Ds3ZDoTgIItkrVOsQTUcmM9PfdXmPKYrsDIX root@nixos";
in
{
  "secrets/tailscale-authkey.age".publicKeys = [ adminPubKey ];
  "secrets/hf-token.age".publicKeys = [ adminPubKey ];
  "secrets/deepseek-api-key.age".publicKeys = [ adminPubKey ];
}