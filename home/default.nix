{ config, pkgs, plasma-manager, inputs, ... }:

let
  users = import ./users.nix;
  tetherPkg = inputs.tether.packages.${pkgs.system}.default;
in
{
  imports = [
    ./packages.nix
    ./plasma.nix
    ./firefox
    ./sts.nix
    ./llm
    ./discord.nix
    ./sidra.nix
    ./spectacle.nix
    ./hushmic.nix
    ./wezterm.nix
    ./dotfiles.nix
    ./minuspod.nix
    plasma-manager.homeModules.plasma-manager
  ];

  home.username = users.b.username;
  home.homeDirectory = users.b.homeDirectory;
  home.stateVersion = "26.05";

  # Tether — background daemon for iPhone connectivity (clipboard, files, ANCS notifications).
  systemd.user.services.tetherd = {
    Unit = {
      Description = "Tether daemon for iOS/Wayland integration";
      # The system bluetooth.service is not visible from the user manager;
      # the daemon probes BlueZ over D-Bus and tolerates it being down.
      After = [ "network.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${tetherPkg}/bin/tetherd";
      RuntimeDirectory = "tether";
      Restart = "on-failure";
      RestartSec = 5;
      # tetherd spawns `tether-gtk` by name for the notification Reply
      # action (G_SPAWN_SEARCH_PATH) and scans XDG_DATA_DIRS for icon
      # themes; neither is resolvable from the default user-service
      # environment, so point both at the package.
      Environment = [
        "PATH=${tetherPkg}/bin:/run/wrappers/bin:/usr/local/bin:/usr/bin:/bin"
        "XDG_DATA_DIRS=${tetherPkg}/share:/run/current-system/sw/share"
      ];
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Autostart the Tether GUI tray app.
  xdg.desktopEntries.tether-gtk = {
    name = "Tether";
    genericName = "Device Synchronization";
    comment = "Pair devices and synchronize clipboard across the network";
    exec = "${tetherPkg}/bin/tether-gtk";
    icon = "tether";
    terminal = false;
    type = "Application";
    categories = [ "Network" "Utility" ];
    # KRunner search aliases: the app is usually wanted as "the iPhone /
    # iMessage app", so match those names too, not just "tether".
    settings.Keywords = "tether;imessage;iphone;phone;sms;messages;continuity";
  };
}
