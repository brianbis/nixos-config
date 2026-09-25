# SGLang runtime as a self-contained python312 venv assembled from
# hash-pinned binary wheels (torch 2.13.0 cu130, sgl-kernel, the nvidia-*
# CUDA runtime, sglang 0.5.19), fetched hermetically (fetchurl, sha256) and
# never compiled: the CUDA dep graph is a multi-GB binary stack not in
# nixpkgs. Same pinned-binary stance as the vLLM docker image, minus the
# container runtime. Wheels pinned in ./wheelhouse.nix; package versions in
# ./requirements.txt (uv pip compile of the three top-level pins). The host
# only needs the NVIDIA driver (libcuda.so.1), as with the ninfer services.

{ stdenv
, lib
, python312
, uv
, fetchurl
, patchelf
  # Host shared libs the venv's compiled (manylinux) extensions expect from a
  # standard /usr/lib; bundled into $out/lib (the service adds it to
  # LD_LIBRARY_PATH). CUDA runtime ships inside the nvidia-* wheels; the host
  # supplies only libcuda.so.1 via the driver.
, zlib              # libz.so.1 — numpy's bundled OpenBLAS
, libsndfile        # libsndfile.so — audio I/O via ctypes (sglang.srt)
, flac              # libsndfile codec deps
, lame
, libmpg123
, libogg
, libopus
, libvorbis
, alsa-lib
  # torchcodec (a video-decode dep imported at startup) links FFmpeg 4-8 and
  # loads the highest whose libs resolve; nixpkgs ffmpeg is 9.x (unsupported),
  # so pin ffmpeg_8. Only the 7 core libs bundled; transitive codecs resolve
  # via each lib's own store RUNPATH.
, ffmpeg_8
  # Self-consistent CUDA toolkit (nvcc + headers + cicc/nvvm) for the
  # FlashInfer JIT: the venv's pip wheels disagree on version (nvcc 13.4.59 vs
  # runtime headers 13.0.96), failing the CCCL cuda_toolkit.h check. Unfree
  # (CUDA EULA) — enabled narrowly by the flake, as for the vLLM DFlash2 runtime.
, cudaToolkit
}:

