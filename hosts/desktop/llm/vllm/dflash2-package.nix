# Native (non-docker) vLLM runtime for the Qwen3.8 DFlash2 release: the
# undockerified counterpart to the community
# `seanyourhighness/vllm-sm12x-nvfp4-dflash2` image, assembled the same way
# the SGLang runtime is (../sglang/package.nix) — a self-contained python312
# venv from a pinned binary + pinned dep graph, no container runtime.
#
# The image is built from upstream vLLM v0.27.1 (commit 6e448d0ea) + the 0001
# all-NVFP4 DFlash2 overlay (51 Python files) + the official Dockerfile (CUDA
# 13.0.3, FlashInfer 0.6.16.post3). Both overlays are PYTHON-ONLY (they do not
# touch the compiled CUDA kernels), so the native equivalent is the stock vLLM
# v0.27.1 wheel (which bundles the matching CUDA stack — torch 2.13.0 cu13,
# cuda-toolkit 13.0.3, flashinfer-python 0.6.16.post3, the same versions the
# fork pins) with the two overlays applied to the installed `vllm` package,
# exactly what the fork's Dockerfile.vision-mrope does.
#
# The build sandbox has no network, so every wheel is fetched up-front via
# fetchurl (sha256-pinned) into a local wheelhouse and the venv is installed
# fully offline (`uv pip install --no-index --find-links`), mirroring the
# SGLang wheelhouse. The two DFlash2 overlays are pinned by the fork's release
# revision + sha256 (verified against the fork's SHA256SUMS). The host
# supplies only the NVIDIA driver (libcuda.so.1); the CUDA runtime ships
# inside the venv (the nvidia-* wheels).
#
# $out/cuda-home: a CUDA home for FlashInfer's runtime JIT — the XQA decode
# kernel is compiled at first decode with nvcc + ninja (flashinfer/jit/
# cpp_ext.py), which needs a real toolkit root ($CUDA_HOME/bin/nvcc,
# $CUDA_HOME/include, -L$CUDA_HOME/lib64 -L$CUDA_HOME/lib64/stubs -lcudart
# -lcuda). The pip nvidia-cuda-nvcc wheel ships only the nvcc driver (no
# nvvm/bin/cicc), so the toolkit comes from nixpkgs' cudaPackages_13.cudatoolkit
# (unfree, CUDA EULA — enabled narrowly by the flake). In the docker image
# this was /usr/local/cuda. It lives inside the single `out` output because
# the Nix daemon relocates a top-level `include` out of a non-primary output
# during fixupPhase (see the outputs comment below).

{ stdenv
, lib
, python312
, uv
, fetchurl
, patch
, patchelf
, cudaToolkit
}:

let
  vllmVersion = "0.27.1";

  # name -> { url, sha256, filename } for every pinned wheel (196 total, incl.
  # the vllm wheel itself), auto-generated against PyPI for the exact resolved
  # dependency set (cp312 / manylinux x86_64).
  wheelSpecs = import ./dflash2-wheelhouse.nix;

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
    pname = "vllm-dflash2-wheelhouse";
    version = "1";

    # The wheels are referenced directly in installPhase (${wheels.n}), which
    # registers them as derivation inputs WITHOUT buildInputs (raw .whl files
    # in buildInputs make stdenv try to `source` them and abort).
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

  # The community DFlash2 overlays, pinned by the fork's release revision +
  # sha256 (both verified against the fork's SHA256SUMS).
  forkRev = "fdb45641d9ef7d663b633037467b6949f1daecf7";
  forkBase =
    "https://raw.githubusercontent.com/seanyourhighness/vllm-sm12x-nvfp4-dflash2/${forkRev}";

  # All-NVFP4 DFlash2 K7 overlay (51 Python files).
  patch0001 = fetchurl {
    url = "${forkBase}/0001-v0271-sm12x-dflash2-nvfp4.patch";
    sha256 = "248adb629444f143975b28013bf29b6c5c65e04789f68aecf5915ea290f0773e";
  };

  # Fused M-RoPE vision overlay (2 production Python files + a CUDA test).
  patch0002 = fetchurl {
    url = "${forkBase}/0002-qwen3-next-fused-mrope-vision.patch";
    sha256 = "82d1a05364dce5151a02b02aa42b9893a05975e45207cdca9c4d87d92c093799";
  };

  # The exact resolved dependency graph for vllm==0.27.1 (python 3.12,
  # x86_64), one `name==version` per line (196 lines, incl. vllm itself);
  # generated once via `uv pip compile "vllm==0.27.1" --python-version 3.12
  # --no-annotate`.
  requirements = ./dflash2-requirements.txt;

