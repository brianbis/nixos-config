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

  # tinyfiledialogs spawns `kdialog` as a child (via popen), so it inherits
  # the LD_LIBRARY_PATH exported above. That path contains poptracker's own
  # openssl (3.0.x); kdialog's libcurl (built against openssl 3.4+) picks it
  # up and dies on a missing symbol version (OPENSSL_3.2.0 / OPENSSL_3.5.0)
  # at load. On KDE the window manager then closes the transient-for main
  # window and the app quits. kdialog is a store binary that resolves its own
  # libraries via RPATH, so unsetting LD_LIBRARY_PATH before exec is safe.
  #
  # kdialog's .desktop file lives in the store, outside the XDG data dirs, so
  # the desktop portal can't resolve its app id (org.kde.kdialog) and logs a
  # "Failed to register with host portal" warning. Pointing DESKTOP_FILE at
  # the store copy lets the portal find the app info.
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
      # NixOS' /lib64/ld-linux-x86-64.so.2 is a stub that rejects non-store
      # binaries, so exec the real glibc loader directly (it resolves the
      # binary's NEEDED entries from LD_LIBRARY_PATH).
      # The app loads assets/ and packs/ relative to CWD.
      cd "$HOME/.local/share/poptracker"
      # tinyfiledialogs (the AP settings dialog) probes PATH for a GUI
      # dialog backend and falls back to console input without one;
      # kdialog is the KDE-native choice. The wrapper unsets the
      # LD_LIBRARY_PATH exported above before exec'ing the real kdialog,
      # so the dialog doesn't load poptracker's openssl and crash.
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

      rm -rf "$dest"
      ${pkgs.xz}/bin/unxz -q -c "${poptrackerRelease}" | ${pkgs.gnutar}/bin/tar -x -C "$tmp"
      mv "$tmp/poptracker" "$dest"
    '';

  # The desktop portal builds its app registry from .desktop files in the XDG
  # data dirs, which the store is not part of. kdialog registers as
  # org.kde.kdialog, so without a discoverable .desktop file the portal logs
  # "Failed to register with host portal ... App info not found". Symlink the
  # store copy into the user's applications dir so the portal can resolve it.
  home.activation.linkKdialogDesktop =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/.local/share/applications"
      ln -sf "${pkgs.kdePackages.kdialog}/share/applications/org.kde.kdialog.desktop" \
        "$HOME/.local/share/applications/org.kde.kdialog.desktop"
    '';
}
