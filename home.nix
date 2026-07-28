{ pkgs, nur, discord-nixpkgs, ... }:

let
  discordPkgs = import discord-nixpkgs {
    system = pkgs.system;
    config = {
      allowUnfree = true;
    };
  };

  discord = discordPkgs.discord;
in

{
  home.username = "b";
  home.homeDirectory = "/home/b";

  home.stateVersion = "26.05";

  home.packages = with pkgs; [
    kdePackages.kate

    # desktop apps
    vscode
    bitwarden-desktop
    discord
    obsidian

    # system tools
    htop
    btop
    lsof
    strace
    tree
    ncdu

    # media
    ffmpeg
    yt-dlp
    mpv
    imagemagick

    # files/data
    ripgrep
    fd
    bat
    jq
    yq
    unzip
    p7zip

    # development
    git
    gh
    just

    # games
    bolt-launcher
    lutris
    heroic
    protonup-qt
    mangohud
    gamescope
  ];
  programs.firefox = {
    enable = true;

    policies = {
      Preferences = {
        "toolkit.legacyUserProfileCustomizations.stylesheets" = {
          Value = true;
          Status = "locked";
        };
      };
    };

    profiles.main = {
      id = 0;
      isDefault = true;

      userChrome = builtins.readFile ./firefox/userChrome.css;

      extensions.packages = import ./firefox/addons.nix { inherit pkgs; };

      settings = import ./firefox/settings.nix;
    };
  };

}