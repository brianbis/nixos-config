# llama.cpp: NixOS module for the router server.
#
# Applies the b10353 overlay (pinned build with sleep-exit patch) internally
# and configures the systemd router service, model downloads, and presets.

{ config, options, lib, pkgs, ... }:

let
  cfg = config.services.llamacpp;

  # Model repositories and file lists.
  museRepo = "meta-models/Muse-Glimmer-30B-GGUF";
  museIncludes = [
    "muse-glimmer-30B-kquant-dynamic.gguf"
    "mmproj-kquant.gguf"
  ];

  draftRepo = "meta-models/Muse-Glimmer-30B-GGUF";
  draftIncludes = [
    "dflash-kquant.gguf"
  ];

  qwenRepo = "unsloth/Qwen3.8-27B-GGUF";
  qwenIncludes = [
    "Qwen3.8-27B-Q8_0.gguf"
  ];

  hereticRepo = "0bserverx/Qwen3.8-27B-Heretic-Abliterated-Uncensored-GGUF";
  hereticIncludes = [
    "RVN-Q6_K.gguf"
  ];

  # Build the activation script fragment that downloads one repo's include
  # files into a dir, only when a file is missing. Idempotent across switches.
  download = name: repo: dir: includes: ''
    mkdir -p ${dir}
    missing=0
    for f in ${builtins.concatStringsSep " " (map (f: "\"${f}\"") includes)}; do
      [ -f "${dir}/$f" ] || missing=1
    done
    if [ "$missing" = "1" ]; then
      export HF_TOKEN="$(cat ${config.age.secrets.hf-token.path} | tr -d '\n')"
      export HF_HUB_DOWNLOAD_TIMEOUT=600
      # `hf download` (not the deprecated huggingface-cli, which errors out).
      ${pkgs.python3Packages.huggingface-hub}/bin/hf download ${repo} \
        --token "$HF_TOKEN" \
        --local-dir ${dir} \
        ${builtins.concatStringsSep " " (map (f: "--include \"${f}\"") includes)}
      status=$?
      if [ "$status" != "0" ]; then
        echo "${name}: hf download failed with status $status" >&2
        exit "$status"
      fi
      chmod 0644 ${dir}/*.gguf
    else
      echo "${name}: all model files present, skipping download"
    fi
  '';

  # Router model presets (--models-preset). The --models-dir scan auto-derives
  # ids from directory / file basenames. Precedence is command-line (highest) >
  # model section > [*] global section, so per-model launch options live here,
  # NOT on the ExecStart line. The [*] block sets shared per-model defaults; the
  # model sections override them and wire their special launch options.
  modelsPreset = pkgs.writeText "llamacpp-models-preset.ini" ''
    version = 1

    [*]
    ; Sampling + generation defaults are per-model (overrideable in each
    ; model's section), so they live here rather than on the router's ExecStart
    ; line, which the llama.cpp router overlays onto EVERY model and cannot be
    ; overridden (preset.merge overwrites existing keys). Override here only
    ; settings that genuinely apply to both backends.
    ctx-size = 262144
    n-gpu-layers = 99
    flash-attn = true
    kv-offload = true
    jinja = true
    n-predict = 8192
    temp = 1.0
    top-p = 0.95
    kv-unified = true

    ; top-k differs per model (Muse official generation_config = 64, Qwen = 20),
    ; so it's set in each model's section below rather than here.

    [muse-glimmer-30B]
    model-draft = ${cfg.draftDir}/dflash-kquant.gguf
    n-gpu-layers-draft = 99
    ctx-size = 131072
    top-k = 64

    [qwen3-8-27b-q8_0-thinking-xhigh]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"xhigh"}

    [qwen3-8-27b-q8_0-thinking-medium]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"medium"}

    [qwen3-8-27b-q8_0-thinking-low]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"low"}

    [qwen3-8-27b-q8_0-thinking-none]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"none"}

    [qwen3-8-27b-q8_0-instruct-xhigh]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"xhigh"}

    [qwen3-8-27b-q8_0-instruct-medium]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"medium"}

    [qwen3-8-27b-q8_0-instruct-low]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"low"}

    [qwen3-8-27b-q8_0-instruct-none]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"none"}

    [qwen3-8-27b-heretic-q6_k]
    model = ${cfg.modelsDir}/RVN-Q6_K.gguf
    ctx-size = 131072
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"xhigh"}
  '';

in
{
  options.services.llamacpp = {
    enable = lib.mkEnableOption "llamacpp router server";
    modelsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/llama/models";
      description = "Directory containing GGUF models for the router.";
    };
    museDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/llama/models/muse-glimmer-30B";
      description = "Subdirectory for Muse-Glimmer-30B multimodal model files.";
    };
    draftDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/llama/draft";
      description = "Directory for speculative decoding drafter models.";
    };
    dwellSeconds = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Idle seconds before the router enters sleep mode.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Apply the pinned llama-cpp overlay (b10353 + sleep-exit patch) so
    # `pkgs.llama-cpp` resolves correctly throughout the system.
    nixpkgs.overlays = [
      (final: prev: {
        llama-cpp = (prev.llama-cpp.override {
          cudaSupport = true;
          cudaPackages = prev.cudaPackages;
        }).overrideAttrs (old: {
          version = "10353";

          src = prev.fetchFromGitHub {
            owner = "ggml-org";
            repo = "llama.cpp";
            tag = "b10353";
            hash = "sha256-/kjqrGjkWJtlotTcZE5r+gSoce+llGwXz4gmQEOe8M0=";
            leaveDotGit = true;

            postFetch = ''
              git -C "$out" rev-parse --short HEAD > "$out/COMMIT"
              find "$out" -name .git -print0 | xargs -0 rm -rf
            '';
          };

          # b10353 changed package-lock.json, so the nixpkgs-pinned
          # npmDepsHash no longer matches this source.
          npmDepsHash =
            "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k=";

          # Exit the child process on idle-sleep so the OS reclaims all
          # VRAM. CUDA's allocator caches freed device memory in a
          # per-process pool, so destroy() alone leaves the DFlash
          # drafter's weights and KV cache resident in nvidia-smi. The
          # router detects the exit via stdout EOF and respawns the
          # child on the next request.
          postPatch = (old.postPatch or "") + ''
            patch -p1 -N < ${./llama-cpp-sleep-exit.patch}
          '';
        });
      })
    ];

    environment.systemPackages = [ pkgs.llama-cpp ];

    system.activationScripts.museModels.text = download "llamacpp-muse" museRepo cfg.museDir museIncludes;

    system.activationScripts.qwenModels.text = download "llamacpp-qwen" qwenRepo cfg.modelsDir qwenIncludes;

    system.activationScripts.hereticModel.text = download "llamacpp-heretic" hereticRepo cfg.modelsDir hereticIncludes;

    system.activationScripts.dflashModel.text = download "llamacpp-dflash" draftRepo cfg.draftDir draftIncludes;

    systemd.tmpfiles.rules = [
      "d ${cfg.modelsDir} 0755 root root -"
      "d ${cfg.museDir} 0755 root root -"
      "d ${cfg.draftDir} 0755 root root -"
    ];

    # llama.cpp router server on :8000. --models-dir makes every top-level .gguf
    # (and each subdir) a routable model; --models-preset attaches the Muse
    # drafter and renames the Qwen id to match the model catalog. The headroom
    # proxy upstreams requests here.
    systemd.services.llamacpp-muse = {
      description = "llama.cpp router (Muse-Glimmer-30B, Qwen3.8-27B, Heretic-RVN)";
      # Auto-starts at boot, stays online. Models sleep after idle to free VRAM.
      wantedBy = [ "multi-user.target" ];
      requires = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.llama-cpp}/bin/llama-server"
          "--models-dir"
          "${cfg.modelsDir}"
          "--models-preset"
          "${modelsPreset}"
          "--models-max"
          "1"
          "--host"
          "127.0.0.1"
          "--port"
          "8000"
          "--parallel"
          "4"
          "--mlock"
          "--sleep-idle-seconds"
          "${toString cfg.dwellSeconds}"
        ];
        Restart = "on-failure";
        RestartSec = "3";
      };
    };
  };
}
