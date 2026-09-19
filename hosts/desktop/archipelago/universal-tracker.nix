{ pkgs, lib, ... }:

# Universal Tracker v0.3.3 (2026-07-30) — "just works" logic tracker for
# nearly any apworld: it simulates the server's logic from the generation
# yaml + apworlds and shows which locations are in-logic.
#
# Distributed as an .apworld from the legacy FarisTheAncient/Archipelago
# repo's Tracker_* releases (the wiki/guide link to the ArchipelagoMW
# releases page, which does not carry the Tracker releases). Extracted into
# the WebHost's custom-worlds dir, where it registers as the
# "Universal Tracker" game (minimum_ap_version 0.6.2; the WebHost runs
# 0.6.8).
let
  trackerWorld = pkgs.fetchurl {
    url = "https://github.com/FarisTheAncient/Archipelago/releases/download/Tracker_v0.3.3/tracker.apworld";
    hash = "sha256-qQn5ZASwAJhl05uHzsi7dJRGeDV313vU+hRDHO8MIUA=";
  };
in
{
  home.activation.installUniversalTracker =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      worlds_dir="$HOME/.local/share/Archipelago/worlds"
      mkdir -p "$worlds_dir"
      rm -rf "$worlds_dir/tracker"
      ${pkgs.unzip}/bin/unzip -q -o "${trackerWorld}" -d "$worlds_dir"
    '';
}
