{ lib, inputs, ... }:

let
  secretsDir = ../../../secrets;
  # List all files in secrets/ ending with .age
  secretFiles = builtins.filter
    (name: lib.hasSuffix ".age" name)
    (builtins.attrNames (builtins.readDir secretsDir));
in
{
  # Make sure agenix module is imported in your flake/configuration
  imports = [ inputs.agenix.nixosModules.default ];

  age = {
    # System identity keys used to decrypt on boot
    identityPaths = [ "/var/lib/agenix/key.txt" ]; # (or /etc/ssh/ssh_host_ed25519_key)

    # Automatically register every .age file in secrets/
    secrets = builtins.listToAttrs (map (file: {
      # Strips ".age" extension ("tailscale-authkey.age" -> "tailscale-authkey")
      name = lib.removeSuffix ".age" file;
      value = {
        file = "${secretsDir}/${file}";
      };
    }) secretFiles);
  };
}