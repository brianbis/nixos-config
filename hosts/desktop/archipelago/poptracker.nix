{ pkgs, lib, ... }:

# PopTracker v0.35.4 (2026-08-12) — universal, scriptable randomizer tracker
# ("Powerful Open Progress Tracker"). Connects to the Archipelago multiworld
# and the local game and auto-updates the map.
#
# The ubuntu-22.04 x86_64 release is a PyInstaller ELF. It bundles libc/ssl/
# zlib, but the SDL2 stack (libSDL2-2.0, libSDL2_ttf, libSDL2_image) remains
# NEEDED, so the wrapper supplies it via LD_LIBRARY_PATH. The data tree
# (assets, api, schema, packs, key) is installed to
# ~/.local/share/poptracker; the `poptracker` wrapper lands on the home
# profile PATH.
let
  poptrackerRelease = pkgs.fetchurl {
    url = "https://github.com/black-sliver/PopTracker/releases/download/v0.35.4/poptracker_0-35-4_ubuntu-22-04-x86_64.tar.xz";
    hash = "sha256-LUasSWvEzyvqiEQwm69Dnj9TjMyiSCOR3E59vOPh9SI=";
  };

  # NEEDED libraries that are NOT bundled in the PyInstaller archive.
  # libstdc++.so.6 comes from the base compiler (standalone libstdcpp/
  # libstdcxx5 packages are gone in current nixpkgs).
  runtimeLibs = with pkgs; [ SDL2 SDL2_ttf SDL2_image openssl_3 zlib (stdenv.cc.cc.lib) ];

  # The shell fragment ${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}, built by
  # concatenation so Nix' ${ interpolation never sees the literal.
  ldAppend = "$" + "{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";
in
{
  home.packages = [
    (pkgs.writeShellScriptBin "poptracker" ''
      export LD_LIBRARY_PATH="${lib.makeLibraryPath runtimeLibs}${ldAppend}"
      # NixOS' /lib64/ld-linux-x86-64.so.2 is a stub that rejects non-store
      # binaries, so exec the real glibc loader directly (it resolves the
      # binary's NEEDED entries from LD_LIBRARY_PATH).
      # The app loads assets/ and packs/ relative to CWD.
      cd "$HOME/.local/share/poptracker"
      exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 --library-path "$LD_LIBRARY_PATH" ./poptracker "$@"
    '')
  ];

  xdg.desktopEntries.poptracker = {
    name = "PopTracker";
    genericName = "Randomizer Tracker";
    comment = "Universal, scriptable randomizer tracker (Archipelago multiworld + local game)";
    exec = "poptracker";
    icon = "/home/b/.local/share/poptracker/assets/icon.png";
    terminal = false;
    type = "Application";
    categories = [ "Game" "Utility" ];
    settings.Keywords = "poptracker;tracker;archipelago;randomizer;multiworld";
  };

  home.activation.installPopTracker =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      dest="$HOME/.local/share/poptracker"
      tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      rm -rf "$dest"
      ${pkgs.xz}/bin/unxz -q -c "${poptrackerRelease}" | ${pkgs.gnutar}/bin/tar -x -C "$tmp"
      mv "$tmp/poptracker" "$dest"
    '';
}
