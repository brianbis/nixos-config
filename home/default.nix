{ config, pkgs, plasma-manager, ... }:

let
  users = import ./users.nix;
in
{
  imports = [
    ./packages.nix
    ./plasma.nix
    ./firefox
    ./sts.nix
    ./llm
    ./discord.nix
    ./imsg
    ./sidra.nix
    ./spectacle.nix
    ./wezterm.nix
    ./dotfiles.nix
    ./minuspod.nix
    plasma-manager.homeModules.plasma-manager
  ];

  home.username = users.b.username;
  home.homeDirectory = users.b.homeDirectory;
  home.stateVersion = "26.05";
}
