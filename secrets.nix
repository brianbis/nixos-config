let
  # Rotated 2026-08-24: the previous key (age13vhqf…) was exposed in a
  # terminal transcript during TPM sealing validation and is treated as
  # compromised. All secrets/*.age were re-encrypted to this recipient.
  adminPubKey = "age1j6qcyjz8409hrm7qhtqt7fxrg9vump4pvmkltjs0vahr6ef5darqcvasmj";
in
{
  "secrets/tailscale-authkey.age".publicKeys = [ adminPubKey ];
  "secrets/hf-token.age".publicKeys = [ adminPubKey ];
  "secrets/deepseek-api-key.age".publicKeys = [ adminPubKey ];
  "secrets/nvidia-api-key.age".publicKeys = [ adminPubKey ];
}
