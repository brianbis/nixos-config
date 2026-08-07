{ pkgs, plasma-manager, ... }:

{
  imports = [
    ./packages.nix
    ./plasma.nix
    ./firefox
    ./sts.nix
    ./llm
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
  '';

  # Yakuake Autostart
  xdg.configFile."autostart/yakuake.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Yakuake
    Exec=${pkgs.kdePackages.yakuake}/bin/yakuake
    Hidden=false
    NoDisplay=false
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
 
  home.username = "b";
  home.homeDirectory = "/home/b";

  home.stateVersion = "26.05";
}