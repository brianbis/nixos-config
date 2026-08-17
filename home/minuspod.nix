{ pkgs, lib, ... }:
let
  # MinusPod: self-hosted, ad-free podcast server.
  # https://github.com/ttlequals0/MinusPod
  src = pkgs.fetchFromGitHub {
    owner = "ttlequals0";
    repo = "MinusPod";
    rev = "a93b3c5bfffa62111f9947096611524a50591ec9";
    hash = "sha256-ZVAe9GA1ROh0Ya9/vWVStVUI8vXASUM1QQuEsJJdmpw=";
  };

  # Offline npm dependency cache for the frontend, locked by package-lock.json.
  # The frontend sources (tsc + vite) run offline against this cache via
  # npmConfigHook, which sets HOME and npm_config_cache; copying the cache
  # into node_modules by hand fails because store paths are read-only.
  npmDeps = pkgs.fetchNpmDeps {
    src = src + "/frontend";
    hash = "sha256-ReA3NUVXNdHrxJ7aEmJmQbm4CK1ohbINblkXaIYAsck=";
  };

  # faster-whisper transcribes through CTranslate2, which needs a CUDA build to
  # run on the GPU. nixpkgs' ctranslate2 (C++ core) is CPU-only unless withCUDA
  # is set, and the python bindings hardwire `ctranslate2-cpp = pkgs.ctranslate2`
  # (top-level), so an in-set override alone won't help. Build a CUDA-enabled
  # top-level ctranslate2 and re-point the python ctranslate2/faster-whisper at
  # it. Mirrors the official GPU Dockerfile (ctranslate2==4.8.1 + CUDA 12.x).
  cudaCT2 = pkgs.ctranslate2.override {
    withCUDA = true;
    withCuDNN = true;
    cudaPackages = pkgs.cudaPackages;
  };

  # cuDNN/cuBLAS are dlopened by CTranslate2 at runtime, so expose their lib
  # dirs the same way the upstream container's LD_LIBRARY_PATH does.
  cudaLibPath = with pkgs.cudaPackages; lib.makeLibraryPath [
    cudnn
    libcublas
    cuda_cudart
  ];

  # Backend runtime: the Python app and all of its requirements, resolved
  # hermetically by nixpkgs (the repo's requirements.txt is pip-compiled and
  # hash-locked for the container, but pip cannot reach the network inside
  # the Nix build sandbox).
  #
  # All python312 patches for MinusPod live here (this override REPLACES any
  # other packageOverrides, so it must carry every fix MinusPod needs):
  #  - ctranslate2: build the C++ core with CUDA so faster-whisper can transcribe
  #    on the GPU, then re-point the python binding at it.
  #  - anthropic: its test chain (respx, starlette, httpx2, httpcore2,
  #    inline-snapshot, ...) is flaky/broken on python 3.12 at this nixpkgs pin;
  #    MinusPod only needs the library, so skip its tests.
  #  - inline-snapshot: drops the docs test that breaks on python 3.12 here.
  minuspodPython = pkgs.python312.override {
    packageOverrides = self: super: {
      ctranslate2 = super.ctranslate2.override {
        ctranslate2-cpp = cudaCT2;
      };
      inline-snapshot = super.inline-snapshot.overridePythonAttrs (old: {
        disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
          "tests/test_docs.py"
        ];
      });
      anthropic = super.anthropic.overridePythonAttrs (old: {
        doCheck = false;
        nativeCheckInputs = [ ];
        checkInputs = [ ];
      });
    };
  };

  pythonEnv = minuspodPython.withPackages (ps: [
    ps.faster-whisper
    ps.ctranslate2
    ps.anthropic
    ps.openai
    ps.flask
    ps.flask-compress
    ps.flask-limiter
    ps.gunicorn
    ps.requests
    ps.beautifulsoup4
    ps.pillow
    ps.feedparser
    ps.python-slugify
    ps.numpy
    ps.huggingface-hub
    ps.pyacoustid
    ps.rapidfuzz
    ps.scikit-learn
    ps.nh3
    ps.cryptography
    ps.pyjwt
    ps.defusedxml
  ]);

  minuspod = pkgs.stdenv.mkDerivation {
    pname = "minuspod";
    version = "2.88.3";

    inherit src npmDeps;

    # npmConfigHook runs `npm ci --offline` in this subdirectory.
    npmRoot = "frontend";

    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.npmHooks.npmConfigHook
      pkgs.makeWrapper
      # Referenced by makeWrapper at install time, so it must be an input.
      pythonEnv
    ];

    # The container hardcodes /app paths; resolve them relative to this
    # derivation's output instead.
    postPatch = ''
      substituteInPlace gunicorn.conf.py \
        --replace-fail 'src_dir = "/app/src"' \
          'src_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "src")'
      # Make Database respect MINUSPOD_DATA_DIR instead of hardcoded /app/data
      substituteInPlace src/database/__init__.py \
        --replace-fail 'def __new__(cls, data_dir: str = "/app/data"):' \
          'def __new__(cls, data_dir: str = None):'
      substituteInPlace src/database/__init__.py \
        --replace-fail 'def __init__(self, data_dir: str = "/app/data"):' \
          'def __init__(self, data_dir: str = None):'
      substituteInPlace src/database/__init__.py \
        --replace-fail '        self.data_dir = Path(data_dir)' \
          '        self.data_dir = Path(data_dir or __import__("os").environ.get("MINUSPOD_DATA_DIR", "/app/data"))'
    '';

    buildPhase = ''
      runHook preBuild
      pushd frontend
      npm run build
      popd
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      # Python backend (imported by gunicorn as `main_app`).
      mkdir -p $out/src
      cp -r src/. $out/src/
      # Copy version.py so app_version can read it from project root
      install -Dm644 version.py $out/version.py
      # Copy builtin assets for ad replacement
      mkdir -p $out/assets_builtin
      cp -r assets/. $out/assets_builtin/
      # Vite writes the built UI to static/ui (see frontend/vite.config.ts);
      # routes.py serves it from <repo root>/static/ui.
      mkdir -p $out/static
      cp -r static/ui $out/static/ui
      install -Dm644 gunicorn.conf.py $out/gunicorn.conf.py
      makeWrapper ${pythonEnv}/bin/gunicorn $out/bin/minuspod \
        --run 'export MINUSPOD_DATA_DIR="''${MINUSPOD_DATA_DIR:-$HOME/.local/share/minuspod}"; export HF_HOME="''${MINUSPOD_DATA_DIR}/.cache/huggingface"; export TRANSFORMERS_CACHE="''${MINUSPOD_DATA_DIR}/.cache/huggingface/transformers"; export MINUSPOD_PORT="''${MINUSPOD_PORT:-8001}"; export MINUSPOD_VERSION="2.88.3"; export WHISPER_DEVICE="cuda"' \
        --prefix PATH : ${lib.makeBinPath [ pkgs.ffmpeg ]} \
        --prefix LD_LIBRARY_PATH : ${cudaLibPath} \
        --prefix PYTHONPATH : $out/src \
        --add-flags "-c $out/gunicorn.conf.py main_app:app"
      runHook postInstall
    '';

    meta = with lib; {
      description = "Self-hosted ad-free podcast server";
      homepage = "https://github.com/ttlequals0/MinusPod";
      license = licenses.mit;
    };
  };
in {
  home.packages = [ minuspod ];

  # Runtime configuration for the local LLM proxy (see home/llm).
  home.sessionVariables = {
    MINUSPOD_LLM_PROVIDER = "openai";
    MINUSPOD_LLM_BASE_URL = "http://127.0.0.1:8787/v1";
    MINUSPOD_LLM_MODEL = "qwen3-8-27b-q8_0";
    MINUSPOD_TRANSCRIBE_PROVIDER = "local";
    MINUSPOD_MASTER_PASSPHRASE = "change-me";
  };

  xdg.desktopEntries.minuspod = {
    name = "MinusPod";
    genericName = "Ad-free podcast server";
    exec = "${minuspod}/bin/minuspod";
    icon = "podcast";
    terminal = false;
    categories = [ "AudioVideo" "Network" ];
    settings.Keywords = "podcast;ad;minuspod";
  };
}