let
  # name -> { url, sha256, filename } for every pinned wheel/sdist.
  wheelSpecs = import ./wheelhouse.nix;

  # C/C++ runtime + the host libs above, bundled into $out/lib so the venv is
  # self-contained. Several packages list "bin" (or header-only "out") first in
  # `outputs`, so reference the output that ships the .so (.out for most, .lib
  # for lame).
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
    # Only the `.lib` output holds the FFmpeg 8 core libs (libav*/libsw*);
    # their transitive codecs resolve via each lib's own store RUNPATH.
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

  # One dir holding every wheel/sdist, so uv resolves the pinned graph offline
  # (--no-index --find-links).
  wheelhouse = stdenv.mkDerivation {
    pname = "sglang-wheelhouse";
    version = "1";

    # The wheels are referenced directly in installPhase below (${wheels.n}),
    # which registers them as derivation inputs WITHOUT buildInputs (raw .whl
    # files in buildInputs make stdenv try to `source` them and abort).
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

  # uv assembles the venv purely from prebuilt wheels (cuda-tile included —
  # pinned as its pypi.nvidia.com cp312 wheel, not the sdist stub), so nothing
  # compiles; patchelf repoints the CUDA toolkit's generic-Linux executables
  # (nvcc & friends) at the NixOS loader.
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
    ln -s $out/venv/bin/sglang $out/bin/sglang
    ln -s $out/venv/bin/python $out/bin/python

    # Bundle the host shared libs the venv's compiled extensions need
    # (manylinux wheels expect a standard /usr/lib); the service adds $out/lib
    # to LD_LIBRARY_PATH. CUDA runtime ships in the nvidia-* wheels.
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
    # (nvcc, ptxas, cicc, cudafe++, ...) with PT_INTERP=/lib64/ld-linux-x86-64.so.2,
    # which NixOS's stub ld-linux refuses. deep_ep JIT-compiles its kernels at
    # import by invoking nvcc (which drives cudafe++/cicc/ptxas), so repoint
    # each at the NixOS glibc loader with an rpath covering the C runtime +
    # the toolkit's own libs.
    cudaHome=$out/venv/lib/python3.12/site-packages/nvidia/cu13
    for dir in "$cudaHome/bin" "$cudaHome/nvvm/bin"; do
      for f in "$dir"/*; do
        [ -f "$f" ] || continue
        # Only dynamic executables carry a program interpreter; skip scripts,
        # the crt/ dir, and the nvcc.profile text file.
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
    # cuobjdump, nvdisasm) under triton/backends/nvidia/bin with the same
    # generic PT_INTERP. NixOS has no /lib64 symlink, so the kernel returns
    # ENOEXEC when triton probes them and reports "Cannot find
    # ptxas-blackwell" on the first kernel compile (triton selects
    # ptxas-blackwell for the RTX 5090, arch >= 100). Same patchelf fix:
    # interpreter at the glibc loader, RUNPATH at the glibc + libstdc++ store
    # dirs (already in this derivation's closure).
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
    # Sanity: ptxas-blackwell (triton's first probe on this GPU) must now
    # request the NixOS loader.
    test "$(patchelf --print-interpreter "$TRITON_BIN/ptxas-blackwell")" \
      = "${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2"

    # The ninja wheel (ninja==1.13.2) installs a manylinux ELF at venv/bin/ninja
    # with the same PT_INTERP. flashinfer's run_ninja() invokes bare `ninja`
    # on the unit's PATH (the service prepends the venv bin) to drive its XQA
    # JIT build, so same patchelf fix.
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
    # get_cuda_path() returns $CUDA_HOME verbatim (short-circuiting its `which
    # nvcc` probe); its ninja build needs bin/nvcc + nvvm side by side (nvcc
    # self-locates nvvm/bin/cicc via /proc/self/exe), include/, and
    # -L$CUDA_HOME/lib64 -L$CUDA_HOME/lib64/stubs -lcudart -lcuda. The venv's
    # own nvidia/cu13 cannot serve: the pip nvcc wheel (13.4.59) and runtime
    # headers (13.0.96) disagree, failing the CCCL (libcu++) compatibility
    # check; the nixpkgs toolkit is one self-consistent version. bin/include/
    # nvvm are NixOS-native (store glibc loader, no patchelf needed); lib64
    # holds the venv's own libcudart (the same nvidia-cuda-runtime wheel copy
    # torch links, so the JIT'd module and torch share one cudart) plus a
    # libcuda.so.1 link stub (the real driver lib is at /run/opengl-driver/lib
    # at runtime). Mirrors the vLLM DFlash2 runtime's $out/cuda-home exactly.
    CUDA_HOME_DIR=$out/cuda-home
    VENV_CUDART=$out/venv/lib/python3.12/site-packages/nvidia/cu13/lib
    [ -f "$VENV_CUDART/libcudart.so.13" ] || {
      echo "error: $VENV_CUDART/libcudart.so.13 not found (nvidia-cuda-runtime layout changed?)" >&2
      exit 1
    }
    mkdir -p "$CUDA_HOME_DIR/lib64/stubs" "$CUDA_HOME_DIR/bin"
    # The nixpkgs cuda_nvcc package's nvcc.profile points INCLUDES at a dir
    # shipping ONLY fatbinary_section.h (the cuda_nvcc redist does not bundle
    # the CUDA runtime headers; cuda_runtime.h lives in the cuda_cudart redist,
    # merged into ${cudaToolkit}/include). nvcc reads its profile from the
    # directory of the (real) nvcc executable via /proc/self/exe, so a
    # symlinked bin/nvcc still resolves to the header-less profile and every
    # JIT compile (sgl_kernel, flashinfer) fails with "cuda_runtime.h: No such
    # file or directory". Copy the real nvcc (following the symlink) and
    # install a custom profile whose INCLUDES point at the merged include;
    # the other nvcc tools are located via the profile's PATH.
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
    # nixfmt's string-indent heuristic.
    printf 'int __flashinfer_libcuda_link_stub;\n' \
      | ${stdenv.cc}/bin/c++ -shared -Wl,-soname,libcuda.so.1 \
        -o "$CUDA_HOME_DIR/lib64/stubs/libcuda.so" -x c -
  '';

  # Self-contained venv: interpreter symlink, the CUDA runtime (toolkit
  # executables repointed at the NixOS loader), and the host C/C++ + audio libs
  # bundled under /lib. The host supplies only the NVIDIA driver (libcuda.so.1).

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
