{ pkgs, ... }:

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
    foot                # primary terminal (native Wayland, niri-friendly)
    kdePackages.kate
    kdePackages.yakuake
    discord
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

    # Language servers for language-aware tooling (LSP)
    nil # Nix
    gopls # Go
    pyright # Python
    typescript-language-server # TypeScript / JavaScript
    rust-analyzer # Rust
    lua-language-server # Lua
    clang-tools # C / C++ (clangd)
    bash-language-server # Bash / shell
    vscode-langservers-extracted # JSON, YAML, HTML, CSS
    marksman # Markdown
    taplo # TOML
    sqls # SQL language server
    # SQL / database tooling

    sqlite
    postgresql
    mariadb.client
  ];
}
