# TabbyAPI + EXL3 (exllamav3) runtime as a self-contained python312 venv.
#
# Assembled from hash-pinned binary wheels (exllamav3 1.5.1+cu132.torch2.13.0,
# torch 2.13.0+cu132, triton 3.7.1 cu132, the nvidia-* CUDA 13.2 runtime, and
# tabbyAPI's dependencies), fetched hermetically (fetchurl, sha256) and never
# compiled — same pinned-binary stance as ../sglang/package.nix. The host only
# needs the NVIDIA driver (libcuda.so.1); the CUDA runtime ships in the
# nvidia-* wheels.
#
# The tabbyAPI app itself is not a wheel: its pyproject declares
# `py-modules = []` and the official NVIDIA cu13 image copies the source tree
# and runs `python3 main.py --config ...`. We do the same from the bare repo,
# pinned by the `tabbyapi` flake input.
#
# Both binaries are sourced from their true bases on GitHub via flake inputs:
#   - `nix flake update tabbyapi` re-pins the API server source
#   - `nix flake update exllamav3` re-pins the engine: the release wheel is
#     selected by the version in the input's exllamav3/version.py (a new
#     version without a pinned sha256 fails the build with the wheel URL to
#     hash — see ./wheelhouse.nix)

{ stdenv
, lib
, python312
, uv
, fetchurl
, writeText
, patchelf
  # Host shared libs the venv's compiled (manylinux) extensions expect from a
  # standard /usr/lib; bundled into $out/lib (the service adds it to
  # LD_LIBRARY_PATH).
, zlib              # libz.so.1 — numpy's bundled OpenBLAS, pillow
, exllamav3Src      # flake input: github:turboderp-org/exllamav3
, tabbyapiSrc       # flake input: github:theroyallab/tabbyAPI
}:

let
  # The exllamav3 version from the flake input source (exllamav3/version.py:
  # `__version__ = "1.5.1"`).
  exllamav3Version = let
    raw = builtins.readFile (exllamav3Src + "/exllamav3/version.py");
    v = lib.trim (lib.removeSuffix "\n" (lib.removePrefix "__version__ = " raw));
  in lib.removeSuffix "\"" (lib.removePrefix "\"" v);

  # name -> { url, sha256, filename } for every pinned wheel; the exllamav3
  # entry is version-keyed (see the file header).
  wheelSpecs = import ./wheelhouse.nix exllamav3Version;

  # C/C++ runtime + the host libs above, bundled into $out/lib so the venv is
  # self-contained.
  runtimeLibs = [
    stdenv.cc.cc.lib
    zlib
  ];

  wheelNames = builtins.attrNames wheelSpecs;

  # One hermetic fetchurl per artifact (sha256-pinned; verified on download).
  wheels = lib.mapAttrs
    (
      name: spec: fetchurl {
        inherit (spec) url sha256;
        # Keep the original filename so `uv --find-links` sees proper wheels.
        name = spec.filename;
      }
    )
    wheelSpecs;

  # One dir holding every wheel, so uv resolves the pinned graph offline
  # (--no-index --find-links).
  wheelhouse = stdenv.mkDerivation {
    pname = "tabbyapi-wheelhouse";
    version = "1";

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      mkdir -p $out
      ${lib.concatStringsSep "\n" (
        map (n: "cp ${wheels.${n}} $out/${wheelSpecs.${n}.filename}") wheelNames
      )}
    '';
  };

  # The pinned set with the exllamav3 version label substituted in.
  requirements = writeText "tabbyapi-requirements.txt" (
    lib.replaceStrings
      ["@exllamav3VersionLabel@"]
      [wheelSpecs.exllamav3.versionLabel]
      (builtins.readFile ./requirements.txt)
  );

