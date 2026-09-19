{ pkgs, lib, ... }:

# Desktop entry for the Archipelago Launcher — the launcher itself is
# already provided by the archipelago package (bin/archipelago-launcher,
# which runs Launcher.py in the python3.13 env with Kivy/KivyMD; see
# package.nix). It bundles the core worlds in the store tree and loads
# custom worlds from ~/.local/share/Archipelago/worlds/ (shared with the
# WebHost), so spire2/, balatro/ and tracker/ are all visible — including
# the "Universal Tracker" game (see universal-tracker.nix).
{
  xdg.desktopEntries.archipelago-launcher = {
    name = "Archipelago Launcher";
    genericName = "Multiworld Launcher";
    comment = "Archipelago multiworld launcher (clients, text client, Universal Tracker)";
    exec = "archipelago-launcher";
    icon = "${pkgs.archipelago}/lib/archipelago/icon.png";
    terminal = false;
    type = "Application";
    categories = [ "Game" "Utility" ];
    settings.Keywords = "archipelago;launcher;multiworld;tracker;universal tracker;ut";
  };
}
