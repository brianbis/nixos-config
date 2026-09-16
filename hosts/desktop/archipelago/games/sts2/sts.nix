{ pkgs, lib, ... }:

let
  # AP client 1.1.1 (2026-09-08), built for Slay the Spire II v0.107.1 (main
  # branch). The previously pinned 0.5.3-alpha was built for v0.103.2 and its
  # assembly no longer initializes on 0.107.1 ("assembly dll for mod
  # archipelago failed to initialize"). 1.1.1 no longer bundles RitsuLib —
  # its manifest declares it as a runtime dependency (see ritsuLib below).
  sts2Client = pkgs.fetchurl {
    url = "https://github.com/dlueben1/Slay-the-Spire-2-Archipelago/releases/download/1.1.1/Archipelago.zip";
    hash = "sha256-9Al5lL117E4H1p2Z1YuyGgWNEwa3orL3bTWc1zLOevs=";
  };

  # RitsuLib 0.5.20, the 0.107.1 compat build. The plain github.zip targets
  # game 0.111.0+ (min_game_version 0.111.0), so on the 0.107.1 main branch
  # the per-version compat artifact is required. If the game branch changes,
  # swap this for the matching Compat.<version> asset (0.109.0 / 0.110.0
  # exist) or the plain zip on the 0.111.0 beta.
  ritsuLib = pkgs.fetchurl {
    url = "https://github.com/BAKAOLC/STS2-RitsuLib/releases/download/v0.5.20/STS2.RitsuLib.Compat.0.107.1.0.5.20.github.zip";
    hash = "sha256-k9f9syhfN3MFDs72Uq7e1mMaGKIH1vbiOCEdiaxI4+Q=";
  };

  # spire2 APWorld (server-side world, world_version 1.1.0,
  # minimum_ap_version 0.6.7 — satisfied by the pinned 0.6.8). Installed into
  # the WebHost user's custom-worlds dir so local seed generation works.
  spire2World = pkgs.fetchurl {
    url = "https://github.com/dlueben1/Slay-the-Spire-2-Archipelago/releases/download/1.1.1/spire2.apworld";
    hash = "sha256-MauZL95ZjYaMIXxl/6yRvH6izYQhlYj65kWNMyShrJY=";
  };
in
{
  home.activation.installSTS2Archipelago =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mods_dir="$HOME/.steam/steam/steamapps/common/Slay the Spire 2/mods"
      mkdir -p "$mods_dir"

      tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      # The 1.1.1 client dropped the bundled RitsuLib and the Win32-only
      # debug-terminal DLLs; stale files left over from 0.5.3-alpha (which
      # bundled an old STS2-RitsuLib.dll) would shadow the new ones, so the
      # old mod dir is wiped before each install.
      rm -rf "$mods_dir/Archipelago"
      ${pkgs.unzip}/bin/unzip -q -o "${sts2Client}" -d "$tmp"
      cp -r "$tmp/Archipelago" "$mods_dir/Archipelago"

      # RitsuLib ships as root-level files; the mod loader expects a
      # per-mod folder (named after the mod id) under mods/.
      rm -rf "$mods_dir/STS2-RitsuLib" "$tmp/ritsu"
      ${pkgs.unzip}/bin/unzip -q -o "${ritsuLib}" -d "$tmp/ritsu"
      cp -r "$tmp/ritsu" "$mods_dir/STS2-RitsuLib"

      # Server-side world for the local Archipelago WebHost (runs as this
      # user; custom worlds load from ~/.local/share/Archipelago/worlds/).
      worlds_dir="$HOME/.local/share/Archipelago/worlds"
      mkdir -p "$worlds_dir"
      rm -rf "$worlds_dir/spire2"
      ${pkgs.unzip}/bin/unzip -q -o "${spire2World}" -d "$worlds_dir"
    '';
}
