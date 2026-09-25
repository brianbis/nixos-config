{ pkgs, lib, archipelagoSources, ... }:

let
  zipFromSource = import ../../zip-from-source.nix;

  # AP client (Archipelago.zip) for Slay the Spire II v0.107.1 (main branch):
  # a compiled .NET mod (Archipelago.dll/.pck + third-party DLLs + the spire2
  # apworld + data), so pinned as a fixed-output fetchurl of the release asset
  # (re-pin: update tag in URL + sha256). No longer bundles RitsuLib — its
  # manifest declares it as a runtime dependency (see ritsuLib below).
  sts2Client = pkgs.fetchurl {
    url = "https://github.com/dlueben1/Slay-the-Spire-2-Archipelago/releases/download/1.1.2/Archipelago.zip";
    hash = "sha256-AmXvIV6a5X6eYk81uXGj91z7WuQHibBUH+Dklkbw8nE=";
  };

  # RitsuLib 0.5.20, the 0.107.1 compat build: the plain github.zip targets
  # game 0.111.0+, so on the 0.107.1 main branch the per-version compat
  # artifact is required (if the game branch changes, swap for the matching
  # Compat.<version> asset or the plain zip on the 0.111.0 beta). Separate
  # repo (BAKAOLC/STS2-RitsuLib), not in the archipelago meta-flake, so pinned
  # here as a fixed-output fetchurl.
  ritsuLib = pkgs.fetchurl {
    url = "https://github.com/BAKAOLC/STS2-RitsuLib/releases/download/v0.5.20/STS2.RitsuLib.Compat.0.107.1.0.5.20.github.zip";
    hash = "sha256-k9f9syhfN3MFDs72Uq7e1mMaGKIH1vbiOCEdiaxI4+Q=";
  };

  # spire2 APWorld (server-side world): built from the pinned STS2 source
  # (zip world/spire2/ under the `spire2/` prefix; `nix flake update
  # archipelago` re-pins the source and the zip follows). Installed into the
  # WebHost user's custom-worlds dir so local seed generation works.
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

      # The zips / store trees carry read-only mode bits, so make the tree
      # owner-writable before rm -rf (stale read-only subdirs).
      rm_rw() { chmod -R u+w "$1" 2>/dev/null || true; rm -rf "$1"; }

      # The 1.1.1 client dropped the bundled RitsuLib + Win32 debug-terminal
      # DLLs; stale 0.5.3-alpha files would shadow the new ones, so wipe the
      # old mod dir before each install.
      rm_rw "$mods_dir/Archipelago"
      # The release zip has no wrapping folder — its mod files sit at the zip
      # root; unzip into an `Archipelago`-named folder so the loader finds
      # mods/Archipelago/.
      ${pkgs.unzip}/bin/unzip -q -o "${sts2Client}" -d "$tmp/Archipelago"
      cp -r "$tmp/Archipelago" "$mods_dir/Archipelago"

      # RitsuLib ships as root-level files; the loader expects a per-mod
      # folder (named after the mod id) under mods/.
      rm_rw "$mods_dir/STS2-RitsuLib"
      rm -rf "$tmp/ritsu"
      ${pkgs.unzip}/bin/unzip -q -o "${ritsuLib}" -d "$tmp/ritsu"
      cp -r "$tmp/ritsu" "$mods_dir/STS2-RitsuLib"

      # Server-side world for the local Archipelago WebHost (custom worlds
      # load from ~/.local/share/Archipelago/worlds/).
      worlds_dir="$HOME/.local/share/Archipelago/worlds"
      mkdir -p "$worlds_dir"
      rm_rw "$worlds_dir/spire2"
      ${pkgs.unzip}/bin/unzip -q -o "${spire2World}" -d "$worlds_dir"
    '';
}
