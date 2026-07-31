# /etc/nixos/home/default.nix
{ pkgs, lib, plasma-manager, ... }:

{
  imports = [
    ./discord.nix
    ./packages.nix
    ./plasma.nix
    ./firefox
    ./sts.nix
    plasma-manager.homeModules.plasma-manager
  ];

  # Discord Autostart
  xdg.configFile."autostart/discord.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Discord
    Exec=${pkgs.discord}/bin/discord --start-minimized
    Hidden=false
    NoDisplay=false
    X-GNOME-Autostart-enabled=true
  '';

  # Yakuake Autostart
  xdg.configFile."autostart/yakuake.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Yakuake
    Exec=${pkgs.kdePackages.yakuake}/bin/yakuake
    Hidden=false
    NoDisplay=false
    X-GNOME-Autostart-enabled=true
  '';

  programs.plasma = {
    enable = true;

    configFile = {
      kwinrc = {
        Windows = {
          FocusStealingPreventionLevel = 0;
        };
      };
    };
  };

  # Escape on an empty shell prompt minimizes Yakuake instead of doing nothing.
  # NOTE: this rebinds bare Escape in bash, which is normally the start of a
  # Meta-key sequence (Esc then key = Alt+key typed slowly). If you rely on
  # that, this will interfere with it.
  programs.bash = {
    enable = true;
    initExtra = ''
      _yakuake_escape() {
        if [ -z "$READLINE_LINE" ]; then
          ${pkgs.kdePackages.qttools}/bin/qdbus6 org.kde.yakuake /yakuake/window org.kde.yakuake.toggleWindowState
        fi
      }
      bind -x '"\e": _yakuake_escape'
    '';
  };

  home.username = "b";
  home.homeDirectory = "/home/b";

  home.stateVersion = "26.05";
}