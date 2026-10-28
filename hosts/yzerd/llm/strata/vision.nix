# The GPU vision encoder (mtmd) for the strata app, built for THIS box's card
# (sm_89 / RTX 4090) — the desktop's twin (hosts/desktop/llm/strata/vision.nix)
# carries sm_120 for its RTX 5090. Same shape as the engine derivation: build
# tools/vision against the pinned llama.cpp, then graft the binary into the
# engine app's $app/engine so setup.py finds it (the launchers here run
# --vision cpu; the GPU encoder is the option setup.py offers, and shipping it
# keeps that switch working without a runtime compile).
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
    version = "0.1.30";
    src = src;

    nativeBuildInputs = [ cmake ninja cudaToolkit ];
    buildInputs = [ cudaToolkit ];

    configurePhase = ''
      cmake -S tools/vision -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DLLAMA_DIR=${llamaCpp} \
        -DSTRATA_VISION_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES=89
    '';

    buildPhase = "cmake --build build --parallel --target strata-vision";

    installPhase = ''
      install -Dm755 build/bin/strata-vision $out/bin/strata-vision
    '';
  };
in
stdenv.mkDerivation {
  pname = "strata-vision-app";
  version = "0.1.30";
  src = engine;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # The engine is an input, so its store path carries only the modes cp -a read
  # from it (dirs 555, files 444); restore the write bits setup.py needs to
  # rewrite the per-model config in the app dir.
  nativeBuildInputs = [ visionBin ];

  installPhase = ''
    mkdir -p $out
    cp -a ${engine}/app $out/app
    chmod -R u+w $out/app
    install -Dm755 ${visionBin}/bin/strata-vision $out/app/engine/strata-vision
    test -s $out/app/engine/strata-vision
  '';

  meta = with lib; {
    description = "Strata app with the GPU vision encoder (mtmd, sm_89)";
    license = unlicense;
    platforms = [ "x86_64-linux" ];
  };
}
