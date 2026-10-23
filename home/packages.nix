{ config, pkgs, inputs, shared, ... }:


let
  fluent-oled = pkgs.stdenvNoCC.mkDerivation {
    pname = "fluent-oled";
    version = "1.0.1";

    # Source from the flakeless `fluent-oled` input; `nix flake update fluent-oled` re-pins it.
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

    # Source from the flakeless `nix-ide` input; `nix flake update nix-ide` re-pins it.
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
    # nix-alien: the "just run" escape hatch for unpatched foreign-ELF
    # binaries — nix-alien resolves a binary's NEEDED sonames via nix-locate
    # (bundled nix-index-with-db) and runs it in an FHSUserEnv; nix-alien-find-libs
    # prints the lib set; nix-alien-ld is the nix-ld variant (needs
    # programs.nix-ld.enable, deliberately not enabled here — the durable
    # per-package fix is patchelf-in-derivation, see refunct.nix).
    inputs.nix-alien.packages.${pkgs.stdenv.hostPlatform.system}.nix-alien
    # Archipelago entry points (webhost/server/generate/launcher wrappers for
    # ad-hoc CLI use; the web UI + tracker + hosted rooms run as the system service).
    archipelago
    foot
    ghostty
    jetbrains-mono
    fuzzel
    kdePackages.kate
    kdePackages.yakuake
    # Filelight — KDE concentric-ring disk-usage visualiser (the GUI twin of ncdu).
    kdePackages.filelight
    discord
    # Serein: lightweight native Discord client (Rust/egui/wgpu), from the flakeless `serein` input.
    serein
    bitwarden-desktop
    obsidian
    # GitButler — GUI git client (virtual branches / stacked PRs), from nixpkgs.
    gitbutler
    # Recurse: AI-native RE IDE (Tauri 2), from the flakeless `recurse` input.
    # Defaults the agent panel to the one LLM door — the availability gate
    # (llm.local, on the ledger's gate port) — with the gate's own default row
    # (`shared.defaultModel`, so there is no second declaration of which model
    # that is): the gate loads it on the first request and keeps whatever is
    # already resident. The dummy API key satisfies the client's credential
    # check. The in-app picker overrides these defaults (persisted to ~/.recurse/).
    (writeShellScriptBin "recurse" ''
      export RECURSE_LLM_ENDPOINT="${shared.gateUrl}/v1/chat/completions"
      export RECURSE_LLM_MODEL="${shared.defaultModel.id}"
      export RECURSE_LLM_API_KEY="local"
      # GSettings schemas: GTK reads org.gtk.Settings.FileChooser via glib,
      # which discovers schemas under $XDG_DATA_DIRS/*/glib-2.0/schemas. The
      # app's runtime env lacks gtk3's schema dir, so the file chooser aborts
      # ("schema not installed"). Prepend the schema dirs of every gsettings
      # provider in the closure (nixpkgs lays each out at
      # share/gsettings-schemas/<pname>-<version>/), preserving existing
      # XDG_DATA_DIRS so icon themes keep resolving.
      recurse_schemas="${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.pname}-${pkgs.gtk3.version}:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.pname}-${pkgs.gsettings-desktop-schemas.version}"
      if [ -n "$XDG_DATA_DIRS" ]; then
        export XDG_DATA_DIRS="$recurse_schemas:$XDG_DATA_DIRS"
      else
        export XDG_DATA_DIRS="$recurse_schemas"
      fi
      exec ${pkgs.recurse}/bin/recurse "$@"
    '')

    htop
    # btop dlopens libnvidia-ml.so (NVML) at runtime; on NixOS it lives in
    # /run/opengl-driver/lib, outside btop's linker search path.
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
    # Sonic Pi — live-coding music synth (music as code), from nixpkgs.
    sonic-pi
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
    # One python env for huggingface-hub + the data-analysis stack (Jupyter,
    # polars, seaborn, duckdb): separate python3Packages entries aren't
    # importable from each other, so the stack must share one withPackages env.
    (python3.withPackages (ps: with ps; [
      huggingface-hub
      seaborn
      polars
      duckdb
      #      jupyter
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

  # Sonic Pi — live-coding music synth (music as code). The nixpkgs package
  # ships its own sonic-pi.desktop; this user entry shadows it (same filename)
  # to add KRunner search aliases.
  xdg.desktopEntries.sonic-pi = {
    name = "Sonic Pi";
    genericName = "Live-coding music synth";
    exec = "sonic-pi";
    icon = "${pkgs.sonic-pi}/share/icons/hicolor/256x256/apps/sonic-pi.png";
    terminal = false;
    type = "Application";
    categories = [ "AudioVideo" "Audio" "Music" "Education" ];
    settings.Keywords = "music;code;live-coding;sonic pi;synth;compose";
  };

  # Filelight — KRunner aliases. The app ships its own entry at
  # share/applications/org.kde.filelight.desktop (upstream misc/org.kde.filelight.desktop),
  # so this entry is keyed on that same filename: the entry key IS the filename
  # (home-manager passes it to makeDesktopItem), and home.packages entries land in
  # ~/.local/share/applications, which wins over the system one — so the shadow
  # REPLACES it rather than adding a duplicate launcher. Fields mirror the shipped
  # entry (Exec/Icon/Comment/GenericName/Categories/MimeType/X-DocPath) so the shadow
  # stays launchable, not just searchable; only Keywords grows — upstream's
  # disk;drive;space;storage;usage; plus the CLI-tool names a user types
  # ("du", "ncdu") and the plain-English phrasings.
  xdg.desktopEntries."org.kde.filelight" = {
    name = "Filelight";
    genericName = "Disk Usage Statistics";
    comment = "Show disk usage and delete unused files";
    exec = "filelight %u";
    icon = "filelight";
    terminal = false;
    type = "Application";
    categories = [ "Qt" "KDE" "Utility" ];
    mimeType = [ "inode/directory" ];
    settings = {
      Keywords = "disk;drive;space;storage;usage;filelight;du;ncdu;disk usage;disk usage viewer;space analyzer;directory size;";
      X-DocPath = "filelight/index.html";
    };
  };

  # Bolt Launcher — KRunner aliases. The nixpkgs package ships Bolt.desktop
  # (makeDesktopItem name="Bolt"); this user entry shadows it (same filename,
  # user dir wins over share/applications) to add search aliases without
  # touching the package. Fields mirror the shipped entry so the shadow stays
  # launchable, not just searchable. StartupWMClass rides in `settings` —
  # the xdg module has no dedicated option for it.
  xdg.desktopEntries.Bolt = {
    name = "Bolt Launcher";
    genericName = "bolt-launcher";
    comment = "An alternative launcher for RuneScape";
    exec = "bolt-launcher";
    icon = "bolt-launcher";
    terminal = false;
    type = "Application";
    categories = [ "Game" ];
    settings = {
      StartupWMClass = "BoltLauncher";
      Keywords = "runelite;jagex;osrs;runescape;bolt";
    };
  };

}
