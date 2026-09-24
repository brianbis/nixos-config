{ config, pkgs, inputs, shared, ... }:


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
    # Serein — lightweight native Discord client (Rust/egui/wgpu; built from
    # the flakeless `serein` input, hosts/desktop/serein/package.nix).
    # `nix flake update serein` re-pins the source.
    serein
    bitwarden-desktop
    obsidian
    # GitButler — GUI git client (virtual branches / stacked PRs), from nixpkgs.
    gitbutler
    # Recurse — AI-native IDE for reverse engineering (Tauri 2; built from the
    # flakeless `recurse` input, hosts/desktop/recurse/package.nix). The agent
    # panel speaks the OpenAI-compatible chat-completions API; default it to
    # the local NInfer engine (socket-activated front :8080, unloads after
    # idle) with Qwen3.8-27B NVFP4 (model id from the catalog, the single
    # source of truth). The dummy API key satisfies the client's credential
    # check — the local server ignores it. The in-app model picker overrides
    # these defaults (persisted to ~/.recurse/).
    (writeShellScriptBin "recurse" ''
      export RECURSE_LLM_ENDPOINT="http://127.0.0.1:8080/v1/chat/completions"
      export RECURSE_LLM_MODEL="${shared.models.qwen38_nvfp4_ninfer.id}"
      export RECURSE_LLM_API_KEY="local"
      # GSettings schemas: GTK reads org.gtk.Settings.FileChooser (and the
      # Color/Emoji choosers) via glib, which discovers schemas under
      # $XDG_DATA_DIRS/*/glib-2.0/schemas/gschemas.compiled. The app's runtime
      # environment does not include gtk3's schema dir, so the file chooser
      # aborts (SIGABRT) with "Settings schema 'org.gtk.Settings.FileChooser'
      # is not installed". Prepend the schema dirs of every gsettings provider
      # in the app's closure — nixpkgs lays each out at
      # share/gsettings-schemas/<pname>-<version>/ — preserving any existing
      # XDG_DATA_DIRS so icon themes and other data keep resolving.
      recurse_schemas="${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.pname}-${pkgs.gtk3.version}:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.pname}-${pkgs.gsettings-desktop-schemas.version}"
      if [ -n "$XDG_DATA_DIRS" ]; then
        export XDG_DATA_DIRS="$recurse_schemas:$XDG_DATA_DIRS"
      else
        export XDG_DATA_DIRS="$recurse_schemas"
      fi
      exec ${pkgs.recurse}/bin/recurse "$@"
    '')

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

  # Recurse — AI-native IDE for reverse engineering (wrapper above).
  xdg.desktopEntries.recurse = {
    name = "Recurse";
    genericName = "AI Native IDE for reverse engineering";
    exec = "recurse";
    icon = "${pkgs.recurse}/share/icons/recurse.png";
    terminal = false;
    type = "Application";
    categories = [ "Development" "Utility" ];
    # KRunner search aliases: the app is usually wanted as "the RE tool".
    settings.Keywords = "reverse engineering;re;binary;disassembly;decompiler;radare2;malware";
  };

}
