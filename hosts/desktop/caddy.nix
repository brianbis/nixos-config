{ pkgs, lib, ... }:

let
  shared = import ./local-ca.nix { inherit pkgs lib; };
in
{
  services.caddy = {
    enable = true;

    # One vhost per friendly name, fronting the loopback backend. All
    # backends are loopback-only; bind Caddy to loopback as well so
    # naming the endpoints does not widen any service's exposure. Port 80
    # is used only for the automatic HTTP -> HTTPS redirect.
    virtualHosts = lib.mapAttrs' (
      name: port:
      lib.nameValuePair name {
        listenAddresses = [ "127.0.0.1" ];
        extraConfig = let
          # dsh.local's backend (the DeepSeek Harness GUI) validates the Host
          # header and Origin against the loopback origin it was launched with
          # and returns 403 for anything else. Caddy forwards the client's Host
          # (dsh.local) and Origin (https://dsh.local) verbatim, which the
          # backend rejects for every JSON-RPC POST. Rewrite Host to the
          # upstream and drop Origin so the request looks like a direct loopback
          # call. Other backends are host/origin-agnostic, so leave them as-is.
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

  # Resolve the friendly names to loopback. /etc/hosts (files) is
  # consulted before DNS/mDNS, so .local names never leak to the network.
  # Note: networking.hosts maps IP -> [hostnames] (the rendered line is
  # "<ip> <names...>"), so all names are aliases of the one loopback IP.
  networking.hosts = {
    "127.0.0.1" = builtins.attrNames shared.services;
  };

  # Trust the local CA system-wide (curl, openssl, Java, browsers).
  security.pki.certificates = [ "${shared.ca}/ca.crt" ];
}
