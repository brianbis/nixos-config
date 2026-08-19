{ lib, inputs, ... }:

let
  secretsDir = ../../secrets;

  secretFiles = builtins.filter
    (name: lib.hasSuffix ".age" name)
    (builtins.attrNames (builtins.readDir secretsDir));
in
{
  imports = [ inputs.agenix.nixosModules.default ];

  users.groups.llm = {};

  users.users.b.extraGroups = [
    "llm"
  ];

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

  age = {
    identityPaths = [
      "/var/lib/agenix/key.txt"
    ];

    secrets = builtins.listToAttrs (map (file: {
      name = lib.removeSuffix ".age" file;

      value =
        if file == "deepseek-api-key.age" then {
          file = "${secretsDir}/${file}";
          owner = "root";
          group = "llm";
          mode = "0440";
        } else if file == "imsg-mac.age" then {
          file = "${secretsDir}/${file}";
          owner = "b";
          group = "users";
          mode = "0400";
        } else {
          file = "${secretsDir}/${file}";
          owner = "root";
          group = "root";
          mode = "0400";
        };
    }) secretFiles);
  };
}