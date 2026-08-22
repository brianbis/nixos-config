# Local certificate authority for the friendly service names served by
# Caddy (see ./caddy.nix).
#
# `services` is the single source of truth for the name -> 127.0.0.1 port
# mapping: caddy.nix builds its virtual hosts from it, and the flake
# exposes the generated CA + leaf certificate as the `local-services-ca`
# package so the material can be inspected or installed on other devices.
#
# Deliberately NOT named:
#   - 8081  NInfer engine: internal child of the 8080 proxy; fronting it
#     directly would bypass the proxy's on-demand model load/unload.
#   - 22    OpenSSH: not HTTP, so no https:// endpoint.
#   - 40437 (v4) / 40980 (v6): bound to the Tailscale address
#     (100.110.118.13) rather than loopback; already reachable on the
#     tailnet and the service behind them is unknown.
#   - Unidentified ad-hoc listeners (not declared in this flake; could not
#     be attributed to a process from the agent jail):
#       6463     Go HTTP server, JSON API ({"code":0,"message":"Not Found"})
#       27060    Jetty/Java HTTP (default 404 page)
#       36671    Jetty/Java HTTP (default 404 page)
#       45361    Jetty/Java HTTP (default 404 page)
#       27036    raw TCP on 0.0.0.0, closes connections immediately
#       57343    accepts connections, never responds
#     TODO: investigate what these are and add them here if they are
#     services worth a named endpoint.
{ pkgs, lib }:

let
  services = {
    "llm.local"      = 8000; # llama.cpp router / vLLM (OpenAI-compatible API)
    "ninfer.local"   = 8080; # NInfer proxy (Qwen3.8-27B NVFP4)
    "headroom.local" = 8787; # Headroom compression proxy -> local llama.cpp
    "deepseek.local" = 8788; # Headroom compression proxy -> DeepSeek cloud
    "claude.local"   = 8789; # Headroom compression proxy -> Claude Code
    "dsh.local"      = 3080; # DeepSeek Harness web GUI
    "print.local"    = 631;  # CUPS web interface
  };

  names = builtins.attrNames services;

  # Private CA + one leaf certificate covering every name, generated at
  # build time. The CA is only meaningful on this machine (it is installed
  # into the system trust store by caddy.nix), so it is regenerated on
  # every rebuild rather than persisted — the same posture as
  # security.acme's runtime-generated certificates. Clients that cached
  # the previous CA (e.g. a browser started before the rebuild) need a
  # restart to trust the new one; curl/openssl re-read the store per
  # request.
  ca = pkgs.stdenv.mkDerivation {
    pname = "local-services-ca";
    version = "1";

    # No real source: everything is generated in installPhase.
    src = pkgs.runCommand "local-services-ca-src" { } "mkdir -p $out";

    nativeBuildInputs = [ pkgs.openssl ];

    dontBuild = true;

    installPhase = ''
      mkdir -p $out

      # Certificate authority (ECDSA P-256, 10 years).
      #
      # Do NOT switch these keys to ed25519: Firefox/NSS never offers
      # ed25519 in the TLS signature_algorithms extension (it is absent
      # from NSS's defaultSignatureSchemes), and Go's TLS server can only
      # sign the handshake with the certificate's key type. An ed25519
      # cert therefore makes Go abort Firefox ClientHellos with
      # handshake_failure, which NSS reports as
      # SSL_ERROR_NO_CYPHER_OVERLAP — while curl/Chrome work fine.
      # ecdsa_secp256r1_sha256 is NSS's first-choice signature scheme, so
      # ECDSA P-256 works in every client.
      openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
      openssl req -x509 -new -key ca.key -sha256 -days 3650 \
        -subj "/CN=b's Local Services CA" \
        -out ca.crt

      # One leaf certificate for all service names. The SANs are applied
      # from the [san] section at signing time (openssl x509 -req -extfile);
      # the CSR itself carries no extensions, so no req_extensions here
      # (DNS.N shorthand is not a valid CSR extension name).
      openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out leaf.key
      cat > san.cnf <<EOF
[req]
prompt = no
distinguished_name = dn
[dn]
CN = local
[san]
subjectAltName = ${lib.concatStringsSep ", " (map (n: "DNS:" + n) names)}
EOF
      openssl req -new -key leaf.key -config san.cnf -out leaf.csr
      openssl x509 -req -in leaf.csr \
        -CA ca.crt -CAkey ca.key -CAcreateserial \
        -days 3650 -sha256 -extfile san.cnf -extensions san \
        -out leaf.crt

      mv ca.crt ca.key leaf.crt leaf.key $out/
    '';
  };
in
{
  inherit services ca;
}
