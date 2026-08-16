{
  description = "imsg - iMessage client via Bluetooth MAP/PBAP";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      src = pkgs.fetchFromGitHub {
        owner = "gnufood";
        repo = "imsg";
        rev = "b53c1b2a1f8ad77c3099a0ff1d51223c934a6db7";
        hash = "sha256-7Kcwx9/qT561vlJ3XGFb3UK6uoxWB3mu+oer25ZBMVc=";
      };

      cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
        inherit src;
        hash = "sha256-WbmnyPZO2HTqed78sSzB6tyA83+sAaVrDwAjyyGYVIk=";
      };

      npmDeps = pkgs.fetchNpmDeps {
        src = "${src}/crates/imsg-gui/frontend";
        hash = "sha256-qPjV7Xm91685SPakxdN9XRA0E0pV7kWmAXnWIf2VgEk=";
      };
      npmRoot = "crates/imsg-gui/frontend";
    in {
      packages.${system}.default =
        pkgs.rustPlatform.buildRustPackage {
          pname = "imsg";
          version = "0.4.0";

          inherit src cargoDeps npmRoot;

          nativeBuildInputs = with pkgs; [
            pkg-config
            nodejs
            cargo-tauri
            wrapGAppsHook3 # Sets up GTK schemas and environments
            makeWrapper
            addDriverRunpath # <-- The magic bullet for NixOS OpenGL/GBM
            npmHooks.npmConfigHook
            npmHooks.npmInstallHook
          ];

          buildInputs = with pkgs; [
            bluez
            dbus
            openssl
            gtk3
            glib
            libsoup_3
            webkitgtk_4_1
          ];

          postPatch = ''
            cp crates/imsg-gui/frontend/package-lock.json ./package-lock.json
            
            # Optional: If the window is still invisible, uncomment the following line
            # to force-disable transparency in Tauri, which bypasses the WebKit alpha bug:
            # sed -i 's/"transparent": true/"transparent": false/g' crates/imsg-gui/tauri.conf.json
          '';

          npmDeps = npmDeps;
          dontNpmBuild = true;

          preBuild = ''
            cargo run --offline --example export_bindings -p imsg-gui
          '';

          buildPhase = ''
            runHook preBuild

            cargo build --release --locked --offline -p imsg

            cd crates/imsg-gui
            npm run build --prefix frontend
            cargo tauri build --no-bundle
            cd ../..

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin

            gui_bin=$(find "$NIX_BUILD_TOP/source/target" -type f -name imsg-gui -executable -print -quit)
            cli_bin=$(find "$NIX_BUILD_TOP/source/target" -type f -name imsg -executable -print -quit)

            if [ -z "$gui_bin" ] || [ -z "$cli_bin" ]; then
              echo "ERROR: Executables not found."
              exit 1
            fi

            cp "$gui_bin" "$out/bin/imsg-gui"
            cp "$cli_bin" "$out/bin/imsg"

            runHook postInstall
          '';

          postFixup = ''
            # 1. Patch the binary to look for graphics drivers in the active system path
            # This fixes the "Failed to create GBM buffer" and Mesa/NVIDIA clashes.
            addDriverRunpath $out/bin/imsg-gui

            # 2. Wrap the binary to disable the buggy DMA-BUF renderer by default
            wrapProgram $out/bin/imsg-gui \
              --set WEBKIT_DISABLE_DMABUF_RENDERER 1
          '';

          meta = {
            description = "iMessage client over Bluetooth MAP/PBAP";
            homepage = "https://github.com/gnufood/imsg";
            license = pkgs.lib.licenses.mit;
            mainProgram = "imsg-gui";
          };
        };
    };
}