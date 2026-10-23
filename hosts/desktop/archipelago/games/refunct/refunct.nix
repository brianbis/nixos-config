{ pkgs, lib, ... }:

# Refunct (Steam 406150, native Linux build) Archipelago setup — same shape as
# balatro.nix/sts.nix, but BOTH artifacts are release-only: the repo
# (spinerak/refunct-tas-archipelago, a refunct-tas Rust fork) carries no
# published Python world source, so unlike sts/balatro nothing is built from
# source; both are pinned here as fixed-output fetchurl of the release asset
# (re-pin: update tag in URL + sha256, same procedure as balatroWorld/ritsuLib).
#
# Client side: practice-linux.zip = the rtil runtime (librtil.so) + the
# refunct-tas launcher + the mod's .re scripts (zip root practice-linux/).
# Both ELF artifacts are generic-Linux binaries: refunct-tas carries
# PT_INTERP /lib64/ld-linux-x86-64.so.2, which on NixOS is the stub-ld
# ("Could not start dynamically linked executable"), and librtil.so (LD_PRELOAD
# into the game) has no RUNPATH for its NEEDED (libxcb*, libgcc_s). Same fix
# as the sglang/vllm packages: a build-time derivation repoints the launcher's
# interpreter at the store glibc loader and gives both artifacts a RUNPATH
# covering glibc + gcc (libgcc_s.so.1) + libxcb + libXau + libXdmcp (libxcb.so.1
# pulls the last two). Steam launch option LD_PRELOADs librtil.so into the game;
# the mod itself starts when the user runs practice-linux/refunct-tas while
# Refunct is open (README: "double-click refunct-tas" after launching the game).
# Server side: refunct.apworld (zip root refunct/) into the WebHost's
# custom-worlds dir so local seed generation works.
#
# SSL_CERT_FILE in the launch option is the README's Linux fix for "IO error:
# no native root CA certificates found" — the mod's Rust HTTPS finds no CA
# path; /etc/ssl/certs/ca-certificates.crt exists on NixOS.
let
  # Client mod (rtil + launcher + scripts), v1.8.0a release asset.
  practiceLinux = pkgs.fetchurl {
    url = "https://github.com/spinerak/refunct-tas-archipelago/releases/download/v1.8.0a/practice-linux.zip";
    hash = "sha256-foa8u5e0N0XQnYnW3M3KsmIEbGeWWTr7zHzocW4D/NE=";
  };

  # NixOS-patched copy (see header): repoint refunct-tas's PT_INTERP at the
  # store glibc loader and give both ELF artifacts a RUNPATH covering their
  # NEEDED (glibc, gcc's libgcc_s.so.1, libxcb* + their libXau/libXdmcp deps).
  practiceLinuxPatched = pkgs.runCommand "refunct-practice-linux"
    {
      nativeBuildInputs = [ pkgs.unzip pkgs.patchelf pkgs.coreutils ];
    } ''
    unzip -q "${practiceLinux}" -d "$out"
    tree="$out/practice-linux"

    rpath="${pkgs.stdenv.cc.libc}/lib:${pkgs.stdenv.cc.libc}/lib64:${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.libxcb}/lib:${pkgs.libXau}/lib:${pkgs.libXdmcp}/lib"

    patchelf --set-interpreter "${pkgs.stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2" \
      --set-rpath "$rpath" "$tree/refunct-tas"
    patchelf --set-rpath "$rpath" "$tree/librtil.so"

    # patchelf rewrites the ELF; keep the zip's exec bits explicit.
    chmod +x "$tree/refunct-tas" "$tree/librtil.so"

    # Sanity (same style as the sglang package): the launcher must now
    # request the store glibc loader, not the generic /lib64 stub.
    test "$(patchelf --print-interpreter "$tree/refunct-tas")" \
      = "${pkgs.stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2"

    # Every NEEDED soname must resolve inside the RUNPATH (patchelf 0.15
    # has no --print-dependencies, so check the known set against $rpath).
    in_rpath() {
      so=$1; found=0
      oldifs=$IFS; IFS=:
      for d in $rpath; do
        [ -f "$d/$so" ] && found=1
      done
      IFS=$oldifs
      [ "$found" = 1 ] || { echo "error: $so not found in rpath" >&2; exit 1; }
    }
    for so in libc.so.6 libm.so.6 libgcc_s.so.1 libxcb.so.1 \
              libxcb-render.so.0 libxcb-shape.so.0 libxcb-xfixes.so.0 \
              libXau.so.6 libXdmcp.so.6; do
      in_rpath "$so"
    done

    # Loader smoke on a /tmp copy (the launcher may write next to itself):
    # it must get past the loader — a GUI app, so it may fail later without
    # a display or the game, but a loader failure prints one of these.
    cp -r "$tree" /tmp/refunct-smoke
    smoke=$(timeout 5 /tmp/refunct-smoke/refunct-tas 2>&1 || true)
    if printf '%s\n' "$smoke" | grep -qiE 'error while loading shared libraries|Could not start dynamically linked|version `GLIBC'; then
      echo "loader failure: $smoke" >&2
      exit 1
    fi
  '';

  # Server-side world, v1.8.0a release asset.
  refunctWorld = pkgs.fetchurl {
    url = "https://github.com/spinerak/refunct-tas-archipelago/releases/download/v1.8.0a/refunct.apworld";
    hash = "sha256-d2ywe4NLLJCn9d5l9kcY4IHZgMoeXDIRGfvpxqGSbcA=";
  };
