{ pkgs, lib, inputs, nvidiaDriver ? null, ... }:
let
  # Source from the flakeless `minuspod` input; `nix flake update minuspod` re-pins it.
  src = inputs.minuspod;

  # Offline npm cache for the frontend (tsc + vite run offline via npmConfigHook).
  npmDeps = pkgs.fetchNpmDeps {
    src = src + "/frontend";
    hash = "sha256-k0XfJSBbVU8lfh+Td2kHDus7dWZHLLZV7sRbznEVT5A=";
  };

  # faster-whisper needs a CUDA CTranslate2 (nixpkgs' core is CPU-only unless
  # withCUDA; the python binding hardwires the top-level ctranslate2).
  cudaCT2 = pkgs.ctranslate2.override {
    withCUDA = true;
    withCuDNN = true;
    cudaPackages = pkgs.cudaPackages;
  };

  # cuDNN/cuBLAS are dlopened by CTranslate2 at runtime; expose them via LD_LIBRARY_PATH.
  cudaLibPath = with pkgs.cudaPackages; lib.makeLibraryPath [
    cudnn
    libcublas
    cuda_cudart
  ];

  # Backend runtime, resolved hermetically by nixpkgs (pip can't reach the
  # network in the sandbox, so the repo's pip-compiled requirements.txt is not
  # used). python313: matches whisper-service's transcription stack; MinusPod's
  # deps (Flask 3, faster-whisper, the pin's ctranslate2 4.8.2) all build for
  # 3.13. (Formerly python312, when the pin predated a current withCUDA
  # ctranslate2.)
  minuspodPython = pkgs.python313.override {
    packageOverrides = self: super: {
      ctranslate2 = super.ctranslate2.override {
        ctranslate2-cpp = cudaCT2;
      };
      # docs test breaks at this pin (observed on python 3.12; kept for 3.13)
      inline-snapshot = super.inline-snapshot.overridePythonAttrs (old: {
        disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
          "tests/test_docs.py"
        ];
      });
      # MinusPod only needs the library; its test chain is unreliable at this pin.
      anthropic = super.anthropic.overridePythonAttrs (old: {
        doCheck = false;
        nativeCheckInputs = [ ];
        checkInputs = [ ];
      });
      # django is not a direct dependency of MinusPod; it enters the closure
      # only as a check-input chain of scikit-learn's interop tooling
      # (scikit-learn 1.9 -> narwhals -> ibis-framework -> factory-boy ->
      # django). Its test suite fails on python 3.13 at this pin (and the
      # metadata check on 5.2.17 always), and MinusPod never runs it:
      # skip the whole check phase.
      django = super.django.overridePythonAttrs (old: {
        pythonRelaxed = true;
        doCheck = false;
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
    # flask-limiter storage backend (RATE_LIMIT_STORAGE_URI=redis://…).
    ps.redis
  ]);

  minuspod = pkgs.stdenv.mkDerivation {
    pname = "minuspod";
    version = "2.97.4";

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
    # derivation's output. (Data-dir default needed no patch: upstream
    # Database() falls back to resolve_data_dir(), which reads MINUSPOD_DATA_DIR.)
    postPatch = ''
      substituteInPlace gunicorn.conf.py \
        --replace-fail 'src_dir = "/app/src"' \
          'src_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "src")'
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
      # Vite writes the built UI to static/ui, which routes.py serves from <repo root>.
      mkdir -p $out/static
      cp -r static/ui $out/static/ui
      install -Dm644 gunicorn.conf.py $out/gunicorn.conf.py
      makeWrapper ${pythonEnv}/bin/gunicorn $out/bin/minuspod \
        --run 'export MINUSPOD_DATA_DIR="''${MINUSPOD_DATA_DIR:-$HOME/.local/share/minuspod}"; export HF_HOME="''${MINUSPOD_DATA_DIR}/.cache/huggingface"; export TRANSFORMERS_CACHE="''${MINUSPOD_DATA_DIR}/.cache/huggingface/transformers"; export MINUSPOD_PORT="''${MINUSPOD_PORT:-8001}"; export MINUSPOD_VERSION="2.97.4"; export WHISPER_DEVICE="cuda"' \
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

  # LLM/transcription runtime config, shared by the interactive session and
  # the systemd user service so the two never drift.
  minuspodEnv = {
    MINUSPOD_LLM_PROVIDER = "openai";
    MINUSPOD_LLM_BASE_URL = "http://127.0.0.1:8787/v1";
    # Consolidated thinking mode; the router preset's default reasoning_effort is xhigh.
    MINUSPOD_LLM_MODEL = "qwen3-8-27b-q8_0-thinking";
    MINUSPOD_TRANSCRIBE_PROVIDER = "local";
    MINUSPOD_MASTER_PASSPHRASE = "change-me";
  };
in
{
  home.packages = [ minuspod ];

  # Runtime configuration for the local LLM proxy (see home/llm).
  home.sessionVariables = minuspodEnv;

  # Always-on user service (resident gunicorn, not a socket-activated idle
  # service). The wrapper already sets data dir, port, WHISPER_DEVICE=cuda, the
  # CUDA runtime lib path and PYTHONPATH; the service adds the LLM config and,
  # when an NVIDIA driver package is supplied, its lib dir so ctranslate2 can
  # dlopen libcuda.so.1 (not in the ldconfig cache — see whisper-service).
  systemd.user.services.minuspod = {
    Unit = {
      Description = "MinusPod ad-free podcast server";
      After = [ "network.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${minuspod}/bin/minuspod";
      WorkingDirectory = "%h";
      Restart = "on-failure";
      RestartSec = "5";
      Environment =
        lib.mapAttrsToList (name: value: "${name}=${value}") minuspodEnv
        ++ lib.optionals (nvidiaDriver != null) [
          "LD_LIBRARY_PATH=${nvidiaDriver}/lib"
        ];
    };
    Install.WantedBy = [ "default.target" ];
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
