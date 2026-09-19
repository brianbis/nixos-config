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
  # After installPopTracker: it rm -rf's ~/.local/share/poptracker, which
  # would wipe a pack installed before it.
  home.activation.installBalatroapPopTracker =
    lib.hm.dag.entryAfter [ "installPopTracker" ] ''
      packs_dir="$HOME/.local/share/poptracker/packs"
      mkdir -p "$packs_dir"
      tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      rm -rf "$packs_dir/balatroap"
      # GitHub archives are .tar.gz (unxz is for .tar.xz), and gzip/gunzip
      # aren't on the activation PATH, so pipe through the explicit binary.
      ${pkgs.gzip}/bin/gunzip -c "${balatroapPack}" | ${pkgs.gnutar}/bin/tar -x -C "$tmp"
      mv "$tmp/balatroap_poptracker-master" "$packs_dir/balatroap"
    '';
}
