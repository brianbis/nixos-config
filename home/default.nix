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
