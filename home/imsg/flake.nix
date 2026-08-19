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

          # Local upstream patch (see patches/gui-sync-on-refresh.patch): makes the
          # GUI's refresh / polling trigger an actual broker sync (sync_messages_now)
          # so new phone messages appear without a manual `imsg sync`. Applies to the
          # pinned rev's crates/imsg-gui source.
          patches = [ ./patches/gui-sync-on-refresh.patch ];

          nativeBuildInputs = with pkgs; [
            pkg-config
            nodejs
            cargo-tauri
            wrapGAppsHook3
            makeWrapper
            addDriverRunpath
            npmHooks.npmConfigHook
            npmHooks.npmInstallHook
          ];

          buildInputs = with pkgs; [
            bluez
            dbus
            openssl
            gtk3
            glib
            glib-networking
            libsoup_3
            webkitgtk_4_1
            cairo
            gdk-pixbuf
            librsvg
            atk
            at-spi2-core
          ];

          postPatch = ''
            cp crates/imsg-gui/frontend/package-lock.json ./package-lock.json
            cargo run --offline --example export_bindings -p imsg-gui
          '';

          npmDeps = npmDeps;
          dontNpmBuild = true;

          buildPhase = ''
            cargo build --release --locked --offline -p imsg
            pushd crates/imsg-gui > /dev/null
            cargo tauri build --no-bundle
            popd > /dev/null
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 target/release/imsg-gui $out/bin/imsg-gui
            install -Dm755 target/release/imsg $out/bin/imsg
            runHook postInstall
          '';

          postFixup = ''
            addDriverRunpath $out/bin/imsg-gui
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
