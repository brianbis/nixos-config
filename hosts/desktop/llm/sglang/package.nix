# The sglang runtime, assembled as a self-contained Python venv.
#
# This is the "curated assembly" build: the heavy CUDA pieces (torch cu130,
# sgl-kernel, the nvidia-* CUDA runtime wheels) and the sglang package itself
# are hash-pinned binary wheels fetched hermetically (fetchurl, sha256), NOT
# compiled from source. The pure-Python long tail is the same pinned set.
#
# Why a venv rather than a from-source build:
#   - sglang 0.5.19 ships no cp314 wheel and its CUDA dep graph (torch 2.13.0
#     + ~30 nvidia-* wheels + sgl-kernel) is a multi-GB binary stack that is
#     not in nixpkgs. Rebuilding any of it from source is hours of CUDA
#     compilation with real version-mismatch risk.
#   - A digest-pinned wheel assembly is the same "pinned binary" stance the
#     repo already takes for the vLLM docker image, minus the container
#     runtime: the result is a native process, not a docker container.
#
# The venv's interpreter is a symlink into the nixpkgs python312 store; the
# CUDA libraries live inside the venv (the nvidia-* wheels). The host only
# needs the NVIDIA driver (libcuda.so.1), exactly like the ninfer services.
#
# Reproducibility: every wheel is pinned by sha256 in ./wheelhouse.nix and
# every package version is pinned in ./requirements.txt (generated from
# `uv pip compile` of the three top-level pins). Re-running the build yields
# the identical venv.

{ stdenv
, lib
, python312
, uv
, fetchurl
, patchelf
  # Host shared libraries the venv's compiled (manylinux) extensions expect from
  # a standard /usr/lib. Nix has no /usr/lib and the venv interpreter's rpath only
  # covers its own C runtime, so we bundle these into $out/lib and the service adds
  # it to LD_LIBRARY_PATH. (The CUDA runtime ships inside the nvidia-* wheels; the
  # host supplies only libcuda.so.1 via the driver.)
, zlib              # libz.so.1 — numpy's bundled OpenBLAS
, libsndfile        # libsndfile.so — audio I/O, loaded via ctypes by sglang.srt
, flac              # libFLAC.so.14 — libsndfile dep
, lame              # libmp3lame.so  — libsndfile dep
, libmpg123         # libmpg123.so   — libsndfile dep
, libogg            # libogg.so      — libsndfile dep
, libopus           # libopus.so     — libsndfile dep
, libvorbis         # libvorbis*.so  — libsndfile dep
, alsa-lib          # libasound.so   — libsndfile dep (Linux)
  # torchcodec (a video-decode dep sglang imports at startup) links against
  # FFmpeg. The wheel ships prebuilt variants for FFmpeg 4-8 and loads the
  # highest whose libs resolve; the default nixpkgs ffmpeg is 9.x (unsupported),
  # so pin ffmpeg_8 (libavutil.so.60 / libavcodec.so.62 / ... = the "core8" set).
  # Only the 7 core FFmpeg libs are bundled; each carries a store RUNPATH to its
  # own transitive codecs (x264, vpx, dav1d, ...), so they resolve at runtime.
  , ffmpeg_8          # libav*/libsw* — torchcodec's FFmpeg 8 ABI
  # A full, self-consistent CUDA toolkit (nvcc + headers + cicc/nvvm) for the
  # FlashInfer JIT. The JIT's CCCL (libcu++) cuda_toolkit.h check aborts the
  # build when the nvcc compiler's version disagrees with the toolkit headers'
  # CUDART_VERSION. The venv's own nvidia/cu13 cannot serve as the JIT home:
  # the pip nvidia-cuda-nvcc wheel (13.4.59) and the nvidia-cuda-runtime
  # wheel's headers (13.0.96) disagree, so the check fails. The nixpkgs
  # toolkit is one self-consistent version, so it passes. It is unfree (CUDA
  # EULA) — enabled narrowly by the flake for this input alone, exactly as the
  # vLLM DFlash2 runtime does.
  , cudaToolkit
}:

