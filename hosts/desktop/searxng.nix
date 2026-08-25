# Self-hosted SearXNG: loopback-only web-search backend for dsh and Caddy's
# searxng.local vhost. nixpkgs ships the package but no services.searxng
# module at this pin, hence the hand-rolled unit.
{ pkgs, lib, ... }:

let
  # SEARXNG_SETTINGS_PATH points at a FILE (not a folder) so SearXNG uses it
  # directly; `use_default_settings: true` merges it over the package's
  # settings.yml, inheriting the default engine set.
  settings = pkgs.writeText "searxng-settings.yml" ''
    use_default_settings: true

    server:
      # Loopback-only: the dsh SearXNG search provider (127.0.0.1:8888) and
      # Caddy's searxng.local vhost are the only clients. No external exposure.
      bind_address: "127.0.0.1"
      port: 8888
      # Local agent backend: the dsh process is the sole client, so no rate
      # limiting (and no bot heuristics that would 403 the JSON API).
      limiter: false
      public_instance: false

    search:
      # Enable the JSON API (html-only by default). The dsh provider queries
      # /search?format=json; without `json` here SearXNG returns 403.
      formats:
        - html
        - json

    # Optional: curate the engine set to a small, keyless, low-latency group.
    # Left at the full default set for now (SearXNG aggregates whichever
    # engines respond and skips failures); uncomment to pin a subset.
    # use_default_settings:
    #   engines:
    #     keep_only:
    #       - google
    #       - bing
    #       - duckduckgo
    #       - startpage
  '';

  # Loopback-only, non-public instance: a fixed secret is fine (no external
  # exposure to brute-force) and keeps the build reproducible.
  secret = "searxng-local-loopback-secret";
in
{
  # Dedicated, homeless system user: least privilege for a backend service
  # (no shell, no home). The unit runs as this user, not as llm or root.
  users.users.searxng = {
    isSystemUser = true;
    group = "searxng";
    description = "SearXNG metasearch engine";
  };
  users.groups.searxng = { };

  systemd.services.searxng = {
    description = "SearXNG metasearch engine (loopback, dsh web-search backend)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      Type = "simple";
      User = "searxng";
      Group = "searxng";
      ExecStart = "${pkgs.searxng}/bin/searxng-run";
      Environment = [
        "SEARXNG_SETTINGS_PATH=${settings}"
        "SEARXNG_SECRET=${secret}"
      ];
      Restart = "on-failure";
      RestartSec = "3";

      # Hardening: the service only needs to read its settings + the store and
      # bind a loopback socket. No filesystem writes, no privilege.
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ ];
    };
  };
}
