{ pkgs, lib, ... }:

# Balatro (Steam, app 2379780) Archipelago setup, mirroring sts.nix:
#   * client side — Balatro runs via Proton, so the mod loader chain lives in
#     two places: Lovely's version.dll next to the game binary (game dir) and
#     the smods + BalatroAP mod folders inside the Proton prefix (save dir).
#     Steam is installed at ~/.steam/steam on this host (same root as sts.nix).
#   * server side — balatro.apworld installed into the Archipelago WebHost's
#     custom-worlds dir (~/.local/share/Archipelago/worlds/), where the
#     archipelago service (running as this user) loads custom worlds from.
#
# Steam launch options (WINEDLLOVERRIDES="version=n,b" %command%) are set
# declaratively by upserting the LaunchOptions entry in steamapps/config.xml.
# Without the override the prefix loads wine's builtin version.dll and the
# mod loader never starts. The upsert skips while Steam is running: Steam
# holds config.xml in memory and rewrites it on exit, which would clobber
# the edit (close Steam, then re-apply home-manager to land it).
let
  # Server-side world (v0.1.9f, 2026-01-11; game "Balatro").
  balatroWorld = pkgs.fetchurl {
    url = "https://github.com/BurndiL/BalatroAP/releases/download/v0.1.9f/balatro.apworld";
    hash = "sha256-WnZ7qjpbWSt2skK5QIBWGpwJc8L8I1HXiseBd5SYXuA=";
  };

  # Client mod (smods mod folder "BalatroAP").
  balatroAPMod = pkgs.fetchurl {
    url = "https://github.com/BurndiL/BalatroAP/releases/download/v0.1.9f/BalatroAP.zip";
    hash = "sha256-4ho/t4KvYu7dMmgiNp0lTB9yoqsCZDwrdqRPsKpdCjw=";
  };

  # Lovely injector: the Windows version.dll that hooks the game and loads
  # smods. The Windows build is used on Linux too (it runs inside Proton).
  lovely = pkgs.fetchurl {
    url = "https://github.com/ethangreen-dev/lovely-injector/releases/download/v0.9.0/lovely-x86_64-pc-windows-msvc.zip";
    hash = "sha256-QLmUoFXudeXyq6geeuBvLBdGDhjMNGSDCJkhiZ+t0fc=";
  };

  # smods mod framework. Releases carry no binary asset; the official Linux
  # install guide uses the tag's source zip.
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

      game_dir="$HOME/.steam/steam/steamapps/common/Balatro"
      save_dir="$HOME/.steam/steam/steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro"
      mods_dir="$save_dir/Mods"
      mkdir -p "$game_dir" "$mods_dir"

      # Lovely injector: version.dll next to the game binary. If Balatro is
      # not installed yet the dir is created early; Steam's install keeps
      # foreign files, so the dll is in place when the game lands.
      $unzip -q -o "${lovely}" -d "$tmp/lovely"
      cp -f "$tmp/lovely/version.dll" "$game_dir/version.dll"

      # smods framework: the source zip's top folder must end up as
      # Mods/smods/<files> (not Mods/smods/smods-.../<files>).
      rm -rf "$mods_dir/smods"
      $unzip -q -o "${smods}" -d "$tmp/smods"
      mv "$tmp/smods/smods-26.829.0" "$mods_dir/smods"

      # BalatroAP mod.
      rm -rf "$mods_dir/BalatroAP"
      $unzip -q -o "${balatroAPMod}" -d "$tmp/mod"
      cp -r "$tmp/mod/BalatroAP" "$mods_dir/"

      # Server-side world for the local Archipelago WebHost.
      worlds_dir="$HOME/.local/share/Archipelago/worlds"
      mkdir -p "$worlds_dir"
      rm -rf "$worlds_dir/balatro"
      $unzip -q -o "${balatroWorld}" -d "$worlds_dir"

      # Balatro launch options, declaratively. Steam keeps per-app launch
      # options in steamapps/config.xml under <item name="apps"> as
      #   <item name="2379780"> ... <item name="LaunchOptions" value="..."/>
      # Steam rewrites config.xml from memory on exit, so only touch it
      # while Steam is not running.
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
