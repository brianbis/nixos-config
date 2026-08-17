{ config, pkgs, lib, ... }:

let
  # GGUF models directory for the llama.cpp router server. The router
  # (--models-dir) treats every top-level .gguf as a routable model, so each
  # multimodal model must live in its own subdirectory with its projector and
  # drafter alongside (see the llama.cpp "multiple models" docs). Files are
  # downloaded idempotently at switch time by the activation scripts below.
  modelsDir = "/var/lib/llama/models";

  # Muse-Glimmer-30B downloads into its own subdir beside its vision projector
  # (mmproj), so the router scan stands up one "muse-glimmer-30B" model with
  # multimodal. The DFlash drafter is NOT dropped in that subdir: scan_subdir
  # classifies any non-mmproj .gguf as the main model in filesystem order, so a
  # drafter beside the model can nondeterministically win and be loaded alone.
  # It lives in its own dir and is attached by path via the preset below.
  museDir = "${modelsDir}/muse-glimmer-30B";
  museRepo = "meta-models/Muse-Glimmer-30B-GGUF";
  museIncludes = [
    "muse-glimmer-30B-kquant-dynamic.gguf"
    "mmproj-kquant.gguf"
  ];

  # DFlash drafter for Muse's speculative decoding (~3x on RTX 5090). Kept out
  # of modelsDir so the router never discovers it, and wired via model-draft.
  draftDir = "/var/lib/llama/draft";
  draftRepo = "meta-models/Muse-Glimmer-30B-GGUF";
  draftIncludes = [
    "dflash-kquant.gguf"
  ];

  # Qwen3.8-27B is a single-file text model, so it lives flat in modelsDir.
  qwenRepo = "unsloth/Qwen3.8-27B-GGUF";
  qwenIncludes = [
    "Qwen3.8-27B-Q8_0.gguf"
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
  #
  #  - [*] default: KV cache offloaded to GPU for every model.
  #  - [muse-glimmer-30B] merges the DFlash drafter onto the auto-discovered
  #    muse preset (which already sets model + mmproj from the subdir scan).
  #  - [qwen3-8-27b-q8_0] registers Qwen under the catalog's model id (the auto
  #    id "Qwen3.8-27B-Q8_0" does not match what headroom/agents send) and
  #    forces KV into RAM (no-kv-offload): its ~27 GiB Q8_0 weights nearly fill
  #    the 32 GB card, so GPU KV OOMs at any real context. This keeps Glimmer's
  #    KV on the GPU, which previously had to be sacrificed for Qwen.
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
    model-draft = ${draftDir}/dflash-kquant.gguf
    n-gpu-layers-draft = 99
    ctx-size = 131072
    top-k = 64

    [qwen3-8-27b-q8_0-thinking-xhigh]
    model = ${modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"xhigh"}

    [qwen3-8-27b-q8_0-thinking-medium]
    model = ${modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"medium"}

    [qwen3-8-27b-q8_0-thinking-low]
    model = ${modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"low"}

    [qwen3-8-27b-q8_0-thinking-none]
    model = ${modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"none"}

    [qwen3-8-27b-q8_0-instruct-xhigh]
    model = ${modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"xhigh"}

    [qwen3-8-27b-q8_0-instruct-medium]
    model = ${modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"medium"}

    [qwen3-8-27b-q8_0-instruct-low]
    model = ${modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"low"}

    [qwen3-8-27b-q8_0-instruct-none]
    model = ${modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"none"}

  '';

  dwellSeconds = 30;

in {
  environment.systemPackages = with pkgs; [ llama-cpp ];

  system.activationScripts.museModels.text = download "llamacpp-muse" museRepo museDir museIncludes;

  system.activationScripts.qwenModels.text = download "llamacpp-qwen" qwenRepo modelsDir qwenIncludes;

  system.activationScripts.dflashModel.text = download "llamacpp-dflash" draftRepo draftDir draftIncludes;

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0755 root root -"
    "d ${museDir} 0755 root root -"
    "d ${draftDir} 0755 root root -"
  ];

  # llama.cpp router server on :8000. --models-dir makes every top-level .gguf
  # (and each subdir) a routable model; --models-preset attaches the Muse
  # drafter and renames the Qwen id to match the model catalog. The headroom
  # proxy upstreams requests here.
  systemd.services.llamacpp-muse = {
    description = "llama.cpp router (Muse-Glimmer-30B, Qwen3.8-27B)";
    # Auto-starts at boot, stays online. Models sleep after idle to free VRAM.
    wantedBy = [ "multi-user.target" ];
    requires = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.llama-cpp}/bin/llama-server"
        "--models-dir" "${modelsDir}"
        "--models-preset" "${modelsPreset}"
        "--models-max" "1"
        "--host" "127.0.0.1"
        "--port" "8000"
        # The llama.cpp router overlays every ExecStart arg onto EVERY model
        # preset (preset.merge, highest precedence) and they cannot be
        # overridden per model. So only genuinely router-level args stay here:
        # host/port, the slot count (--parallel), memory pinning and the idle
        # sleep timer. Model launch options (jinja, n-predict, ctx-size,
        # n-gpu-layers, kv-offload, flash-attn, and all sampling params like
        # temp/top-p/top-k) live in the preset file so each model can override
        # its own. E.g. Qwen keeps KV in RAM while Glimmer keeps KV on GPU.
        "--parallel" "4"
        "--mlock"
        "--sleep-idle-seconds" "${toString dwellSeconds}"
      ];
      Restart = "on-failure";
      RestartSec = "3";
    };
  };
}
