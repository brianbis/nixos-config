{ config, pkgs, inputs, ... }:


let
  fluent-oled = pkgs.stdenvNoCC.mkDerivation {
    pname = "fluent-oled";
    version = "1.0.1";

    # Source from the flakeless `fluent-oled` input (see flake.nix);
    # `nix flake update fluent-oled` re-pins it.
    src = inputs.fluent-oled;

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

    # Source from the flakeless `nix-ide` input (see flake.nix);
    # `nix flake update nix-ide` re-pins it.
    src = inputs.nix-ide;

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
    inputs.sidra.packages.${pkgs.stdenv.hostPlatform.system}.default
    # Archipelago entry points (archipelago-webhost/-server/-generate/-launcher).
    # The web UI + tracker + hosted rooms run as the archipelago system service;
    # these wrappers are for ad-hoc CLI use (seed generation, "Build APWorlds",
    # standalone MultiServer, the kivy Launcher GUI).
    archipelago
    foot
    ghostty
    jetbrains-mono
    fuzzel
    kdePackages.kate
    kdePackages.yakuake
    discord
    bitwarden-desktop
    obsidian
    # GitButler — GUI git client (virtual branches / stacked PRs), from nixpkgs.
    gitbutler

    htop
    # btop dlopens libnvidia-ml.so (NVML) at runtime to detect NVIDIA GPUs.
    # On NixOS that library lives in the graphics-drivers env (/run/opengl-driver/lib),
    # which is not in btop's default linker search path, so wrap it to set
    # LD_LIBRARY_PATH and let NVML initialise.
    (writeShellScriptBin "btop" ''
      export LD_LIBRARY_PATH="/run/opengl-driver/lib"
      exec ${btop}/bin/btop "$@"
    '')
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
    # difftastic: syntax-aware structural diff (the `difft` binary); built from
    # the flakeless `difftastic` input (home/llm/tools/difftastic.nix).
    difftastic
    jq
    yq
    unzip
    p7zip
    gcc
    git
    gh
    just
    # One python environment carrying huggingface-hub plus the data-analysis
    # stack (Jupyter notebooks, polars dataframes, seaborn plotting, duckdb
    # bindings). A bare python3 plus separate python3Packages entries are not
    # importable from each other, so the stack must live in one withPackages
    # env for `import seaborn` etc. to work from the `python3` on PATH.
    (python3.withPackages (ps: with ps; [
      huggingface-hub
      seaborn
      polars
      duckdb
      jupyter
    ]))
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
    duckdb
    mariadb.client
  ];
  xdg.dataFile."konsole/OLED.colorscheme".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/konsole/OLED.colorscheme";

  xdg.dataFile."konsole/OLED.profile".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/konsole/OLED.profile";

}
