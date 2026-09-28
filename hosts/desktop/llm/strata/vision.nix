# strata-vision: the optional image encoder (llama.cpp's mtmd library at the
# same pinned commit), GPU build (ggml-cuda, sm_120). Shipped as the engine
# app layout (strataEnginePkg's $out/app) plus the vision binary in
# $out/app/engine, so setup.py's vision=gpu config resolves both executables
# from the same engine directory.
{ stdenv
, lib
, cmake
, ninja
, cudaToolkit
, src
, llamaCpp
, engine
}:
let
  visionBin = stdenv.mkDerivation {
    pname = "strata-vision";
    version = "0.1.12";
    src = src;

    nativeBuildInputs = [ cmake ninja cudaToolkit ];
    buildInputs = [ cudaToolkit ];

    configurePhase = ''
      cmake -S tools/vision -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_DIR=${llamaCpp} \
        -DSTRATA_VISION_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES=120
    '';

    buildPhase = "cmake --build build --parallel --target strata-vision";

    installPhase = "install -Dm755 build/bin/strata-vision $out/bin/strata-vision";
  };
in
stdenv.mkDerivation {
  pname = "strata-vision-app";
  version = "0.1.12";

  src = engine;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ visionBin ];

  installPhase = ''
    cp -a ${engine}/app/. $out/app/
    install -Dm755 ${visionBin}/bin/strata-vision $out/app/engine/strata-vision
    test -s $out/app/engine/strata-vision
  '';

  meta = with lib; {
    description = "Strata app with the GPU vision encoder (mtmd, sm_120)";
    homepage = "https://github.com/Niko1221/Strata";
    license = unlicense;
    platforms = [ "x86_64-linux" ];
  };
}