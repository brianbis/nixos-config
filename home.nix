{ pkgs, nur, lib, ... }:

let
  sts2Client = pkgs.fetchurl {
    url = "https://github.com/dlueben1/Slay-the-Spire-2-Archipelago/releases/download/0.5.3-alpha/sts2-client.zip";
    hash = "sha256-A3x1iR4Cm1EmzH001jrasdgy9kdhofF3swc4kikfuz4=";
  };
in
{
  imports = [
    ./discord.nix
  ];

  home.username = "b";
  home.homeDirectory = "/home/b";

  home.stateVersion = "26.05";

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

    git
    gh
    just

    bolt-launcher
    lutris
    heroic
    protonup-qt
    mangohud
    gamescope
  ];

  home.activation.installSTS2Archipelago =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      target="$HOME/.steam/steam/steamapps/common/Slay the Spire 2/mods/Archipelago"
      mkdir -p "$target"

      tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      set +e
      ${pkgs.unzip}/bin/unzip -o "${sts2Client}" -d "$tmp"
      unzip_status=$?
      set -e
      if [ "$unzip_status" -ge 2 ]; then
        echo "sts2-client.zip extraction failed (exit $unzip_status)" >&2
        exit "$unzip_status"
      fi

      find "$tmp" -type f \( -name '*.dll' -o -name '*.json' -o -name '*.pck' \) -print0 \
        | while IFS= read -r -d $'\0' file; do
            base="$(basename "$file")"
            # Some Windows-built zips embed the "Archipelago\" prefix as a
            # literal backslash character in the filename instead of a real
            # subdirectory (Info-Zip on Linux won't split on \). Strip
            # anything up to the last backslash so we get the real basename.
            real_name="''${base##*\\}"
            cp -f "$file" "$target/$real_name"
          done
    '';

  programs.firefox = {
    enable = true;

    policies = {
      Preferences = {
        "toolkit.legacyUserProfileCustomizations.stylesheets" = {
          Value = true;
          Status = "locked";
        };
      };
    };

    profiles.main = {
      id = 0;
      isDefault = true;

      userChrome = builtins.readFile ./firefox/userChrome.css;

      extensions.packages = import ./firefox/addons.nix { inherit pkgs; };

      settings = import ./firefox/settings.nix;
    };
  };
}