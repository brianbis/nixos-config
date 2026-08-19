{ config, pkgs, inputs, ... }:


let
  fluent-oled = pkgs.stdenvNoCC.mkDerivation {
    pname = "fluent-oled";
    version = "1.0.1";

    src = pkgs.fetchFromGitHub {
      owner = "fermeridamagni";
      repo = "fluent-oled";
      rev = "4b013f5";
      hash = "sha256-WsbG1k0D6h8XecuEojRM9KfamkuJpKThqK1AYQrCa94=";
    };

    installPhase = ''
      mkdir -p $out/share/vscode/extensions/fermeridamagni.fluent-oled
      cp -r . $out/share/vscode/extensions/fermeridamagni.fluent-oled/
    '';

    vscodeExtPublisher = "fermeridamagni";
    vscodeExtName = "fluent-oled";
    vscodeExtUniqueId = "fermeridamagni.fluent-oled";

    meta = {
      description = "A pure black, minimalist theme for VS Code";
      homepage = "https://github.com/fermeridamagni/fluent-oled";
      license = pkgs.lib.licenses.mit;
    };
  };

  nix-ide = pkgs.stdenvNoCC.mkDerivation {
    pname = "nix-ide";
    version = "0.5.13";

    src = pkgs.fetchFromGitHub {
      owner = "nix-community";
      repo = "vscode-nix-ide";
      rev = "1d26f139a6ff4ce22ca18faabc3d2596513470ac";
      hash = "sha256-TAElWtpoiZmMRUUc+TADezwlNuX5AGnqe2Qn+fB2qy8=";
    };

    installPhase = ''
      mkdir -p $out/share/vscode/extensions/jnoortheen.nix-ide
      cp -r . $out/share/vscode/extensions/jnoortheen.nix-ide/
    '';

    vscodeExtPublisher = "jnoortheen";
    vscodeExtName = "nix-ide";
    vscodeExtUniqueId = "jnoortheen.nix-ide";

    meta = {
      description = "Nix language server and formatter for VS Code";
      homepage = "https://github.com/nix-community/vscode-nix-ide";
      license = pkgs.lib.licenses.mit;
    };
  };
  in

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

  programs.vscode = {
    enable = true;

    profiles.default = {
      extensions = [
        fluent-oled
        nix-ide
      ];
    };
  };

  home.packages = with pkgs; [
    inputs.sidra.packages.${pkgs.system}.default
    inputs.imsg.packages.${pkgs.system}.default
    foot
    ghostty
    fuzzel
    kdePackages.kate
    kdePackages.yakuake
    discord
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
    python3Packages.huggingface-hub
    bolt-launcher
    lutris
    heroic
    gamescope

    nil
    gopls
    pyright
    typescript-language-server
    rust-analyzer
    lua-language-server
    clang-tools
    bash-language-server
    vscode-langservers-extracted
    marksman
    taplo
    sqls

    sqlite
    postgresql
    mariadb.client
  ];
  xdg.dataFile."konsole/OLED.colorscheme".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/konsole/OLED.colorscheme";

xdg.dataFile."konsole/OLED.profile".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/konsole/OLED.profile";

  xdg.desktopEntries.imsg-gui = {
    name = "imsg";
    genericName = "iMessage client";
    exec = "env WEBKIT_DISABLE_DMABUF_RENDERER=1 imsg-gui";
    icon = "imsg";
    categories = [ "Network" "InstantMessaging" ];
    terminal = false;
    settings = {
      Keywords = "phone link;imessage;phone;iphone";
    };
  };

  home.sessionVariables.WEBKIT_DISABLE_DMABUF_RENDERER = "1";
}