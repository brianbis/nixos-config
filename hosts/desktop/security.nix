{ lib, inputs, ... }:

let
  secretsDir = ../../secrets;

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

  services.openssh = {
    enable = true;

    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  # Agenix secret management
  age = {
    identityPaths = [
      "/var/lib/agenix/key.txt"
    ];

    secrets = builtins.listToAttrs (map (file: {
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
