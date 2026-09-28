# Strata engine (C++20/CUDA inference engine for Qwen3.8-Flash-Next GSQ-RCO
# GGUF MoE checkpoints) plus the vendored Python app (setup.py + serve/).
#
# This is setup.py's "compile instead" path, made declarative:
#   - CUDA targets for sm_120 (RTX 5090). CMAKE_CUDA_ARCHITECTURES is the plain
#     number 120, NOT "120a": CMakeLists' architecture guard
#     (`if(_base LESS 80)`) does a string comparison for non-numeric values and
#     FATAL_ERRORs on "120a". The published prebuilts use 120 + PTX; a plain
#     120 SASS build is fine on this single-card host.
#   - The ggml CPU backend (i-quant expert kernels; STRATA_NATIVE_EXPERTS is ON
#     by default) comes from the llama.cpp commit Strata pins
#     (setup.py's LLAMA_CPP_COMMIT), so no network FetchContent at build time.
#   - There is no install() rule in CMake; installPhase assembles the layout
#     setup.py expects: the app at $out/app with the built binaries in
#     $out/app/engine, plus a BUILD.json carrying source "local" so setup.py's
#     engine-install check passes without touching the network.
{ stdenv
, lib
, cmake
, ninja
, cudaToolkit
, src
, llamaCpp
, version ? "0.1.12"   # mkDerivation's sibling attrs are not in interpolation scope; the arg is
}:                      # what ${version} below (BUILD.json) sees.
stdenv.mkDerivation {
  inherit version;
  pname = "strata-engine";
  src = src;

  nativeBuildInputs = [ cmake ninja cudaToolkit ];
  buildInputs = [ cudaToolkit ];

  configurePhase = ''
    cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DSTRATA_ENABLE_CUDA=ON \
      -DCMAKE_CUDA_ARCHITECTURES=120 \
      -DSTRATA_GGML_DIR=${llamaCpp} \
      -DSTRATA_BUILD_TESTS=OFF
  '';

  buildPhase = "cmake --build build --parallel";

  installPhase = ''
    mkdir -p $out/app/engine
    cp -a $src/. $out/app/
    # The runtime contract (what the engine and server resolve at start):
    test -s $out/app/data/expert-profile.bin
    test -f $out/app/setup.py
    test -f $out/app/serve/server.py
    cp build/strata $out/app/engine/strata
    cp build/strata-device $out/app/engine/strata-device
    cat > $out/app/engine/BUILD.json <<EOF
    { "version": "${version}", "source": "local", "archs": [120], "ptx": false, "cuda": "${cudaToolkit.version}" }
    EOF
  '';

  meta = with lib; {
    description = "Strata inference engine (sm_120) with the 512-expert Qwen3.8-Flash-Next GGUF app";
    homepage = "https://github.com/Niko1221/Strata";
    license = unlicense; # repo carries no LICENSE file at the pinned rev
    platforms = [ "x86_64-linux" ];
  };
}