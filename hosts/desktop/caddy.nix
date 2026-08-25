{ pkgs, lib, ... }:

let
  shared = import ./local-ca.nix { inherit pkgs lib; };
in
{
  services.caddy = {
    enable = true;

    # One vhost per friendly name, fronting the loopback backend. All backends
    # are loopback-only, so Caddy binds to loopback too (naming does not widen
    # exposure); port 80 is only the HTTP -> HTTPS redirect.
    virtualHosts = lib.mapAttrs' (
      name: port:
      lib.nameValuePair name {
        listenAddresses = [ "127.0.0.1" ];
        extraConfig = let
          # dsh.local's backend (the GUI) validates Host/Origin against its loopback
          # origin and 403s anything else, so Caddy rewrites Host to the upstream and
          # drops Origin (other backends are host/origin-agnostic).
          reverseProxy =
            if name == "dsh.local" then ''
              reverse_proxy 127.0.0.1:${toString port} {
                header_up Host {upstream_hostport}
                header_up -Origin
              }
            '' else ''
              reverse_proxy 127.0.0.1:${toString port}
            '';
        in ''
          tls ${shared.ca}/leaf.crt ${shared.ca}/leaf.key
          ${reverseProxy}
        '';
      }
    ) shared.services;
  };

  # Resolve the friendly names to loopback. /etc/hosts (files) is consulted
  # before DNS/mDNS, so .local names never leak to the network; all names are
  # aliases of the one loopback IP (networking.hosts maps IP -> [hostnames]).
  networking.hosts = {
    "127.0.0.1" = builtins.attrNames shared.services;
  };

  # Trust the local CA system-wide (curl, openssl, Java, browsers).
  security.pki.certificates = [ "${shared.ca}/ca.crt" ];
}
