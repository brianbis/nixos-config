{ config, pkgs, plasma-manager, ... }:

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
    ./dotfiles.nix
    plasma-manager.homeModules.plasma-manager
  ];

  home.username = "b";
  home.homeDirectory = "/home/b";
  home.stateVersion = "26.05";
}
