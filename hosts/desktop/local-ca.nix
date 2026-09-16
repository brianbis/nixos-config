# Local certificate authority for the friendly service names served by
# Caddy (see ./caddy.nix).
#
# `services` is the single source of truth for the name -> 127.0.0.1 port
# mapping: caddy.nix builds its vhosts from it, and the flake exposes the
# generated CA + leaf cert as the `local-services-ca` package.
#
# Deliberately NOT named: 8081 (NInfer engine) is an internal child of the
# 8080 wrapper (fronting it directly bypasses on-demand load/unload); 22 is
# not HTTP, so no https:// endpoint.
{ pkgs, lib }:

let
  services = {
    "llm.local" = 8000; # llama.cpp router / vLLM (OpenAI-compatible API)
    "ninfer.local" = 8080; # NInfer engine (Qwen3.8-27B NVFP4, socket-activated)
    "ninfer-a3b.local" = 8082; # NInfer engine (Qwen3.6-35B-A3B, socket-activated)
    "ninfer-gzenz.local" = 8084; # NInfer gzenz fork engine (Qwen3.8-27B NVFP4, socket-activated)
    "sglang.local" = 8086; # SGLang engine (Qwen3.8-27B NVFP4, native, socket-activated)
    "headroom.local" = 8787; # Headroom compression proxy -> local llama.cpp
    "deepseek.local" = 8788; # Headroom compression proxy -> DeepSeek cloud
    "claude.local" = 8789; # Headroom compression proxy -> Claude Code
    "dsh.local" = 3080; # DeepSeek Harness web GUI
    "searxng.local" = 8888; # SearXNG metasearch (loopback; dsh web-search backend)
    "archipelago.local" = 8090; # Archipelago WebHost (multiworld server + tracker + generator)
    "forge.local" = 3445; # Crystal Forge server (web UI + API; builder + Postgres run alongside)
    # Deliberately NOT here: dsh.tail835824.ts.net is served by `tailscale
    # serve` with a Let's Encrypt cert (Tailscale control plane), not by
    # Caddy with this local CA.
    "print.local" = 631; # CUPS web interface
  };

  names = builtins.attrNames services;

  # Private CA + one leaf cert covering every name, generated at build time.
  # The CA is only meaningful on this machine, so it is regenerated on every
  # rebuild rather than persisted (like security.acme's runtime certs).
  ca = pkgs.stdenv.mkDerivation {
    pname = "local-services-ca";
    version = "1";

    # No real source: everything is generated in installPhase.
    src = pkgs.runCommand "local-services-ca-src" { } "mkdir -p $out";

    nativeBuildInputs = [ pkgs.openssl ];

    dontBuild = true;

    installPhase = ''
            mkdir -p $out

            # ECDSA P-256, 10 years. Do NOT switch to ed25519: Firefox/NSS never
            # offers ed25519 in TLS signature_algorithms, and Go's TLS server signs
            # only with the cert's key type, so ed25519 breaks Firefox (curl/Chrome OK).
            openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key
            openssl req -x509 -new -key ca.key -sha256 -days 3650 \
              -subj "/CN=b's Local Services CA" \
              -out ca.crt

            # One leaf cert for all service names. SANs are applied from the [san]
            # section at signing time (openssl x509 -req -extfile); the CSR carries
            # no extensions (DNS.N is not a valid CSR extension name).
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
