{ config, lib, pkgs, ... }:

let
  idleSeconds = 120;

  releaseRev = "fdb45641d9ef7d663b633037467b6949f1daecf7";

  dflash2Image =
    "ghcr.io/seanyourhighness/vllm-sm12x-nvfp4-dflash2@sha256:48436de2f21d9eb77c9a4a7697e16227de12b0ea46638d95f09da0b27f436974";

  dflash2TargetRepo = "gittensor-model-hub/Qwen3.8-27B-NVFP4-RTX5090";
  dflash2TargetRevision = "0cc27958cefbbe231782ec8511de8c4eb5233348";
  dflash2TargetDir = "/var/lib/vllm/qwen38-nvfp4-target";

  dflash2TargetSentinels = [
    "model-00001-of-00003.safetensors"
    "model-00002-of-00003.safetensors"
    "model-00003-of-00003.safetensors"
    "model.safetensors.index.json"
  ];

  dflash2DraftRepo = "YourHighnessLA/Qwen3.8-27B-DFlash2-NVFP4";
  dflash2DraftRevision = "d913b0b5603a67c26f3edaf7e42a9f8cf89886be";
  dflash2DraftDir = "/var/lib/vllm/qwen38-nvfp4-draft";

  dflash2DraftSentinels = [
    "model.safetensors"
  ];

  dflash2ChatTemplate = pkgs.fetchurl {
    url =
      "https://raw.githubusercontent.com/seanyourhighness/vllm-sm12x-nvfp4-dflash2/${releaseRev}/chat-template.jinja";
    sha256 =
      "398edf5b5bb802fb6b9c9a8dba670d09f2aaeef6fdcaa0b2ca307265f59f78dc";
  };

  /*
   * Runtime download helper.
   *
   * IMPORTANT:
   * This is now called by a normal systemd service, never by
   * system.activationScripts.
   */
  downloadVllm =
    name: repo: revision: dir: sentinels: pkgs.writeShellScript name ''
      set -euo pipefail

      mkdir -p "${dir}"

      REVISION_FILE="${dir}.revision"
      recorded="none"

      if [ -f "$REVISION_FILE" ]; then
        recorded="$(cat "$REVISION_FILE")"
      fi

      missing=0

      for f in ${builtins.concatStringsSep " "
        (map (f: ''"${f}"'') sentinels)
      }; do
        [ -f "${dir}/$f" ] || missing=1
      done

      if [ "$recorded" = "${revision}" ] && [ "$missing" = "0" ]; then
        echo "${name}: revision ${revision} present, skipping download"
        exit 0
      fi

      echo "${name}: downloading ${repo} @ ${revision} (recorded: $recorded)"

      export HF_TOKEN="$(${pkgs.coreutils}/bin/cat ${
        config.age.secrets.hf-token.path
      } | ${pkgs.coreutils}/bin/tr -d '\n')"

      export HF_HUB_DOWNLOAD_TIMEOUT=600

      ${pkgs.python3Packages.huggingface-hub}/bin/hf download \
        "${repo}" \
        --revision "${revision}" \
        --token "$HF_TOKEN" \
        --local-dir "${dir}"

      echo "${revision}" > "$REVISION_FILE"

      echo "${name}: download complete"
    '';

  targetDownloadScript = downloadVllm
    "vllm-qwen38-nvfp4-target"
    dflash2TargetRepo
    dflash2TargetRevision
    dflash2TargetDir
    dflash2TargetSentinels;

  draftDownloadScript = downloadVllm
    "vllm-qwen38-nvfp4-draft"
    dflash2DraftRepo
    dflash2DraftRevision
    dflash2DraftDir
    dflash2DraftSentinels;

  /*
   * Image preparation.
   *
   * Also normal userspace now. No 60-second Docker wait during activation.
   */
  dflash2PullScript = pkgs.writeShellScriptBin "pull-vllm-dflash2" ''
    set -euo pipefail

    export PATH="${pkgs.docker}/bin:${pkgs.coreutils}/bin:$PATH"

    IMAGE="${dflash2Image}"

    echo "Checking Docker..."
    docker info >/dev/null

    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      echo "image $IMAGE already present; skipping pull"
      exit 0
    fi

    echo "==> pulling $IMAGE"
    docker pull "$IMAGE"
    echo "==> done: $IMAGE"
  '';

  mkVllm = import ./lib.nix;

  # Socket-activated idle wrapper (shared with the NInfer engines; the
  # relay/health/idle machinery lives in ../idle-wrapper once).
  idleWrapper = pkgs.callPackage ../idle-wrapper { };
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/vllm/qwen38-nvfp4-target 0755 root root -"
    "d /var/lib/vllm/qwen38-nvfp4-draft 0755 root root -"
    "d /var/lib/vllm/hf-cache 0755 2000 root -"
    "d /var/lib/vllm/vllm-cache 0755 2000 root -"
  ];

  /*
   * ------------------------------------------------------------------------
   * PREPARATION SERVICES
   * ------------------------------------------------------------------------
   *
   * These are deliberately NOT WantedBy=multi-user.target.
   *
   * They are pulled in by the first vLLM request through the preparation
   * target below. Therefore:
   *
   *   boot -> no HF download
   *   boot -> no GHCR pull
   *   boot -> no Docker dependency
   *
   * First request:
   *
   *   socket -> wrapper -> prep.target -> downloads/image -> container
   */

  systemd.services.vllm-qwen38-dflash2-target = {
    description = "Download Qwen3.8 DFlash2 target checkpoint";

    after = [
      "network-online.target"
    ];

    wants = [
      "network-online.target"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${targetDownloadScript}";
    };
  };

  systemd.services.vllm-qwen38-dflash2-draft = {
    description = "Download Qwen3.8 DFlash2 draft checkpoint";

    after = [
      "network-online.target"
    ];

    wants = [
      "network-online.target"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${draftDownloadScript}";
    };
  };

  systemd.services.vllm-qwen38-dflash2-image = {
    description = "Pull pinned Qwen3.8 DFlash2 vLLM image";

    after = [
      "docker.service"
      "network-online.target"
    ];

    wants = [
      "network-online.target"
    ];

    requires = [
      "docker.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${dflash2PullScript}/bin/pull-vllm-dflash2";
    };
  };

  /*
   * The first request pulls this target in through the wrapper service.
   *
   * All three preparation jobs can run independently, and the wrapper
   * waits until this target has completed.
   */
  systemd.targets.vllm-qwen38-dflash2-prep = {
    description = "Prepare Qwen3.8 DFlash2 runtime";

    wants = [
      "vllm-qwen38-dflash2-target.service"
      "vllm-qwen38-dflash2-draft.service"
      "vllm-qwen38-dflash2-image.service"
    ];

    after = [
      "vllm-qwen38-dflash2-target.service"
      "vllm-qwen38-dflash2-draft.service"
      "vllm-qwen38-dflash2-image.service"
    ];
  };

  /*
   * ------------------------------------------------------------------------
   * CONTAINER
   * ------------------------------------------------------------------------
   */

  virtualisation.oci-containers.containers.vllm-qwen38-dflash2 = mkVllm {
    image = dflash2Image;

    model = "/models/target";

    servedName = "qwen3.8-27b-nvfp4-dflash2";

    port = 18090;

    maxModelLen = 262144;

    quantization = "modelopt";
    kvCacheDtype = "nvfp4";

    toolCallParser = "qwen3_coder";
    reasoningParser = "qwen3";

    chatTemplate = "/opt/vllm-release/chat-template.jinja";

    speculativeConfig =
      ''{"method":"dflash","model":"/models/draft","num_speculative_tokens":7,"kv_cache_dtype":"nvfp4"}'';

    /*
     * Still useful as a final safety net.
     *
     * The normal path is the preparation target above.
     */
    pull = "missing";

    volumes = [
      "${dflash2TargetDir}:/models/target:ro"
      "${dflash2DraftDir}:/models/draft:ro"
      "${dflash2ChatTemplate}:/opt/vllm-release/chat-template.jinja:ro"
      "/var/lib/vllm/hf-cache:/home/vllm/.cache/huggingface"
      "/var/lib/vllm/vllm-cache:/home/vllm/.cache/vllm"
    ];

    environment = {
      HF_HOME = "/home/vllm/.cache/huggingface";

      VLLM_DFLASH_FORCE_EAGER = "1";
      VLLM_XQA_DEDICATED_STREAM = "1";
      VLLM_USE_FLASHINFER_SAMPLER = "0";

      VLLM_WSL2_ENABLE_PIN_MEMORY = "1";

      TRITON_CACHE_DIR =
        "/home/vllm/.cache/vllm/triton";
    };

    extraArgs = [
      "--trust-remote-code"

      "--kv-cache-memory-bytes"
      "8589934592"

      "--mamba-ssm-cache-dtype"
      "bfloat16"

      "--max-num-seqs"
      "4"

      "--max-num-batched-tokens"
      "4096"

      "--long-prefill-token-threshold"
      "2048"

      "--scheduling-policy"
      "priority"

      "--enable-chunked-prefill"

      "--compilation-config"
      # FULL_DECODE_ONLY, not FULL_AND_PIECEWISE: the piecewise (prefill)
      # graphs are re-captured on every cold start (never persisted) and are
      # almost never dispatched here — chunked prefill runs up to 2048-token
      # chunks (long-prefill-token-threshold), so mixed batches exceed the
      # 32-token piecewise capture sizes. Dropping them halves the capture
      # phase (6 of 12 capture-like forward passes) with no regression on the
      # latency-critical FULL decode/verification path. The DFlash2 drafter
      # already runs in this mode.
      ''{"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[8,16,24,32]}''

      "--attention-config"
      ''{"flash_attn_version":2}''

      "--enable-mm-embeds"

      "--limit-mm-per-prompt"
      ''{"image":0,"video":0}''

      "--default-chat-template-kwargs"
      ''{"enable_thinking":true,"reasoning_effort":"medium"}''

      "--override-generation-config"
      ''{"temperature":0.6}''
    ];

    shmSize = "8g";
  };

  /*
   * The generated container service must NOT restart the container itself.
   * The Python wrapper owns the lifecycle.
   */
  systemd.services."docker-vllm-qwen38-dflash2".serviceConfig.Restart =
    lib.mkForce "no";

  /*
   * The container service depends on the preparation target (HF checkpoint
   * downloads + pinned image pull). The socket-activated wrapper already pulls
   * this in, but the DIRECT start path (`just vllm-qwen38-dflash2`, which
   * starts this service without the wrapper) also needs the checkpoints +
   * image present before `docker run`. Declaring the dependency on the service
   * itself (rather than only in the justfile recipe) makes it self-sufficient
   * for either start path; it is a no-op when the wrapper has already started
   * the target.
   */
  systemd.services."docker-vllm-qwen38-dflash2".requires = [
    "vllm-qwen38-dflash2-prep.target"
  ];

  systemd.services."docker-vllm-qwen38-dflash2".after = [
    "vllm-qwen38-dflash2-prep.target"
  ];

  /*
   * Cache directories are created/chowned immediately before docker run.
   */
  systemd.services."docker-vllm-qwen38-dflash2".serviceConfig.ExecStartPre =
    lib.mkForce [
      "${pkgs.coreutils}/bin/mkdir -p /var/lib/vllm/vllm-cache /var/lib/vllm/hf-cache"

      "${pkgs.coreutils}/bin/chown 2000:0 /var/lib/vllm/vllm-cache /var/lib/vllm/hf-cache"

      "${pkgs.coreutils}/bin/chmod 0755 /var/lib/vllm/vllm-cache /var/lib/vllm/hf-cache"
    ];

  /*
   * Graceful idle unload.
   *
   * The module's generated stop is `docker stop <name> || true` with docker's
   * DEFAULT 10-second stop timeout. vLLM's SIGTERM shutdown (engine-core abort
   * + CUDA graph/context teardown for a 27B model) exceeds 10s, so the default
   * ceiling SIGKILLs the container instead of letting it exit cleanly — the
   * "not graceful" idle unload. `preStop` is the NixOS option that renders into
   * the unit's ExecStop, so overriding it (as the Restart/ExecStartPre overrides
   * above do) gives the stop a 60s window. 60s stays under the module's
   * TimeoutStopSec=120 and matches the wrapper's --shutdown-timeout.
   */
  systemd.services."docker-vllm-qwen38-dflash2".preStop =
    lib.mkForce "docker stop -t 60 vllm-qwen38-dflash2 || true";

  /*
   * ------------------------------------------------------------------------
   * SOCKET / ON-DEMAND WRAPPER
   * ------------------------------------------------------------------------
   */

  systemd.sockets.vllm-qwen38-dflash2 = {
    description =
      "vLLM Qwen3.8 DFlash2 socket";

    wantedBy = [
      "sockets.target"
    ];

    socketConfig = {
      ListenStream = "127.0.0.1:18089";
    };
  };

  systemd.services.vllm-qwen38-dflash2 = {
    description =
      "vLLM Qwen3.8 DFlash2 idle wrapper";

    /*
     * IMPORTANT:
     *
     * Starting the wrapper causes systemd to start the preparation target.
     * The wrapper does not run until the target's wanted services have
     * completed successfully.
     */
    requires = [
      "vllm-qwen38-dflash2-prep.target"
    ];

    after = [
      "vllm-qwen38-dflash2-prep.target"
    ];

    serviceConfig = {
      Type = "simple";

      ExecStart = lib.concatStringsSep " " [
        "${pkgs.python3}/bin/python3"
        "${idleWrapper}/vllm_wrapper.py"

        "--child-port"
        "18090"

        "--container"
        "vllm-qwen38-dflash2"

        "--image"
        dflash2Image

        "--pull-timeout"
        "7200"

        "--idle-seconds"
        (toString idleSeconds)

        "--ready-timeout"
        "3600"

        "--shutdown-timeout"
        "60"

        "--kill-timeout"
        "30"
      ];

      Environment = [
        "PATH=/run/current-system/sw/bin:/usr/bin:/bin"
      ];

      Restart = "on-abnormal";
      RestartSec = "3";
    };
  };
}
