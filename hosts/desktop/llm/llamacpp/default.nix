# llama.cpp: NixOS module for the router server.
#
# Consumes pkgs.llama-cpp (built by the flake from the flakeless `llama-cpp`
# source input, with CUDA + the sleep-exit patch — see ./package.nix) and
# configures the systemd router service, model downloads, and presets.
# `nix flake update llama-cpp` re-pins the source to the newest master commit.

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

  # Ternary-Bonsai-2-27B: fetched declaratively by pinned sha256 (immutable
  # store inputs) and assembled into a store dir the Bonsai router reads, so
  # there is no runtime activation download for this model. The PQ2_0 language
  # model (7.2 GB) is resident; the Q8_0 mmproj (0.63 GB) is the optional
  # vision tower. Hashes are the HF LFS sha256 for each file.
  bonsaiRepo = "prism-ml/Ternary-Bonsai-2-27B-gguf";
  # pkgs.fetchurl (a fixed-output derivation), not builtins.fetchURL (a builtin
  # that needs the `fetchers` experimental feature / --impure, which `just
  # switch`'s nix invocation does not enable).
  bonsaiPQ2 = pkgs.fetchurl {
    url = "https://huggingface.co/${bonsaiRepo}/resolve/main/Ternary-Bonsai-2-27B-PQ2_0.gguf";
    sha256 = "3907dc1658db1f78a9826bf8d5bcb8dc65db0d466388937af57f2294fae62ec1";
    name = "Ternary-Bonsai-2-27B-PQ2_0.gguf";
  };
  bonsaiMmproj = pkgs.fetchurl {
    url = "https://huggingface.co/${bonsaiRepo}/resolve/main/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf";
    sha256 = "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903";
    name = "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf";
  };
  # Assemble the two files into a dir with the exact basenames the router's
  # --models-dir scan and its mmproj auto-detection expect.
  bonsaiModelsDir = pkgs.runCommand "llama-bonsai-models" {} ''
    mkdir -p $out
    cp ${bonsaiPQ2} $out/Ternary-Bonsai-2-27B-PQ2_0.gguf
    cp ${bonsaiMmproj} $out/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
    chmod 0644 $out/*.gguf
  '';

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

    ; Qwen3.8-27B Q8_0: one preset per mode (thinking / instruct). The
    ; chat-template-kwargs reasoning_effort is the DEFAULT for requests that
    ; omit it; a per-request reasoning_effort (the dsh effort selector) always
    ; wins, since the server merges the request field over the preset kwarg.
    [qwen3-8-27b-q8_0-thinking]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"xhigh"}

    [qwen3-8-27b-q8_0-instruct]
    model = ${cfg.modelsDir}/Qwen3.8-27B-Q8_0.gguf
    no-kv-offload = true
    top-k = 20
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"medium"}

    [qwen3-8-27b-heretic-q6_k]
    model = ${cfg.modelsDir}/RVN-Q6_K.gguf
    ctx-size = 131072
    top-k = 20
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"xhigh"}
  '';

  # Bonsai router presets. One entry per mode (thinking / instruct); both load
  # the same PQ2_0 gguf (and its mmproj) and differ only in sampling + the
  # chat-template reasoning_effort. The chat-template-kwargs reasoning_effort is
  # the DEFAULT for requests that omit it; a per-request reasoning_effort (the
  # dsh effort selector) always wins, since the server merges the request field
  # over the preset kwarg. Sampling values are the model card's recommended
  # sets: thinking mode (temp 1.0 / top-p 0.95 / presence 0.0) and instruct mode
  # (temp 0.7 / top-p 0.8 / presence 1.5). The model's template supports
  # xhigh/medium (low behaves like xhigh; there is no none). The 7.2 GB weights
  # leave ample VRAM headroom, so the KV cache stays on the card (kv-offload,
  # no offload).
  bonsaiPreset = pkgs.writeText "llamacpp-bonsai-models-preset.ini" ''
    version = 1

    [*]
    ctx-size = 262144
    n-gpu-layers = 99
    flash-attn = true
    kv-offload = true
    jinja = true
    n-predict = 8192
    kv-unified = true

    [bonsai2-27b-pq2_0-thinking]
    model = ${bonsaiModelsDir}/Ternary-Bonsai-2-27B-PQ2_0.gguf
    mmproj = ${bonsaiModelsDir}/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
    top-k = 20
    min-p = 0.0
    temp = 1.0
    top-p = 0.95
    presence-penalty = 0.0
    chat-template-kwargs = {"reasoning_effort":"xhigh"}

    [bonsai2-27b-pq2_0-instruct]
    model = ${bonsaiModelsDir}/Ternary-Bonsai-2-27B-PQ2_0.gguf
    mmproj = ${bonsaiModelsDir}/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf
    top-k = 20
    min-p = 0.0
    temp = 0.7
    top-p = 0.8
    presence-penalty = 1.5
    chat-template-kwargs = {"reasoning_effort":"medium"}
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
      default = 120;
      description = "Idle seconds before the router enters sleep mode.";
    };
  };

  config = lib.mkIf cfg.enable {
    # pkgs.llama-cpp is provided by the flake's nixpkgs.overlays: it is built
    # from the flakeless `llama-cpp` source input (CUDA + the sleep-exit patch,
    # see ./package.nix), so `nix flake update llama-cpp` re-pins the source.
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
          "--load-mode"
          "mlock"
          "--sleep-idle-seconds"
          "${toString cfg.dwellSeconds}"
        ];
        Restart = "on-failure";
        RestartSec = "3";
      };
    };

    # Bonsai router on :8010. Runs the PrismML-Eng fork (the only binary that
    # loads the ternary PQ2_0 weights) over the declarative store models dir.
    # Kept separate from the stock llamacpp-muse router so the fork's build and
    # the ternary model don't touch the Muse / Qwen / Heretic fleet.
    systemd.services.llamacpp-bonsai = {
      description = "llama.cpp Bonsai fork router (Ternary-Bonsai-2-27B)";
      wantedBy = [ "multi-user.target" ];
      requires = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.llama-cpp-bonsai}/bin/llama-server"
          "--models-dir"
          "${bonsaiModelsDir}"
          "--models-preset"
          "${bonsaiPreset}"
          "--models-max"
          "1"
          "--host"
          "127.0.0.1"
          "--port"
          "8010"
          "--parallel"
          "4"
          "--load-mode"
          "mlock"
          "--sleep-idle-seconds"
          "${toString cfg.dwellSeconds}"
        ];
        Restart = "on-failure";
        RestartSec = "3";
      };
    };
  };
}