in
{
  home.activation.installRefunctAP =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        mods_dir="$HOME/.local/share/refunct-ap"
        mkdir -p "$mods_dir"

        tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT

        # The store tree carries read-only mode bits, so make the tree
        # owner-writable before rm -rf (stale read-only subdirs).
        rm_rw() { chmod -R u+w "$1" 2>/dev/null || true; rm -rf "$1"; }

        # practice-linux: the NixOS-patched tree (see practiceLinuxPatched);
        # cp -r preserves modes, so refunct-tas/librtil.so stay +x.
        rm_rw "$mods_dir/practice-linux"
        cp -r "${practiceLinuxPatched}" "$mods_dir/practice-linux"

        # Server-side world for the local Archipelago WebHost (zip root is
        # refunct/, custom worlds load from ~/.local/share/Archipelago/worlds/).
        worlds_dir="$HOME/.local/share/Archipelago/worlds"
        mkdir -p "$worlds_dir"
        rm_rw "$worlds_dir/refunct"
        ${pkgs.unzip}/bin/unzip -q -o "${refunctWorld}" -d "$worlds_dir"

        # Refunct launch options (appid 406150): LD_PRELOAD carries rtil in the
        # game process; the mod starts when the user runs practice-linux/refunct-tas
        # while the game is open. Steam rewrites config.xml from memory on exit,
        # so only touch it while Steam is not running (same guard as installBalatroAP).
        if pgrep -x steam >/dev/null 2>&1; then
          echo "installRefunctAP: Steam is running; skipping config.xml launch-options upsert (close Steam and re-apply)"
        else
          config_xml="$HOME/.steam/steam/steamapps/config.xml"
          if [ -f "$config_xml" ]; then
            preload="$HOME/.local/share/refunct-ap/practice-linux/librtil.so"
            opts="LD_PRELOAD=\"$preload\" SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt %command%"
            ${pkgs.python3}/bin/python3 - "$config_xml" "406150" "$opts" <<'PY'
      import re, sys
      path, appid, opts = sys.argv[1], sys.argv[2], sys.argv[3]
      opts_esc = opts.replace('"', "&quot;")
      text = open(path, encoding="utf-8").read()
      m = re.search(r'<item name="%s">.*?</item>' % appid, text, re.S)
      if not m:
          print(f"installRefunctAP: app {appid} not found in {path}; skipping (install Refunct first)")
          sys.exit(0)
      block = m.group(0)
      item = '<item name="LaunchOptions" value="%s"/>' % opts_esc
      if 'name="LaunchOptions"' in block:
          new_block = re.sub(r'<item name="LaunchOptions"[^>]*/>', item, block)
      else:
          # Insert before the block's closing tag, keeping its indentation.
          new_block = re.sub(r"(\s*)</item>", item + r"\1</item>", block, count=1)
      if new_block == block:
          print("installRefunctAP: launch options already set")
          sys.exit(0)
      open(path, "w", encoding="utf-8").write(text.replace(block, new_block))
      print("installRefunctAP: set Refunct launch options in", path)
      PY
          else
            echo "installRefunctAP: $config_xml missing; skipping launch-options upsert"
          fi
        fi
    '';
}
