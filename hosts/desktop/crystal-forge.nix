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

    # --- Declarative onboarding of this host's config into Crystal Forge ---
    # The server upserts everything below into its database at startup
    # (sync_systems_to_db), so no UI clicking is needed: the flake is polled
    # and evaluated by the builder, and the agent (running on this same host,
    # ordered after the server) registers the system by signing heartbeats
    # with the Ed25519 keypair whose public key is declared here.
    #
    # The private key is NOT in this repo (it is public on GitHub). It lives
    # at /var/lib/crystal-forge/host.key (base64 raw 32-byte Ed25519 seed,
    # matching the public key in systems[0].public_key below). Create it once
    # before the first switch that enables the client:
    #   sudo bash -c 'echo "<seed-b64>" > /var/lib/crystal-forge/host.key && chmod 600 /var/lib/crystal-forge/host.key'
    # The module types private_key as lib.types.path, so the file must exist
    # before the first `just switch` that enables the client.
    client = {
      enable = true;
      server_port = 3445; # module default is 3000; server_host defaults to 127.0.0.1 (same host)
      private_key = "/var/lib/crystal-forge/host.key";
    };

    # Watch this repo as a flake. repo_url is used two ways: the builder
    # mirrors it with `git clone --bare <repo_url>`, and the server evaluates
    # it as a Nix flake reference (normalize_flake_git_url -> git+<url>, then
    # builtins.getFlake "git+file:///etc/nixos?rev=<commit>"). A bare local
    # path ("/etc/nixos") survives the git clone but nix misparses the
    # resulting "git+/etc/nixos?rev=..." reference; file:// is a valid git
    # URL for both. The builder (user crystal-forge) can read /etc/nixos.
    flakes = {
      watched = [
        {
          name = "desktop";
          repo_url = "file:///etc/nixos";
          branch = "main";
          auto_poll = true;
          initial_commit_depth = 10;
        }
      ];
    };

    # The environment the system belongs to (synced to the DB before systems).
    environments = [
      {
        name = "production";
        description = "Production desktop host (nixos)";
        is_active = true;
        risk_profile = "LOW";
        compliance_level = "NONE";
      }
    ];

    # This host as a managed system. public_key is the base64 raw 32-byte
    # Ed25519 public key of the agent's keypair (private half in
    # /var/lib/crystal-forge/host.key). deployment_policy = manual means
    # activations are only triggered from the UI.
    systems = [
      {
        hostname = "nixos";
        public_key = "fdhAZ9dukrbkcGsHLXjuKZp4jzODrQ18QCgJjo7ng3Y=";
        environment = "production";
        flake_name = "desktop";
        deployment_policy = "manual";
      }
    ];
  };

  # The module sets nix.settings.allowed-users / trusted-users to
  # ["root" "crystal-forge"], which would drop @wheel (user b) from the nix
  # daemon. List-type options merge by concatenation, so mkForce replaces the
  # module's value with the module's list plus b.
  nix.settings.allowed-users = lib.mkForce [ "root" "b" "crystal-forge" ];
  nix.settings.trusted-users = lib.mkForce [ "root" "b" "crystal-forge" ];

  # libgit2 (nix's built-in git fetcher) refuses to open a repository whose
  # path is not owned by the calling user: "repository path '/etc/nixos' is
  # not owned by current user". The server (user crystal-forge) evaluates the
  # watched flake via builtins.getFlake "git+file:///etc/nixos?rev=...", and
  # /etc/nixos is owned by llm, so every commit eval failed instantly.
  # git-fetch-with-cli makes the daemon use the git CLI for fetches instead,
  # which has no ownership check (commit polling already used CLI git, which
  # is why commits synced fine while evals failed).
  nix.settings.git-fetch-with-cli = true;

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
