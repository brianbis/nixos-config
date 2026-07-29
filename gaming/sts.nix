{ pkgs, lib, ... }:

let
  sts2Client = pkgs.fetchurl {
    url = "https://github.com/dlueben1/Slay-the-Spire-2-Archipelago/releases/download/0.5.3-alpha/sts2-client.zip";
    hash = "sha256-A3x1iR4Cm1EmzH001jrasdgy9kdhofF3swc4kikfuz4=";
  };
in
{
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
            real_name="''${base##*\\}"
            cp -f "$file" "$target/$real_name"
          done
    '';
}