in
stdenv.mkDerivation {
  pname = "tabbyapi-exl3";
  version = exllamav3Version;

  # uv assembles the venv purely from prebuilt wheels, so nothing compiles;
  # patchelf repoints the generic-Linux ELF executables (ninja, triton tools)
  # at the NixOS loader.
  nativeBuildInputs = [ uv patchelf ];

  buildInputs = [ python312 wheelhouse ] ++ runtimeLibs;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    # uv needs a writable cache; the Nix build HOME is read-only.
    export UV_CACHE_DIR="$(mktemp -d)"

    # A venv rooted in $out, backed by the nixpkgs python312 interpreter.
    uv venv $out/venv --python ${python312}/bin/python3.12

    # Install the exact pinned set, offline, from the local wheelhouse.
    uv pip install \
      --python $out/venv/bin/python \
      --no-index \
      --find-links ${wheelhouse} \
      -r ${requirements}

    # Thin entry points so the service can run a stable path.
    mkdir -p $out/bin
    ln -s $out/venv/bin/python $out/bin/python3
    ln -s $out/venv/bin/python $out/bin/python

    # The tabbyAPI app (run with the venv python; it reads config.yml from
    # the working directory at runtime — the service sets WorkingDirectory).
    mkdir -p $out/app
    cp -a ${tabbyapiSrc}/. $out/app/
    test -f "$out/app/main.py"

    # Bundle the host shared libs the venv's compiled extensions need
    # (manylinux wheels expect a standard /usr/lib); the service adds $out/lib
    # to LD_LIBRARY_PATH. CUDA runtime ships in the nvidia-* wheels.
    mkdir -p $out/lib
    for p in ${lib.concatStringsSep " " runtimeLibs}; do
      for d in "$p/lib" "$p/lib64"; do
        [ -d "$d" ] && find "$d" -maxdepth 1 -name '*.so*' -exec cp -aL {} "$out/lib/" \;
      done
    done
    # Sanity: the C++ runtime must have landed.
    test -e "$out/lib/libstdc++.so.6"

    # The ninja wheel (ninja==1.13.2) installs a manylinux ELF at venv/bin/ninja
    # with PT_INTERP=/lib64/ld-linux-x86-64.so.2, which NixOS's stub ld-linux
    # refuses. exllamav3 declares ninja and JIT-compiles kernels with it at
    # import, so repoint it at the NixOS glibc loader (same fix as the sglang
    # runtime).
    NINJA=$out/venv/bin/ninja
    [ -f "$NINJA" ] || {
      echo "error: $NINJA not found (ninja wheel layout changed?)" >&2
      exit 1
    }
    patchelf --set-interpreter ${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2 \
      --set-rpath ${stdenv.cc.libc}/lib:${stdenv.cc.libc}/lib64:${stdenv.cc.cc.lib}/lib \
      "$NINJA"
    test "$(patchelf --print-interpreter "$NINJA")" \
      = "${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2"

    # The triton wheel (a torch dep) bundles the NVIDIA tools (ptxas,
    # ptxas-blackwell, cuobjdump, nvdisasm) under triton/backends/nvidia/bin
    # with the same generic PT_INTERP. exllamav3 does not drive triton, but
    # patch them for the same reason (cheap insurance if a code path probes
    # them).
    TRITON_BIN=$out/venv/lib/python3.12/site-packages/triton/backends/nvidia/bin
    if [ -d "$TRITON_BIN" ]; then
      for tool in ptxas ptxas-blackwell cuobjdump nvdisasm; do
        [ -f "$TRITON_BIN/$tool" ] || continue
        patchelf --set-interpreter ${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2 \
          --set-rpath ${stdenv.cc.libc}/lib:${stdenv.cc.libc}/lib64:${stdenv.cc.cc.lib}/lib \
          "$TRITON_BIN/$tool"
      done
    fi
  '';

  meta = with lib; {
    description = "TabbyAPI + EXL3 (exllamav3) LLM runtime (pinned CUDA wheel assembly, python312)";
    longDescription = ''
      TabbyAPI (the OpenAI-compatible EXL3 API server) + the exllamav3 CUDA
      inference engine, assembled from hash-pinned wheels (exllamav3
      1.5.1+cu132.torch2.13.0, torch 2.13.0+cu132, triton 3.7.1 cu132, the
      nvidia-* CUDA 13.2 runtime) on nixpkgs python312. The tabbyAPI app
      source is pinned from the bare repo. Serves the OpenAI-compatible API.
    '';
    license = licenses.asl20;
    platforms = platforms.linux;
  };
}
