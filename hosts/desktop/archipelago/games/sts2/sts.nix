{ pkgs, lib, archipelagoSources, ... }:

let
  zipFromSource = import ../../zip-from-source.nix;

  # AP client (Archipelago.zip), built for Slay the Spire II v0.107.1 (main
  # branch). It's a compiled .NET mod (bundles Archipelago.dll/.pck +
  # third-party DLLs + the spire2 apworld + data files), so it's pinned as a
  # fixed-output fetchurl of the release asset. Re-pin on a new release:
  # update the tag in the URL + the sha256. The client no longer bundles
  # RitsuLib — its manifest declares it as a runtime dependency (see ritsuLib
  # below).
  sts2Client = pkgs.fetchurl {
    url = "https://github.com/dlueben1/Slay-the-Spire-2-Archipelago/releases/download/1.1.2/Archipelago.zip";
    hash = "sha256-AmXvIV6a5X6eYk81uXGj91z7WuQHibBUH+Dklkbw8nE=";
  };

  # RitsuLib 0.5.20, the 0.107.1 compat build. The plain github.zip targets
  # game 0.111.0+ (min_game_version 0.111.0), so on the 0.107.1 main branch
  # the per-version compat artifact is required. If the game branch changes,
  # swap this for the matching Compat.<version> asset (0.109.0 / 0.110.0
  # exist) or the plain zip on the 0.111.0 beta. (RitsuLib is a separate repo
  # — BAKAOLC/STS2-RitsuLib — and is NOT part of the archipelago meta-flake,
  # so it is pinned here as a fixed-output fetchurl.)
  ritsuLib = pkgs.fetchurl {
    url = "https://github.com/BAKAOLC/STS2-RitsuLib/releases/download/v0.5.20/STS2.RitsuLib.Compat.0.107.1.0.5.20.github.zip";
    hash = "sha256-k9f9syhfN3MFDs72Uq7e1mMaGKIH1vbiOCEdiaxI4+Q=";
  };

  # spire2 APWorld (server-side world). Built from the pinned STS2 source:
  # zip world/spire2/ under the `spire2/` prefix. `nix flake update
  # archipelago` re-pins the source; the zip follows (no manual re-pin).
  # Installed into the WebHost user's custom-worlds dir so local seed
  # generation works.
  spire2World = zipFromSource {
    inherit pkgs;
    src = archipelagoSources.sts2.outPath;
    subdir = "world/spire2";
    prefix = "spire2";
    name = "sts2-apworld";
  };
in
{
  home.activation.installSTS2Archipelago =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mods_dir="$HOME/.steam/steam/steamapps/common/Slay the Spire 2/mods"
      mkdir -p "$mods_dir"

      tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      # The zips / store trees carry read-only mode bits, so a previous
      # activation can leave these dirs with read-only subdirs that a plain
      # `rm -rf` cannot unlink ("Permission denied"). Make the tree
      # owner-writable before removing it. `|| true` keeps a missing dir
      # (first run) from tripping `set -e`.
      rm_rw() { chmod -R u+w "$1" 2>/dev/null || true; rm -rf "$1"; }

      # The 1.1.1 client dropped the bundled RitsuLib and the Win32-only
      # debug-terminal DLLs; stale files left over from 0.5.3-alpha (which
      # bundled an old STS2-RitsuLib.dll) would shadow the new ones, so the
      # old mod dir is wiped before each install.
      rm_rw "$mods_dir/Archipelago"
      # The release zip has no wrapping folder — its mod files (Archipelago.dll,
      # data/, spire2.apworld, ...) sit at the zip root. Unzip straight into an
      # `Archipelago`-named folder so the mod loader finds mods/Archipelago/.
      ${pkgs.unzip}/bin/unzip -q -o "${sts2Client}" -d "$tmp/Archipelago"
      cp -r "$tmp/Archipelago" "$mods_dir/Archipelago"

      # RitsuLib ships as root-level files; the mod loader expects a
      # per-mod folder (named after the mod id) under mods/.
      rm_rw "$mods_dir/STS2-RitsuLib"
      rm -rf "$tmp/ritsu"
      ${pkgs.unzip}/bin/unzip -q -o "${ritsuLib}" -d "$tmp/ritsu"
      cp -r "$tmp/ritsu" "$mods_dir/STS2-RitsuLib"

      # Server-side world for the local Archipelago WebHost (runs as this
      # user; custom worlds load from ~/.local/share/Archipelago/worlds/).
      worlds_dir="$HOME/.local/share/Archipelago/worlds"
      mkdir -p "$worlds_dir"
      rm_rw "$worlds_dir/spire2"
      ${pkgs.unzip}/bin/unzip -q -o "${spire2World}" -d "$worlds_dir"
    '';
}
