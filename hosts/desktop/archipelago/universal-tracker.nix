{ pkgs, lib, archipelagoSources, ... }:

# Universal Tracker — "just works" logic tracker for nearly any apworld: it
# simulates the server's logic from the generation yaml + apworlds and shows
# which locations are in-logic.
#
# Built from the pinned source (the FarisTheAncient/Archipelago fork's
# worlds/tracker/): zip it under the `tracker/` prefix. `nix flake update
# archipelago` re-pins the source; the zip follows (no manual re-pin).
# Extracted into the WebHost's custom-worlds dir, where it registers as the
# "Universal Tracker" game (minimum_ap_version 0.6.2; the WebHost runs 0.6.8).
let
  zipFromSource = import ./zip-from-source.nix;
  trackerWorld = zipFromSource {
    inherit pkgs;
    src = archipelagoSources."universal-tracker".outPath;
    subdir = "worlds/tracker";
    prefix = "tracker";
    name = "tracker-apworld";
  };
in
{
  home.activation.installUniversalTracker =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      worlds_dir="$HOME/.local/share/Archipelago/worlds"
      mkdir -p "$worlds_dir"

      # The zip carries the source's read-only mode bits, so a previous
      # activation leaves read-only subdirs that a plain `rm -rf` cannot
      # unlink ("Permission denied"). Make the tree owner-writable first.
      # `|| true` keeps a missing dir (first run) from tripping `set -e`.
      rm_rw() { chmod -R u+w "$1" 2>/dev/null || true; rm -rf "$1"; }

      rm_rw "$worlds_dir/tracker"
      ${pkgs.unzip}/bin/unzip -q -o "${trackerWorld}" -d "$worlds_dir"
    '';
}
