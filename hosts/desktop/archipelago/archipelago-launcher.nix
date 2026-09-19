{ pkgs, lib, ... }:

# Archipelago Launcher 0.6.7 — multiworld launcher: game clients, text
# client, and the "Universal Tracker" button (the UT world is installed
# separately, see universal-tracker.nix). PyInstaller onefile, same
# distribution shape as PopTracker: the outer binary needs only glibc; the
# inner (Kivy) binary needs SDL2 + libstdc++ at runtime. Bundles its own
# lib/ (python + Kivy.libs + 89 core worlds); custom worlds are picked up
# from ~/.local/share/Archipelago/worlds/ (shared with the WebHost).
let
  launcherRelease = pkgs.fetchurl {
    url = "https://github.com/ArchipelagoMW/Archipelago/releases/download/0.6.7/Archipelago_0.6.7_linux-x86_64.tar.gz";
    hash = "sha256-sNDOkLWpoPEhOZHTfh61jwk+PE66LfzVZb+7eawqSfw=";
  };

  # NEEDED libraries that are NOT bundled in the PyInstaller archive.
  runtimeLibs = with pkgs; [ SDL2 SDL2_ttf SDL2_image openssl_3 zlib (stdenv.cc.cc.lib) ];

  # The shell fragment ${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}, built by
  # concatenation so Nix' ${ interpolation never sees the literal.
  ldAppend = "$" + "{LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}";
in
{
  home.packages = [
    (pkgs.writeShellScriptBin "archipelago-launcher" ''
      export LD_LIBRARY_PATH="${lib.makeLibraryPath runtimeLibs}${ldAppend}"
      # NixOS' /lib64/ld-linux-x86-64.so.2 is a stub that rejects non-store
      # binaries, so exec the real glibc loader directly (it resolves the
      # binary's NEEDED entries from LD_LIBRARY_PATH).
      # The app finds lib/, data/ and share/ relative to CWD.
      cd "$HOME/.local/share/archipelago-launcher"
      exec ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 --library-path "$LD_LIBRARY_PATH" ./ArchipelagoLauncher "$@"
    '')
  ];

  xdg.desktopEntries.archipelago-launcher = {
    name = "Archipelago Launcher";
    genericName = "Multiworld Launcher";
    comment = "Archipelago multiworld launcher (clients, text client, Universal Tracker)";
    exec = "archipelago-launcher";
    icon = "/home/b/.local/share/archipelago-launcher/icon.png";
    terminal = false;
    type = "Application";
    categories = [ "Game" "Utility" ];
    settings.Keywords = "archipelago;launcher;multiworld;tracker;universal tracker;ut";
  };

  home.activation.installArchipelagoLauncher =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      dest="$HOME/.local/share/archipelago-launcher"
      tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      rm -rf "$dest"
      ${pkgs.xz}/bin/unxz -q -c "${launcherRelease}" | ${pkgs.gnutar}/bin/tar -x -C "$tmp"
      mv "$tmp/Archipelago" "$dest"
    '';
}
