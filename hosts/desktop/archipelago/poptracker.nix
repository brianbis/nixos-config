{ pkgs, lib, ... }:

# PopTracker: universal, scriptable randomizer tracker (Archipelago multiworld + local game).
# The ubuntu-22.04 release is a PyInstaller ELF bundling libc/ssl/zlib; the SDL2 stack stays
# NEEDED (supplied via LD_LIBRARY_PATH). Data tree installs to ~/.local/share/poptracker.
# Pinned as a fixed-output fetchurl; re-pin on new release: update tag in URL + sha256.
let
  poptrackerRelease = pkgs.fetchurl {
    url = "https://github.com/black-sliver/PopTracker/releases/download/v0.35.4/poptracker_0-35-4_ubuntu-22-04-x86_64.tar.xz";
    hash = "sha256-LUasSWvEzyvqiEQwm69Dnj9TjMyiSCOR3E59vOPh9SI=";
  };

  # NEEDED libs not bundled in the PyInstaller archive (libstdc++.so.6 via the base compiler).
  runtimeLibs = with pkgs; [ SDL2 SDL2_ttf SDL2_image openssl_3 zlib (stdenv.cc.cc.lib) ];

  # The shell fragment ${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}, built by
  # concatenation so Nix' ${ interpolation never sees the literal.
  ldAppend = "$" + "{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";

  # kdialog inherits LD_LIBRARY_PATH (poptracker's openssl 3.0.x) and dies on
  # missing symbol versions; unset it (kdialog resolves via RPATH). Also point
  # DESKTOP_FILE at the store copy so the portal can resolve its app id.
  kdialogClean = pkgs.writeShellScriptBin "kdialog" ''
    unset LD_LIBRARY_PATH
    export DESKTOP_FILE="${pkgs.kdePackages.kdialog}/share/applications/org.kde.kdialog.desktop"
    exec ${pkgs.kdePackages.kdialog}/bin/kdialog "$@"
  '';
in
{
  home.packages = [
    (pkgs.writeShellScriptBin "poptracker" ''
      export LD_LIBRARY_PATH="${lib.makeLibraryPath runtimeLibs}${ldAppend}"
      # NixOS' /lib64/ld-linux-x86-64.so.2 rejects non-store binaries, so exec
      # the real glibc loader; assets/ and packs/ load relative to CWD.
      cd "$HOME/.local/share/poptracker"
      # tinyfiledialogs needs a GUI dialog backend on PATH; the kdialog
      # wrapper unsets LD_LIBRARY_PATH so it doesn't load poptracker's openssl.
      export PATH="${kdialogClean}/bin:$PATH"
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

      # The tarball carries read-only mode bits, so make the tree owner-writable
      # before rm -rf (a plain rm would fail on stale read-only subdirs).
      rm_rw() { chmod -R u+w "$1" 2>/dev/null || true; rm -rf "$1"; }

      rm_rw "$dest"
      ${pkgs.xz}/bin/unxz -q -c "${poptrackerRelease}" | ${pkgs.gnutar}/bin/tar -x -C "$tmp"
      mv "$tmp/poptracker" "$dest"
    '';

  # kdialog registers as org.kde.kdialog but its .desktop file is in the store
  # (outside XDG data dirs), so symlink it for the portal's app registry.
  home.activation.linkKdialogDesktop =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/.local/share/applications"
      ln -sf "${pkgs.kdePackages.kdialog}/share/applications/org.kde.kdialog.desktop" \
        "$HOME/.local/share/applications/org.kde.kdialog.desktop"
    '';
}
