{ lib, inputs, ... }:

# Crystal Forge: NixOS fleet monitoring / build coordination / compliance.
#
# Runs the upstream services.crystal-forge module: server (embedded web UI) +
# API-mode builder + local PostgreSQL (system instance, trust auth on
# loopback). The server binds loopback only and is served via Caddy as
# https://forge.local (see ./local-ca.nix + ./caddy.nix).
#
# First run: the builder API key auto-generates at
# /var/lib/crystal-forge/builder-api.key and its public key is printed to the
# journal (journalctl -u crystal-forge-builder) for registration in the UI.
# First registered user in the web UI becomes Admin (auth_mode = local).
{
  imports = [ inputs.crystal-forge.nixosModules.crystal-forge ];

  # Provides pkgs.crystal-forge.* (server/builder/agent packages,
  # run-postgres-jobs, dashboards) that the module references.
  nixpkgs.overlays = [ inputs.crystal-forge.overlays.default ];

  services.crystal-forge = {
    enable = true;
    local-database = true;

    server = {
      enable = true;
      host = "127.0.0.1";
      port = 3445;
      auth_mode = "local";
    };

    build = {
      enable = true;
      api_mode = true;
      server_url = "http://127.0.0.1:3445";
    };
  };

  # The module sets nix.settings.allowed-users / trusted-users to
  # ["root" "crystal-forge"], which would drop @wheel (user b) from the nix
  # daemon. List-type options merge by concatenation, so mkForce replaces the
  # module's value with the module's list plus b.
  nix.settings.allowed-users = lib.mkForce [ "root" "b" "crystal-forge" ];
  nix.settings.trusted-users = lib.mkForce [ "root" "b" "crystal-forge" ];
}
