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
#     $out/app/engine, plus a BUILD.json carrying source "local" AND setup.py's
#     source fingerprints (src/vision_src) + the source's own version. setup.py's
#     build_engine reuses a source:"local" engine only when those fingerprints
#     match the current source (a `git pull`), so without them every start would
#     recompile the engine (and fail: no compiler/CUDA in the service).
{ stdenv
, lib
, cmake
, ninja
, python3
, cudaToolkit
, src
, llamaCpp
, version ? "0.1.30"   # cosmetic (store name); BUILD.json's version comes from the source
}:
stdenv.mkDerivation {
  inherit version;
  pname = "strata-engine";
  src = src;

  nativeBuildInputs = [ cmake ninja python3 cudaToolkit ];
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
    # BUILD.json: source "local" plus setup.py's own source fingerprints
    # (src/vision_src, computed exactly as setup.py's source_hash does) and the
    # source's own version. build_engine reuses this engine when the fingerprints
    # match, so a start never recompiles; a source change (new pin) changes them
    # and the flake rebuilds the engine.
    SRC=$src OUT=$out python3 - <<'PY'
    import hashlib, json, os, re
    ROOT = os.environ["SRC"]
    LLAMA_CPP_COMMIT = "3cf03257f219afbe7334045ff7c6a06ac68c627d"   # setup.py's LLAMA_CPP_COMMIT
    def source_hash(parts):
        h = hashlib.sha256(LLAMA_CPP_COMMIT.encode())
        for part in parts:
            base = os.path.join(ROOT, part)
            if os.path.isfile(base):
                files = [base]
            else:
                files = sorted(f for f in (os.path.join(dp, fn) for dp, dn, fns in os.walk(base) for fn in fns))
            for f in files:
                rel = os.path.relpath(f, ROOT).replace(os.sep, "/")
                with open(f, "rb") as fh:
                    data = fh.read().replace(b"\r\n", b"\n")
                h.update(rel.encode() + b"\0" + data)
        return h.hexdigest()[:16]
    m = re.search(r"project\(strata VERSION ([\d.]+)",
                  open(os.path.join(ROOT, "CMakeLists.txt"), encoding="utf-8").read())
    meta = {
        "version": m.group(1) if m else "0",
        "source": "local",
        "archs": [120],
        "ptx": False,
        "cuda": "${cudaToolkit.version}",
        "src": source_hash(("CMakeLists.txt", "src", "include", "third_party/ggml")),
        "vision_src": source_hash(("tools/vision",)),
    }
    with open(os.path.join(os.environ["OUT"], "app", "engine", "BUILD.json"), "w") as fh:
        json.dump(meta, fh)
    PY
  '';

  meta = with lib; {
    description = "Strata inference engine (sm_120) with the 512-expert Qwen3.8-Flash-Next GGUF app";
    homepage = "https://github.com/Niko1221/Strata";
    license = unlicense; # repo carries no LICENSE file at the pinned rev
    platforms = [ "x86_64-linux" ];
  };
}