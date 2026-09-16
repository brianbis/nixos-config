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

  # The snowfall-lib module wrapper hands the module Crystal Forge's own
  # nixpkgs instance (with its overlay), so pkgs.crystal-forge.* resolves
  # without host-side help. The overlay is kept anyway so host-side consumers
  # can use pkgs.crystal-forge.* too.
  nixpkgs.overlays = [ inputs.crystal-forge.overlays.default ];

  services.crystal-forge = {
    enable = true;
    local-database = true;

    # The module default host is the socket path "/run/postgresql", but the
    # server builds a postgres:// URL from it (to_url:
    # "postgres://user:pass@host:port/db"); a leading "/" leaves the URL
    # authority empty, so tokio-postgres fails with "both host and hostaddr
    # are missing" (upstream CF bug). TCP loopback works: the module adds
    # trust-auth pg_hba lines for crystal_forge on 127.0.0.1/::1.
    database = {
      host = "127.0.0.1";
    };

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

  # Upstream ordering gap: the module's server and postgres-jobs units only
  # order After=postgresql.service, but current nixpkgs moved the
  # ensureUsers/ensureDatabases work into postgresql-setup.service, which runs
  # after postgresql.service. Without this, the server starts before the
  # crystal_forge role exists and crash-loops until systemd's start limit.
  # (An After= reference to a unit that does not exist is a no-op.)
  systemd.services."crystal-forge-server".after = [ "postgresql-setup.service" ];
  systemd.services."crystal-forge-postgres-jobs".after = [ "postgresql-setup.service" ];

  # The module never conveys server.auth_mode to the server process: it is
  # not written into the generated TOML, and the AUTH_MODE env assignment in
  # the module's server environment is commented out. The server defaults
  # auth_mode to $AUTH_MODE or "oidc" (default_auth_mode), so without this
  # the UI only offers OIDC login. The README documents AUTH_MODE as the
  # server's auth env var.
  systemd.services."crystal-forge-server".environment = {
    AUTH_MODE = "local";
  };
}