in
stdenv.mkDerivation {
  pname = "vllm-dflash2";
  version = vllmVersion;

  # uv assembles the venv; patch applies the Python overlays; patchelf makes
  # the triton-bundled NVIDIA tools self-contained (see installPhase). Every
  # artifact is a prebuilt wheel; the only thing compiled is the libcuda.so
  # link stub under $out/cuda-home (stdenv.cc). stdenv.cc.cc.lib supplies the
  # C++ runtime (libstdc++) bundled into $out/lib for the dlopen'd C
  # extensions.
  nativeBuildInputs = [ uv patch patchelf ];
  buildInputs = [ python312 wheelhouse stdenv.cc.cc.lib ];

  # Single `out` output: the venv ($out/venv) plus the FlashInfer-JIT CUDA
  # home ($out/cuda-home, see installPhase). Deliberately NOT a second output —
  # the Nix daemon (2.34) relocates a top-level `include` out of a non-primary
  # output into the primary one during fixupPhase, which would leave
  # $CUDA_HOME/include missing at JIT time.

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    # uv wants a writable cache; the Nix build HOME is read-only.
    export UV_CACHE_DIR="$(mktemp -d)"

    # A venv rooted in $out, backed by the nixpkgs python312 interpreter.
    uv venv $out/venv --python ${python312}/bin/python3.12

    # Install the exact pinned set, offline, from the local wheelhouse. Every
    # artifact is a prebuilt wheel (torch 2.13 cu13, flashinfer 0.6.16.post3,
    # the nvidia-* CUDA runtime, the vllm wheel), so uv never compiles or
    # reaches the network.
    uv pip install \
      --python $out/venv/bin/python \
      --no-index \
      --find-links ${wheelhouse} \
      -r ${requirements}

    # Apply the DFlash2 overlays to the installed vllm package (Python-only).
    # Resolve site-packages via sysconfig (no `import vllm`, which would load
    # torch and its CUDA deps at build time); patch paths are vllm/... (strip
    # 1), so apply from the site-packages directory.
    SITE=$($out/venv/bin/python -c "import sysconfig; print(sysconfig.get_paths()['purelib'])")

    patch -p1 -d "$SITE" < ${patch0001}

    # The 0002 overlay carries a tests/ file not present in the wheel; keep
    # only its production vllm/ files (the same filter the fork's
    # Dockerfile.vision-mrope uses).
    awk '/^diff --git / { keep = ($3 ~ /^a\/vllm\//) } keep { print }' ${patch0002} \
      | patch -p1 -d "$SITE"

    # The triton wheel bundles the NVIDIA tools (ptxas, ptxas-blackwell,
    # cuobjdump, nvdisasm) under triton/backends/nvidia/bin with
    # PT_INTERP=/lib64/ld-linux-x86-64.so.2. NixOS has no /lib64 symlink, so
    # the kernel returns ENOEXEC when triton probes them (`--version`) and
    # reports "Cannot find ptxas-blackwell" on the first kernel compile.
    # Make each self-contained: interpreter at the glibc loader, RUNPATH at
    # the glibc and libgcc_s store dirs (already in this derivation's closure).
    # Verified hermetically: the unpatched binary fails to exec under `env -i`,
    # the patched one runs — including after stdenv's RPATH-shrink fixup.
    TRITON_BIN="$SITE/triton/backends/nvidia/bin"
    for tool in ptxas ptxas-blackwell cuobjdump nvdisasm; do
      [ -f "$TRITON_BIN/$tool" ] || {
        echo "error: $TRITON_BIN/$tool not found (triton layout changed?)" >&2
        exit 1
      }
      patchelf --set-interpreter ${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2 \
        --set-rpath ${stdenv.cc.libc}/lib:${stdenv.cc.libc}/lib64:${stdenv.cc.cc.lib}/lib \
        "$TRITON_BIN/$tool"
    done

    # The ninja wheel (ninja==1.13.2) installs a manylinux ELF at
    # venv/bin/ninja with the same PT_INTERP. flashinfer's run_ninja() invokes
    # bare `ninja` on the venv's PATH to drive the XQA JIT build, so same
    # patchelf fix.
    NINJA=$out/venv/bin/ninja
    [ -f "$NINJA" ] || {
      echo "error: $NINJA not found (ninja wheel layout changed?)" >&2
      exit 1
    }
    patchelf --set-interpreter ${stdenv.cc.libc}/lib64/ld-linux-x86-64.so.2 \
      --set-rpath ${stdenv.cc.libc}/lib:${stdenv.cc.libc}/lib64:${stdenv.cc.cc.lib}/lib \
      "$NINJA"

    # Assemble the FlashInfer-JIT CUDA home ($out/cuda-home). flashinfer's
    # get_cuda_path() returns $CUDA_HOME verbatim (short-circuiting its `which
    # nvcc` probe, which would fail: no `which` on the unit's PATH, no
    # /usr/local/cuda); its ninja build needs bin/nvcc + nvvm side by side
    # (nvcc self-locates nvvm/bin/cicc via /proc/self/exe), include/, and
    # -L$CUDA_HOME/lib64 -L$CUDA_HOME/lib64/stubs -lcudart -lcuda. The pip
    # nvidia-cuda-nvcc wheel is only the nvcc driver (no nvvm/bin/cicc device
    # compiler), so bin/include/nvvm come from the nixpkgs toolkit (a
    # NixOS-native build: every binary already carries the store glibc loader —
    # no patchelf needed). lib64 is a real dir holding the venv's own libcudart
    # (the same nvidia-cuda-runtime wheel copy torch links, so the JIT'd module
    # and torch share one cudart) plus a libcuda.so link stub with SONAME
    # libcuda.so.1 (the real driver lib is at /run/opengl-driver/lib at
    # runtime).
    CUDA_HOME_DIR=$out/cuda-home
    VENV_CUDART="$SITE/nvidia/cu13/lib"
    [ -f "$VENV_CUDART/libcudart.so.13" ] || {
      echo "error: $VENV_CUDART/libcudart.so.13 not found (nvidia-cuda-runtime layout changed?)" >&2
      exit 1
    }
    mkdir -p "$CUDA_HOME_DIR/lib64/stubs"
    ln -s ${cudaToolkit}/bin "$CUDA_HOME_DIR/bin"
    ln -s ${cudaToolkit}/include "$CUDA_HOME_DIR/include"
    ln -s ${cudaToolkit}/nvvm "$CUDA_HOME_DIR/nvvm"
    ln -s "$VENV_CUDART/libcudart.so.13" "$CUDA_HOME_DIR/lib64/libcudart.so.13"
    ln -s libcudart.so.13 "$CUDA_HOME_DIR/lib64/libcudart.so"
    # (A printf pipe, not a heredoc: a column-0 terminator would confuse
    # nixfmt's string-indent heuristic.)
    printf 'int __flashinfer_libcuda_link_stub;\n' \
      | ${stdenv.cc}/bin/c++ -shared -Wl,-soname,libcuda.so.1 \
        -o "$CUDA_HOME_DIR/lib64/stubs/libcuda.so" -x c -

    # Thin entry points so the service runs a stable path.
    mkdir -p $out/bin
    ln -s $out/venv/bin/vllm $out/bin/vllm
    ln -s $out/venv/bin/python $out/bin/python

    # Bundle the C++ runtime (libstdc++) so the venv's C-extension wheels
    # (torch, flashinfer, triton, ...) can dlopen it at runtime. PyPI wheels
    # carry no RPATH and the CPython interpreter is a C binary that does not
    # link libstdc++, so it is on neither loader path. Exposed at $out/lib;
    # the service prepends it to LD_LIBRARY_PATH. libstdc++.so.6 is
    # ABI-stable, so the stdenv's copy satisfies every wheel's NEEDED symbols.
    mkdir -p $out/lib
    for d in ${stdenv.cc.cc.lib}/lib ${stdenv.cc.cc.lib}/lib64; do
      if [ -f "$d/libstdc++.so.6" ]; then
        cp -L "$d/libstdc++.so.6" $out/lib/
        break
      fi
    done
    [ -f $out/lib/libstdc++.so.6 ] || {
      echo "error: libstdc++.so.6 not found in ${stdenv.cc.cc.lib}" >&2
      exit 1
    }
  '';

  meta = with lib; {
    description = "vLLM v0.27.1 + DFlash2 K7 all-NVFP4 overlays (pinned wheelhouse + Python patches, python312)";
    longDescription = ''
      Native (non-docker) vLLM v0.27.1 runtime for Blackwell (SM120/SM121):
      the pinned vLLM wheel (torch 2.13 cu13, flashinfer 0.6.16.post3) with the
      community all-NVFP4 DFlash2 K7 Python overlays applied. Serves the
      OpenAI-compatible API via `vllm serve`.
    '';
    license = licenses.asl20;
    platforms = platforms.linux;
  };
}
