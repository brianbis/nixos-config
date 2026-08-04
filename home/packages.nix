{ pkgs, makeJailedOpencode, makeJailedCrush, ... }:

{
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "b";
        email = "brianbis@gmail.com";
      };
      safe = {
        directory = [ "/etc/nixos" ];
      };
    };
  };
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
    gcc
    git
    gh
    just
    python3
    bolt-launcher
    lutris
    heroic
    gamescope
    (makeJailedCrush {})
    (makeJailedOpencode {})
  ];
}
