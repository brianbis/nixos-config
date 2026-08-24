let
  adminPubKey = "age13vhqfs4f288fl2haqsr6g8nd2r0e7e0sjy2a7jr94dhvu6p8cpyq2a9hz6";
in
{
  "secrets/tailscale-authkey.age".publicKeys = [ adminPubKey ];
  "secrets/hf-token.age".publicKeys = [ adminPubKey ];
  "secrets/deepseek-api-key.age".publicKeys = [ adminPubKey ];
  "secrets/imsg-mac.age".publicKeys = [ adminPubKey ];
}