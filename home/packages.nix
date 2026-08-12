{ pkgs, inputs, ... }:


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

    dontBuild = true;

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
      ];

      userSettings = {
        "workbench.colorTheme" = "Fluent OLED";
      };
    };
  };

  home.packages = with pkgs; [
    inputs.sidra.packages.${pkgs.system}.default
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
    bolt-launcher
    lutris
    heroic
    gamescope

    # Language servers
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
  xdg.dataFile."konsole/OLED.colorscheme".text = ''
[Background]
Color=0,0,0

[BackgroundIntense]
Color=0,0,0

[Foreground]
Color=230,230,230

[ForegroundIntense]
Color=255,255,255

[Color0]
Color=0,0,0

[Color1]
Color=255,85,85

[Color2]
Color=85,255,85

[Color3]
Color=255,255,85

[Color4]
Color=85,85,255

[Color5]
Color=255,85,255

[Color6]
Color=85,255,255

[Color7]
Color=230,230,230

[Color8]
Color=85,85,85

[Color9]
Color=255,85,85

[Color10]
Color=85,255,85

[Color11]
Color=255,255,85

[Color12]
Color=85,85,255

[Color13]
Color=255,85,255

[Color14]
Color=85,255,255

[Color15]
Color=255,255,255
'';

xdg.dataFile."konsole/OLED.profile".text = ''
[Appearance]
ColorScheme=OLED

[General]
Name=OLED
Parent=FALLBACK/
'';
}