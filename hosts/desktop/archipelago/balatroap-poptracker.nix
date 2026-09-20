{ pkgs, lib, inputs, ... }:

# BalatroAP PopTracker pack (GrayGooGlitch) — full / compact / map-only AP
# trackers for Balatro. The source tree IS the pack; installed into the
# PopTracker packs dir so it shows up in the Load menu.
#
# Source from the archipelago meta-flake's `balatroap-poptracker` nested input
# (graygooglitch/balatroap_poptracker, default branch master). The repo has no
# releases, so this module consumes the locked source tree directly; `nix
# flake update archipelago` re-pins it to the newest master commit.
let
  balatroapPack = inputs.archipelago.outputs.archipelagoInputs."balatroap-poptracker";
in
{
  # After installPopTracker: it rm -rf's ~/.local/share/poptracker, which
  # would wipe a pack installed before it.
  home.activation.installBalatroapPopTracker =
    lib.hm.dag.entryAfter [ "installPopTracker" ] ''
      packs_dir="$HOME/.local/share/poptracker/packs"
      mkdir -p "$packs_dir"

      # The pack is copied from the read-only store tree, so a previous
      # activation leaves read-only subdirs that a plain `rm -rf` cannot
      # unlink ("Permission denied"). Make the tree owner-writable first.
      # `|| true` keeps a missing dir (first run) from tripping `set -e`.
      rm_rw() { chmod -R u+w "$1" 2>/dev/null || true; rm -rf "$1"; }

      rm_rw "$packs_dir/balatroap"
      # The flake input is the unpacked source tree (in the store), so copy it
      # straight into the packs dir — no tarball to gunzip.
      cp -r "${balatroapPack}" "$packs_dir/balatroap"
    '';
}
