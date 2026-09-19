{ pkgs, lib, ... }:

# BalatroAP PopTracker pack v1.2.0.0 (GrayGooGlitch) — full / compact /
# map-only AP trackers for Balatro (min PopTracker 0.25.9; we run 0.35.4).
# Installed into the PopTracker packs dir so it shows up in the Load menu.
let
  balatroapPack = pkgs.fetchurl {
    url = "https://github.com/graygooglitch/balatroap_poptracker/archive/refs/heads/master.tar.gz";
    hash = "sha256-PARZexV6FiUWfpfstHRLFViCpPX+kvMlcrpUHs+tItM=";
  };
in
{
  home.activation.installBalatroapPopTracker =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      packs_dir="$HOME/.local/share/poptracker/packs"
      mkdir -p "$packs_dir"
      tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      rm -rf "$packs_dir/balatroap"
      ${pkgs.gnutar}/bin/tar -xzf "${balatroapPack}" -C "$tmp"
      mv "$tmp/balatroap_poptracker-master" "$packs_dir/balatroap"
    '';
}
