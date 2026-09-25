{ pkgs, lib, archipelagoSources, ... }:

# Balatro (Steam 2379780) Archipelago setup, mirroring sts.nix: client side
# (Proton: Lovely's version.dll next to the game binary + smods/BalatroAP mods
# in the prefix save dir) and server side (balatro.apworld into the WebHost's
# custom-worlds dir). Launch options (WINEDLLOVERRIDES="version=n,b") are
# upserted into steamapps/config.xml declaratively; skipped while Steam runs
# (it rewrites config.xml from memory on exit and would clobber the edit).
let
  zipFromSource = import ../../zip-from-source.nix;

  # Server-side world; source not published, so pinned as a fixed-output
  # fetchurl of the release asset (re-pin: update tag in URL + sha256).
  balatroWorld = pkgs.fetchurl {
    url = "https://github.com/BurndiL/BalatroAP/releases/download/v0.1.9f/balatro.apworld";
    hash = "sha256-WnZ7qjpbWSt2skK5QIBWGpwJc8L8I1HXiseBd5SYXuA=";
  };

  # Client mod (smods folder "BalatroAP"): built from the pinned BalatroAP
  # source (the main branch IS the mod), zipped under a `BalatroAP/` prefix.
  balatroAPMod = zipFromSource {
    inherit pkgs;
    src = archipelagoSources.balatroap.outPath;
    subdir = ".";
    prefix = "BalatroAP";
    name = "balatro-mod";
  };

  # Lovely injector: the Windows version.dll that hooks the game and loads smods.
  lovely = pkgs.fetchurl {
    url = "https://github.com/ethangreen-dev/lovely-injector/releases/download/v0.9.0/lovely-x86_64-pc-windows-msvc.zip";
    hash = "sha256-QLmUoFXudeXyq6geeuBvLBdGDhjMNGSDCJkhiZ+t0fc=";
  };

  # smods framework; no binary release asset, so the tag's source zip.
  smods = pkgs.fetchurl {
    url = "https://github.com/Steamodded/smods/archive/refs/tags/26.829.0.zip";
    hash = "sha256-HstwFaKcKe9Qf1FQdsnop67/rxja4AlkX42ntEgzIs8=";
  };
in
{
  home.activation.installBalatroAP =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
            unzip="${pkgs.unzip}/bin/unzip"

            tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
            trap 'rm -rf "$tmp"' EXIT

            # The zips preserve the source's read-only mode bits, so make the
            # tree owner-writable before rm -rf (stale read-only subdirs).
            rm_rw() { chmod -R u+w "$1" 2>/dev/null || true; rm -rf "$1"; }

            game_dir="$HOME/.steam/steam/steamapps/common/Balatro"
            save_dir="$HOME/.steam/steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro"
            mods_dir="$save_dir/Mods"
            mkdir -p "$game_dir" "$mods_dir"

            # Lovely's version.dll next to the game binary; Steam keeps foreign
            # files, so it is in place when the game lands if not installed yet.
            $unzip -q -o "${lovely}" -d "$tmp/lovely"
            cp -f "$tmp/lovely/version.dll" "$game_dir/version.dll"

            # smods: the source zip's top folder must end up as Mods/smods/<files>.
            rm_rw "$mods_dir/smods"
            $unzip -q -o "${smods}" -d "$tmp/smods"
            mv "$tmp/smods/smods-26.829.0" "$mods_dir/smods"

            # BalatroAP mod.
            rm_rw "$mods_dir/BalatroAP"
            $unzip -q -o "${balatroAPMod}" -d "$tmp/mod"
            cp -r "$tmp/mod/BalatroAP" "$mods_dir/"

            # Server-side world for the local Archipelago WebHost.
            worlds_dir="$HOME/.local/share/Archipelago/worlds"
            mkdir -p "$worlds_dir"
            rm_rw "$worlds_dir/balatro"
            $unzip -q -o "${balatroWorld}" -d "$worlds_dir"

            # Balatro launch options: Steam keeps per-app options in config.xml
            # under <item name="apps">; it rewrites the file from memory on exit,
            # so only touch it while Steam is not running.
            if pgrep -x steam >/dev/null 2>&1; then
              echo "installBalatroAP: Steam is running; skipping config.xml launch-options upsert (close Steam and re-apply)"
            else
              config_xml="$HOME/.steam/steam/steamapps/config.xml"
              if [ -f "$config_xml" ]; then
                ${pkgs.python3}/bin/python3 - "$config_xml" <<'PY'
      import re, sys
      path, appid, opts = sys.argv[1], "2379780", 'WINEDLLOVERRIDES="version=n,b" %command%'
      opts_esc = opts.replace('"', "&quot;")
      text = open(path, encoding="utf-8").read()
      m = re.search(r'<item name="%s">.*?</item>' % appid, text, re.S)
      if not m:
          print(f"installBalatroAP: app {appid} not found in {path}; skipping (install Balatro first)")
          sys.exit(0)
      block = m.group(0)
      item = '<item name="LaunchOptions" value="%s"/>' % opts_esc
      if 'name="LaunchOptions"' in block:
          new_block = re.sub(r'<item name="LaunchOptions"[^>]*/>', item, block)
      else:
          # Insert before the block's closing tag, keeping its indentation.
          new_block = re.sub(r"(\s*)</item>", item + r"\1</item>", block, count=1)
      if new_block == block:
          print("installBalatroAP: launch options already set")
          sys.exit(0)
      open(path, "w", encoding="utf-8").write(text.replace(block, new_block))
      print("installBalatroAP: set Balatro launch options in", path)
      PY
              else
                echo "installBalatroAP: $config_xml missing; skipping launch-options upsert"
              fi
            fi
    '';
}
