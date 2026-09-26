# TabbyAPI + EXL3 (exllamav3) runtime as a self-contained Python venv.
#
# Undockerified counterpart to the `ghcr.io/0xsero/tabbyapi-exl3` container.
# The venv provides:
#   - tabbyapi (the OpenAI-compatible API server)
#   - exllamav3 (the EXL3 inference backend, CUDA C++ extension)
#   - torch + nvidia-* CUDA runtime (pinned wheels)
#
# The exllamav3 source is tracked via the flake input (`nix flake update
# exllamav3` re-pins it). The version from the source tree is used to select
# the matching pre-built wheel (or build from source if no wheel exists).
#
# STATUS: placeholder structure. The actual wheel set needs to be extracted
# from the 0xsero/tabbyapi-exl3 container and pinned in ./wheelhouse.nix
# (same pattern as ../sglang/wheelhouse.nix). Until then, this derivation
# produces the directory layout the service expects.

{ stdenv
, lib
, python312
, uv
, fetchurl
, patchelf
, exllamav3Src
, zlib
, libsndfile
, flac
, lame
, libmpg123
, libogg
, libopus
, libvorbis
, alsa-lib
, ffmpeg_8
}:

let
  # TODO: pin the actual wheel set (extracted from the 0xsero container).
  # For now, use a minimal placeholder that creates the expected layout.
  # The real implementation follows the same pattern as ../sglang/package.nix:
  #   1. wheelhouse.nix: name -> { url, sha256, filename } for every wheel
  #   2. requirements.txt: the pinned dependency set
  #   3. uv venv + uv pip install --no-index --find-links
  #   4. patchelf the CUDA toolkit executables
  #   5. Bundle host shared libs into $out/lib

  # The exllamav3 version (from the source tree's version file or git describe).
  # Used for logging / version pinning; the actual CUDA extension comes from
  # the pre-built wheel in the wheelhouse.
  exllamav3Version = "dev"; # TODO: derive from exllamav3Src

in
stdenv.mkDerivation {
  pname = "tabbyapi-exl3";
  version = exllamav3Version;

  nativeBuildInputs = [ uv patchelf ];
  buildInputs = [ python312 ] ++ [
    zlib
    libsndfile.out
    flac.out
    lame.lib
    libmpg123.out
    libogg.out
    libopus.out
    libvorbis.out
    alsa-lib
    ffmpeg_8.lib
  ];

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # The exllamav3 source (referenced so the flake input is in the closure;
  # a future build-from-source path will use it for the CUDA extension).
  exllamav3Source = exllamav3Src;

  installPhase = ''
    # Create the venv (placeholder: no wheels installed yet).
    export UV_CACHE_DIR="$(mktemp -d)"
    uv venv $out/venv --python ${python312}/bin/python3.12

    # Thin entry points (the service expects $out/bin/python3 + $out/main.py).
    mkdir -p $out/bin
    ln -s $out/venv/bin/python $out/bin/python3
    ln -s $out/venv/bin/python $out/bin/python

    # Placeholder main.py: the real one comes from the tabbyapi wheel.
    # For now, create a stub that prints the config and exits (so the
    # service unit can be tested end-to-end before the venv is complete).
    cat > $out/main.py << 'PYEOF'
#!/usr/bin/env python3
"""Placeholder tabbyapi entry point.

TODO: replace with the real tabbyapi main.py (from the tabbyapi wheel).
This stub exists so the socket-activated service can be tested.
"""
import sys

if "--config" in sys.argv:
    config_path = sys.argv[sys.argv.index("--config") + 1]
    print(f"tabbyapi (placeholder): would load config {config_path}", file=sys.stderr)
    print("tabbyapi (placeholder): engine not yet installed", file=sys.stderr)

# Keep the process alive (the idle wrapper expects a long-running child).
import time
try:
    while True:
        time.sleep(60)
except KeyboardInterrupt:
    pass
PYEOF
    chmod +x $out/main.py

    # Bundle host shared libs (same pattern as sglang).
    mkdir -p $out/lib
    for p in ${lib.concatStringsSep " " [
      stdenv.cc.cc.lib
      zlib
      libsndfile.out
      flac.out
      lame.lib
      libmpg123.out
      libogg.out
      libopus.out
      libvorbis.out
      alsa-lib
      ffmpeg_8.lib
    ]}; do
      for d in "$p/lib" "$p/lib64"; do
        [ -d "$d" ] && find "$d" -maxdepth 1 -name '*.so*' -exec cp -aL {} "$out/lib/" \;
      done
    done
    test -e "$out/lib/libstdc++.so.6"
  '';

  meta = with lib; {
    description = "TabbyAPI + EXL3 (exllamav3) LLM runtime (placeholder venv)";
    longDescription = ''
      Undockerified TabbyAPI + exllamav3 runtime for EXL3-quantized models.
      Currently a placeholder: the venv layout is correct but the actual
      tabbyapi + exllamav3 wheels are not yet installed. See the TODO in
      the source for the wheel extraction plan.
    '';
    license = licenses.asl20;
    platforms = platforms.linux;
  };
}