let
  # name -> { url, sha256, filename } for every pinned wheel/sdist.
  wheelSpecs = import ./wheelhouse.nix;

  # The C/C++ runtime plus the host libs above, bundled into $out/lib so the
  # venv is self-contained. stdenv.cc.cc.lib provides libstdc++.so.6 and
  # libgcc_s.so.1 (needed by every C++ extension: numpy, torch, sgl-kernel).
  #
  # Several of these packages list "bin" (or a header-only "out") first in
  # their `outputs`, so the default attr is NOT the one that ships the shared
  # library. Reference the output that actually contains the .so: `.out` for
  # most, `.lib` for lame.
  runtimeLibs = [
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
    # The FFmpeg 8 core libs (libav*/libsw*) for torchcodec; only the `.lib`
    # output holds the shared objects. Their transitive codecs resolve via
    # each lib's own store RUNPATH, so no external codec packages are bundled.
    ffmpeg_8.lib
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

  # A single directory holding every wheel/sdist, so `uv` can resolve the
  # whole pinned graph offline (--no-index --find-links).
  wheelhouse = stdenv.mkDerivation {
    pname = "sglang-wheelhouse";
    version = "1";

    # The wheels are referenced directly in installPhase below (${wheels.n}),
    # which registers them as derivation inputs WITHOUT putting them in
    # buildInputs. Putting the raw .whl files in buildInputs makes stdenv try
    # to `source` them (they are binary zip archives) and the build aborts
    # with "cannot execute binary file".
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

  # The pinned top-level + transitive set (name==version, one per line).
  requirements = ./requirements.txt;

in
stdenv.mkDerivation {
  pname = "sglang";
  version = "0.5.19";

  # uv assembles the venv. Every artifact in the set is a prebuilt wheel
  # (cuda-tile included — it is pinned as its pypi.nvidia.com cp312 wheel, not
  # the wheel-stub sdist), so uv installs purely from wheels and never
  # compiles anything; no C toolchain is needed. patchelf repoints the CUDA
  # toolkit's generic-Linux executables (nvcc & friends) at the NixOS loader.
  nativeBuildInputs = [ uv patchelf ];

  buildInputs = [ python312 wheelhouse ] ++ runtimeLibs;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    # uv wants a writable cache; the Nix build HOME is read-only, so point
    # it at a build-local directory.
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
    ln -s $out/venv/bin/sglang $out/bin/sglang
    ln -s $out/venv/bin/python $out/bin/python

    # Bundle the host shared libraries the venv's compiled extensions need.
    # The manylinux wheels expect a standard /usr/lib (libstdc++, libz, the
    # audio stack); Nix has none, and the venv interpreter's rpath only covers
    # its own C runtime, so these would otherwise fail to load at import time
    # (e.g. numpy's _multiarray_umath needs libstdc++.so.6 / libz.so.1). Copy
    # every .so* from the C/C++ runtime, zlib, and the audio stack into
    # $out/lib so the venv is self-contained; the service adds $out/lib to
    # LD_LIBRARY_PATH. (The CUDA runtime ships in the nvidia-* wheels; the
    # host supplies only libcuda.so.1 via the driver.)
    mkdir -p $out/lib
    for p in ${lib.concatStringsSep " " runtimeLibs}; do
      for d in "$p/lib" "$p/lib64"; do
        [ -d "$d" ] && find "$d" -maxdepth 1 -name '*.so*' -exec cp -aL {} "$out/lib/" \;
      done
    done
    # Sanity: the C++ runtime, the audio lib, and the FFmpeg core must have
    # landed.
    test -e "$out/lib/libstdc++.so.6"
    test -e "$out/lib/libsndfile.so.1"
    test -e "$out/lib/libavutil.so.60"

    # The CUDA toolkit (nvidia/cu13) ships generic-Linux ELF executables
    # (nvcc, ptxas, cicc, cudafe++, ...) whose interpreter is
    # /lib64/ld-linux-x86-64.so.2 — a path NixOS's stub ld-linux refuses
    # ("cannot run dynamically linked executables intended for generic
    # linux"). deep_ep JIT-compiles its kernels at import by invoking nvcc,
    # which in turn drives cudafe++/cicc/ptxas, so they must actually run.
    # Repoint each at the NixOS glibc loader and give them an rpath covering
    # the C runtime + the toolkit's own libs.
    cudaHome=$out/venv/lib/python3.12/site-packages/nvidia/cu13
    for dir in "$cudaHome/bin" "$cudaHome/nvvm/bin"; do
      for f in "$dir"/*; do
        [ -f "$f" ] || continue
        # Only dynamically-linked executables carry a program interpreter;
        # skip scripts, the crt/ dir, and the nvcc.profile text file.
        interp=$(patchelf --print-interpreter "$f" 2>/dev/null || true)
        [ -n "$interp" ] || continue
        patchelf --set-interpreter ${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2 \
          --set-rpath ${stdenv.cc.libc}/lib64:${stdenv.cc.libc}/lib:${stdenv.cc.cc.lib}/lib:"$cudaHome/lib" \
          "$f"
      done
    done
    # Sanity: nvcc must now request the NixOS loader, not the generic one.
    test "$(patchelf --print-interpreter "$cudaHome/bin/nvcc")" \
      = "${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2"

    # The triton wheel bundles the NVIDIA tools (ptxas, ptxas-blackwell,
    # cuobjdump, nvdisasm) under triton/backends/nvidia/bin with
    # PT_INTERP=/lib64/ld-linux-x86-64.so.2. NixOS has no /lib64 symlink, so
    # the kernel returns ENOEXEC when triton probes them (`--version`) and
    # reports "Cannot find ptxas-blackwell" on the first kernel compile
    # (triton selects ptxas-blackwell for the RTX 5090, arch >= 100). Make
    # each one self-contained: point the interpreter at the glibc loader and
    # the RUNPATH at the glibc and libstdc++ store dirs (both already in this
    # derivation's closure, so no new runtime deps).
    TRITON_BIN=$out/venv/lib/python3.12/site-packages/triton/backends/nvidia/bin
    for tool in ptxas ptxas-blackwell cuobjdump nvdisasm; do
      [ -f "$TRITON_BIN/$tool" ] || {
        echo "error: $TRITON_BIN/$tool not found (triton layout changed?)" >&2
        exit 1
      }
      patchelf --set-interpreter ${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2 \
        --set-rpath ${stdenv.cc.libc}/lib:${stdenv.cc.libc}/lib64:${stdenv.cc.cc.lib}/lib \
        "$TRITON_BIN/$tool"
    done
    # Sanity: the Blackwell ptxas must now request the NixOS loader — it is
    # the one triton probes first on this GPU.
    test "$(patchelf --print-interpreter "$TRITON_BIN/ptxas-blackwell")" \
      = "${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2"

    # The ninja wheel (ninja==1.13.2) installs a manylinux ELF at
    # venv/bin/ninja with the same PT_INTERP. flashinfer's run_ninja() invokes
    # bare `ninja` on the unit's PATH (the service prepends the venv bin) to
    # drive its XQA JIT build, so it must exec: same patchelf fix.
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

    # Assemble the FlashInfer-JIT CUDA home ($out/cuda-home). flashinfer's
    # get_cuda_path() returns $CUDA_HOME verbatim (short-circuiting its
    # `which nvcc` probe), then its ninja build needs:
    #   - $CUDA_HOME/bin/nvcc  (nvcc self-locates nvvm/bin/cicc via
    #     /proc/self/exe, so bin + nvvm must sit side by side)
    #   - $CUDA_HOME/include   (the CUDA headers)
    #   - -L$CUDA_HOME/lib64 -L$CUDA_HOME/lib64/stubs -lcudart -lcuda
    # The venv's own nvidia/cu13 cannot serve as this home: the pip
    # nvidia-cuda-nvcc wheel (13.4.59) and the nvidia-cuda-runtime wheel's
    # headers (13.0.96) disagree, so the CCCL (libcu++) cuda_toolkit.h
    # compatibility check ("CUDA compiler and CUDA toolkit headers are
    # incompatible") aborts every JIT compile. The nixpkgs toolkit is one
    # self-consistent version (nvcc + headers + cicc/nvvm), so the check
    # passes. bin/include/nvvm are NixOS-native (store glibc loader — no
    # patchelf needed); lib64 is a real dir holding the venv's own libcudart
    # (the same nvidia-cuda-runtime wheel copy torch links, so the JIT'd
    # module and torch share one cudart) plus a libcuda.so link stub with
    # SONAME libcuda.so.1 (the real driver lib is supplied by the host at
    # /run/opengl-driver/lib at runtime). This mirrors the vLLM DFlash2
    # runtime's $out/cuda-home exactly.
    CUDA_HOME_DIR=$out/cuda-home
    VENV_CUDART=$out/venv/lib/python3.12/site-packages/nvidia/cu13/lib
    [ -f "$VENV_CUDART/libcudart.so.13" ] || {
      echo "error: $VENV_CUDART/libcudart.so.13 not found (nvidia-cuda-runtime layout changed?)" >&2
      exit 1
    }
    mkdir -p "$CUDA_HOME_DIR/lib64/stubs" "$CUDA_HOME_DIR/bin"
    # The nixpkgs cuda_nvcc package's nvcc.profile points INCLUDES at the
    # cuda_nvcc package's own include dir, which ships ONLY fatbinary_section.h
    # (the cuda_nvcc redist does not bundle the CUDA runtime headers).
    # cuda_runtime.h lives in the cuda_cudart redist, merged into
    # ${cudaToolkit}/include. nvcc reads its nvcc.profile from the directory of
    # the (real) nvcc executable via /proc/self/exe, so a symlinked bin/nvcc
    # still resolves to the cuda_nvcc package's header-less profile and every
    # JIT compile (sgl_kernel, flashinfer) fails with
    # "cuda_runtime.h: No such file or directory". Copy the nvcc binary
    # (following the symlink) into a real bin/ dir and install a custom
    # nvcc.profile whose INCLUDES point at the merged toolkit include (which
    # has cuda_runtime.h). The other nvcc tools are located via the profile's
    # PATH (pointed at the merged toolkit bin), so no other copies are needed.
    cp -L ${cudaToolkit}/bin/nvcc "$CUDA_HOME_DIR/bin/nvcc"
    printf '%s\n' \
      'TOP = $(_HERE_)/..' \
      "CICC_PATH = ${cudaToolkit}/nvvm/bin" \
      "NVVMIR_LIBRARY_DIR = ${cudaToolkit}/nvvm/libdevice" \
      "LD_LIBRARY_PATH += ${cudaToolkit}/lib:${cudaToolkit}/lib64:" \
      "PATH += ${cudaToolkit}/nvvm/bin:${cudaToolkit}/bin:\$(_HERE_):" \
      "INCLUDES += \"-I${cudaToolkit}/include\"" \
      "SYSTEM_INCLUDES += \"-isystem\" \"${cudaToolkit}/include\"" \
      "compiler-bindir = ${stdenv.cc}/bin" \
      > "$CUDA_HOME_DIR/bin/nvcc.profile"
    # Sanity: the copied nvcc and its profile must be present.
    test -x "$CUDA_HOME_DIR/bin/nvcc"
    test -e "$CUDA_HOME_DIR/bin/nvcc.profile"
    ln -s ${cudaToolkit}/include "$CUDA_HOME_DIR/include"
    ln -s ${cudaToolkit}/nvvm "$CUDA_HOME_DIR/nvvm"
    ln -s "$VENV_CUDART/libcudart.so.13" "$CUDA_HOME_DIR/lib64/libcudart.so.13"
    ln -s libcudart.so.13 "$CUDA_HOME_DIR/lib64/libcudart.so"
    # A printf pipe, not a heredoc: a column-0 terminator would confuse
    # nixfmt's string-indent heuristic and the re-indent would break it.
    printf 'int __flashinfer_libcuda_link_stub;\n' \
      | ${stdenv.cc}/bin/c++ -shared -Wl,-soname,libcuda.so.1 \
        -o "$CUDA_HOME_DIR/lib64/stubs/libcuda.so" -x c -
  '';

  # The venv is self-contained: interpreter symlink, the CUDA runtime (the
  # nvidia-* wheels, with the toolkit's nvcc/ptxas/cicc executables repointed
  # at the NixOS loader), and the host C/C++ + audio libs bundled under /lib.
  # The host supplies only the NVIDIA driver (libcuda.so.1) at runtime, exactly
  # like the ninfer services.

  meta = with lib; {
    description = "SGLang fast serving framework (pinned CUDA wheel assembly, python312)";
    longDescription = ''
      SGLang runtime assembled from hash-pinned wheels (torch 2.13.0 cu130,
      sgl-kernel 0.4.6.post1, sglang 0.5.19 + the nvidia-* CUDA runtime) on
      nixpkgs python312. Serves the OpenAI-compatible API; run via `sglang serve`.
    '';
    license = licenses.asl20;
    platforms = platforms.linux;
  };
}
