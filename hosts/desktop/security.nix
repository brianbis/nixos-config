{ lib, pkgs, inputs, ... }:

let
  secretsDir = ../../secrets;

  secretFiles = builtins.filter
    (name: lib.hasSuffix ".age" name)
    (builtins.attrNames (builtins.readDir secretsDir));
in
{
  imports = [ inputs.agenix.nixosModules.default ];

  users.groups.llm = { };

  # TPM2 unseal: the age key is sealed in the TPM bound to PCRs 0,2,3; this
  # script unseals the key into tmpfs (/run/agenix-tpm) for agenix to use as
  # its identity. Runbook (sealing/rotation/recovery): docs/secrets.md.
  system.activationScripts.tpmUnseal = {
    text = ''
      set -e
      export TPM2TOOLS_TCTI=device:/dev/tpmrm0
      for i in $(seq 1 100); do
        [ -e /dev/tpmrm0 ] && break
        sleep 0.1
      done
      [ -e /dev/tpmrm0 ] || { echo "agenix-tpm: TPM device not available" >&2; exit 1; }
      mkdir -p /run/agenix-tpm
      chmod 700 /run/agenix-tpm
      ${pkgs.tpm2-tools}/bin/tpm2_createprimary -c /run/agenix-tpm/primary.ctx -Q
      ${pkgs.tpm2-tools}/bin/tpm2_load -C /run/agenix-tpm/primary.ctx \
        -u /var/lib/agenix-tpm/seal.pub \
        -r /var/lib/agenix-tpm/seal.priv \
        -c /run/agenix-tpm/seal.ctx -Q
      ${pkgs.tpm2-tools}/bin/tpm2_unseal -c /run/agenix-tpm/seal.ctx -p pcr:sha256:0,2,3 \
        -o /run/agenix-tpm/key.txt
      chmod 0400 /run/agenix-tpm/key.txt
      rm -f /run/agenix-tpm/primary.ctx /run/agenix-tpm/seal.ctx
    '';
    deps = [ "specialfs" ];
  };
  # Order the unseal before agenix's own activation script (which decrypts the
  # secrets) in both the initrd (boot) and the main system (switch).
  system.activationScripts.agenixInstall.deps = lib.mkAfter [ "tpmUnseal" ];

  users.users.b.extraGroups = [
    "llm"
  ];

  services.openssh = {
    enable = true;

    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
    };
  };

  age = {
    # The identity is the TPM-unsealed key. Rollback/recovery if a boot fails
    # to unseal (PCR drift): see docs/secrets.md.
    identityPaths = [
      "/run/agenix-tpm/key.txt"
    ];

    secrets = builtins.listToAttrs (map
      (file: {
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
      })
      secretFiles);
  };
}
