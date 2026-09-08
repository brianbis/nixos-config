{
  description = "Tether - Linux + iPhone Continuity / iMessage / SMS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      src = pkgs.fetchFromGitHub {
        owner = "zackb";
        repo = "tether";
        rev = "v0.2.17";
        sha256 = "sha256-YG5Siv1/MZILtc6/tyydYq9t1bEjTbgC3N1+s0Ni0+A=";
      };

      # The daemon + CLI (the `tether` binary, which also runs the browser
      # native-messaging host via `tether --native-host`).
      tether =
        pkgs.stdenv.mkDerivation {
          pname = "tether";
          version = "0.2.17";
          inherit src;

          # Upstream git-clones nlohmann/json + googletest via FetchContent (no
          # network in the Nix sandbox) and installs browser native-messaging
          # manifests to absolute /etc paths. The patch swaps FetchContent for
          # find_package and drops those installs; the JSON dependency is the
          # nixpkgs package declared below.
          patches = [ ./tether-0.2.17.patch ];
          patchFlags = [ "-p1" ];

          nativeBuildInputs = with pkgs; [
            cmake
            ninja
            pkg-config
            gettext
          ];

          buildInputs = with pkgs; [
            wayland
            openssl
            glib
            avahi
            libnotify
            gtk3
            gtk-layer-shell
            nlohmann_json
          ];

          cmakeFlags = [
            "-DTETHER_BUILD_EXTENSIONS=OFF"
          ];

          # Tests are disabled in the patch (no googletest fetch).
          doCheck = false;

          meta = {
            description = "Bridge your iPhone to the Linux Wayland desktop: clipboard, files, messages, and notifications";
            homepage = "https://github.com/zackb/tether";
            license = pkgs.lib.licenses.mit;
            platforms = ["x86_64-linux"];
            mainProgram = "tether-gtk";
          };
        };

      # The Firefox add-on (OTP autofill over native messaging). Upstream's
      # build.sh runs `npm ci` (no network in the sandbox); the bundle only
      # needs esbuild, so we bundle directly and package the .xpi ourselves.
      # Layout matches NUR's buildFirefoxXpiAddon: a <addonId>.xpi under
      # share/mozilla/extensions/{ec8030f7-...}/, which home-manager symlinks
      # into the profile's extensions/ dir.
      # The Firefox add-on (OTP autofill over native messaging). Upstream's
      # build.sh runs `npm ci` (no network in the sandbox); the bundle only
      # needs esbuild, so we bundle directly and package the .xpi ourselves.
      # runCommand (not mkDerivation): the repo root has a Makefile whose
      # default target runs cmake, so a stdenv buildPhase would try to build
      # the C++ daemon. This derivation only packages, so runCommand (which
      # runs just buildCommand) is the right tool.
      #
      # Layout matches NUR's buildFirefoxXpiAddon: a <addonId>.xpi under
      # share/mozilla/extensions/{ec8030f7-...}/, which home-manager symlinks
      # into the profile's extensions/ dir.
      firefoxExtension =
        pkgs.runCommand "tether-firefox-extension-${tether.version}" {
          src = src;
          nativeBuildInputs = with pkgs; [
            esbuild
            zip
          ];
          meta = {
            description = "Tether Firefox extension: autofills OTPs on webpages via the tether daemon";
            homepage = "https://github.com/zackb/tether";
            license = pkgs.lib.licenses.mit;
            platforms = ["x86_64-linux"];
          };
        } ''
          set -e
          extdir="$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
          mkdir -p "$extdir"
          tmp="$(mktemp -d)"
          mkdir -p "$tmp/src/background" "$tmp/src/content"

          # Bundle the service worker (inlines its import of shared/native.js)
          # and the content script — the same two bundles upstream's build.sh
          # produces for the Firefox browser extension.
          esbuild "$src/extension/src/background/background.js" \
            --bundle --outfile="$tmp/src/background/background.js"
          esbuild "$src/extension/src/content/autofill.js" \
            --bundle --outfile="$tmp/src/content/autofill.js"

          cp "$src/extension/manifest-browser.json" "$tmp/manifest.json"
          cp -R "$src/extension/icons" "$tmp/"

          # Package as the .xpi Firefox loads from the profile extensions dir.
          ( cd "$tmp" && zip -qr "$extdir/tether@tether.com.xpi" . )
        '';

      # The native-messaging host the extension talks to. The browser execs the
      # wrapper (named in the manifest's "path"), which runs `tether --native-host`.
      # Pointing straight at the Nix store binary is more reliable than the
      # upstream wrapper's /usr/local/bin + $PATH fallbacks. A few files, so
      # runCommand (no unpack/build phases).
      nativeHost =
        pkgs.runCommand "tether-native-host-${tether.version}" {
          meta = {
            description = "Native messaging host for the Tether Firefox extension";
            homepage = "https://github.com/zackb/tether";
            license = pkgs.lib.licenses.mit;
            platforms = ["x86_64-linux"];
          };
        } ''
          set -e
          mkdir -p $out/bin $out/lib/mozilla/native-messaging-hosts

          printf '#!/bin/sh\nexec %s --native-host\n' "${tether}/bin/tether" \
            > $out/bin/tether-native-host
          chmod +x $out/bin/tether-native-host

          cat > $out/lib/mozilla/native-messaging-hosts/com.tether.extension.json <<EOF
{
    "name": "com.tether.extension",
    "description": "Tether Native Messaging Host",
    "path": "$out/bin/tether-native-host",
    "type": "stdio",
    "allowed_extensions": [
        "tether@tether.com"
    ]
}
EOF
        '';
    in
    {
      packages.${system} = {
        default = tether;
        firefox-extension = firefoxExtension;
        native-host = nativeHost;
      };
    };
}