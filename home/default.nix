{ pkgs, noctalia, plasma-manager, ... }:

{
  imports = [
    ./packages.nix
    ./plasma.nix
    # ./niri.nix
    # ./hyprland.nix
    ./firefox
    ./sts.nix
    ./llm
    noctalia.homeModules.default
    plasma-manager.homeModules.plasma-manager
  ];


  #programs.noctalia = {
  #  enable = true;
  #  systemd.enable = false;
  #};

  # Discord Autostart
  xdg.configFile."autostart/discord.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Discord
    Exec=${pkgs.discord}/bin/discord --start-minimized
    Hidden=false
    NoDisplay=false
  '';

  home.username = "b";
  home.homeDirectory = "/home/b";

  home.stateVersion = "26.05";
}
