{ lib, inputs, ... }:

let
  secretsDir = ../../../secrets;
  # List all files in secrets/ ending with .age
  secretFiles = builtins.filter
    (name: lib.hasSuffix ".age" name)
    (builtins.attrNames (builtins.readDir secretsDir));
in
{
  imports = [ inputs.agenix.nixosModules.default ];
  
  security.sudo.extraConfig = ''
    Defaults env_keep += "SSH_AUTH_SOCK"
  '';

  # System SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Agenix secret management
  age = {
    # System identity keys used to decrypt on boot
    identityPaths = [ "/var/lib/agenix/key.txt" ];

    # Automatically register every .age file in secrets/
    secrets = builtins.listToAttrs (map (file: {
      # Strips ".age" extension ("tailscale-authkey.age" -> "tailscale-authkey")
      name = lib.removeSuffix ".age" file;
      value = {
        file = "${secretsDir}/${file}";
        owner = "root";
        group = "root";
        mode = "0400";
      };
    }) secretFiles);
  };
}