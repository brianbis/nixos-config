{ pkgs, ... }:

{
  home.packages = with pkgs; [
    kdePackages.kate

    vscode
    bitwarden-desktop
    obsidian

    htop
    btop
    lsof
    strace
    tree
    ncdu

    ffmpeg-full
    yt-dlp
    mpv
    imagemagick

    ripgrep
    fd
    bat
    jq
    yq
    unzip
    p7zip

    git
    gh
    just

    bolt-launcher
    lutris
    heroic
    gamescope
  ];
}
