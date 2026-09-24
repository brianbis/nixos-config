{ pkgs, lib, inputs, nvidiaDriver ? null, ... }:
let
  # Source from the flakeless `minuspod` input (see flake.nix);
  # `nix flake update minuspod` re-pins it.
  src = inputs.minuspod;

  # Offline npm dependency cache for the frontend (tsc + vite run offline via
  # npmConfigHook); copying the cache into node_modules by hand fails because
  # store paths are read-only.
  npmDeps = pkgs.fetchNpmDeps {
    src = src + "/frontend";
    hash = "sha256-k0XfJSBbVU8lfh+Td2kHDus7dWZHLLZV7sRbznEVT5A=";
  };

  # faster-whisper needs a CUDA-enabled CTranslate2 for GPU: nixpkgs' core is
  # CPU-only unless withCUDA, and the python binding hardwires the top-level
  # ctranslate2, so build a CUDA core and re-point the binding at it.
  cudaCT2 = pkgs.ctranslate2.override {
    withCUDA = true;
    withCuDNN = true;
    cudaPackages = pkgs.cudaPackages;
  };

  # cuDNN/cuBLAS are dlopened by CTranslate2 at runtime; expose their lib dirs
  # via LD_LIBRARY_PATH.
  cudaLibPath = with pkgs.cudaPackages; lib.makeLibraryPath [
    cudnn
    libcublas
    cuda_cudart
  ];

  # Backend runtime, resolved hermetically by nixpkgs: pip cannot reach the
  # network inside the Nix build sandbox, so the repo's requirements.txt
  # (pip-compiled for the container) is not used.
  minuspodPython = pkgs.python312.override {
    packageOverrides = self: super: {
      ctranslate2 = super.ctranslate2.override {
        ctranslate2-cpp = cudaCT2;
      };
      # docs test breaks on python 3.12 at this pin
      inline-snapshot = super.inline-snapshot.overridePythonAttrs (old: {
        disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
          "tests/test_docs.py"
        ];
      });
      # test chain is broken on python 3.12 at this pin; MinusPod only needs
      # the library, so skip its tests
      anthropic = super.anthropic.overridePythonAttrs (old: {
        doCheck = false;
        nativeCheckInputs = [ ];
        checkInputs = [ ];
      });
      # nixpkgs' pythonMetadataCheckPhase fails on 5.2.17 (metadata mismatch);
      # relax the check.
      django = super.django.overridePythonAttrs (old: {
        pythonRelaxed = true;
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
    # flask-limiter storage backend (RATE_LIMIT_STORAGE_URI=redis://…);
    # declared direct dep upstream, lazy-imported only when configured.
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
    # derivation's output instead. (The data-dir default needed no patch as
    # of 2.97.4: upstream Database() falls back to utils.paths.resolve_data_dir(),
    # which reads MINUSPOD_DATA_DIR at call time.)
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
      # Vite writes the built UI to static/ui (see frontend/vite.config.ts);
      # routes.py serves it from <repo root>/static/ui.
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

  # LLM/transcription runtime config. Shared by the interactive session
  # (home.sessionVariables) and the systemd user service so the two never
  # drift.
  minuspodEnv = {
    MINUSPOD_LLM_PROVIDER = "openai";
    MINUSPOD_LLM_BASE_URL = "http://127.0.0.1:8787/v1";
    # Consolidated thinking mode; the router preset's default reasoning_effort
    # is xhigh (MinusPod sends no per-request effort, so it uses the default).
    MINUSPOD_LLM_MODEL = "qwen3-8-27b-q8_0-thinking";
    MINUSPOD_TRANSCRIBE_PROVIDER = "local";
    MINUSPOD_MASTER_PASSPHRASE = "change-me";
  };
in
{
  home.packages = [ minuspod ];

  # Runtime configuration for the local LLM proxy (see home/llm).
  home.sessionVariables = minuspodEnv;

  # Always-on user service. MinusPod is a resident gunicorn web server (not a
  # socket-activated idle service like whisper-service), so it stays up and
  # restarts on failure. The binary wrapper (makeWrapper) already sets the data
  # dir, MINUSPOD_PORT, WHISPER_DEVICE=cuda, the CUDA *runtime* lib path and
  # PYTHONPATH; the service adds the LLM/transcription config above and, when an
  # NVIDIA driver package is supplied, its lib dir so ctranslate2 can dlopen
  # libcuda.so.1 (not in the ldconfig cache — see whisper-service).
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
