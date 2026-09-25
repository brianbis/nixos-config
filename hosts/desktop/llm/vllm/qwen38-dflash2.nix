# Qwen3.8-27B NVFP4 + DFlash2 K7, served as a NATIVE (non-docker) process on
# the RTX 5090. Undockerified counterpart to the former `vllm-qwen38-dflash2`
# container (the community `seanyourhighness/vllm-sm12x-nvfp4-dflash2` image):
# the engine is now the `pkgs.vllmDflash2` derivation (a pinned-wheel vLLM
# v0.27.1 venv with the DFlash2 Python overlays — see ./dflash2-package.nix)
# running as a socket-activated child process under the shared idle wrapper,
# exactly like the SGLang native engine. Between requests no process is
# resident and the model's VRAM is released.
#
# The weights are the SAME artifacts the SGLang engine and the old container
# used:
#   - target: gittensor-model-hub/Qwen3.8-27B-NVFP4-RTX5090
#             (downloaded to /var/lib/vllm/qwen38-nvfp4-target; the SGLang
#             service also requires this download service)
#   - draft:  YourHighnessLA/Qwen3.8-27B-DFlash2-NVFP4
#             (downloaded to /var/lib/vllm/qwen38-nvfp4-draft)
# The two download services below are unchanged from the docker version and
# remain the single source of the checkpoints.
{ config, lib, pkgs, ... }:

let
  idleSeconds = 120;
  frontPort = 18089; # socket-activated front (the catalog / Caddy face)
  childPort = 18090; # loopback-only child (the vllm server)

  # The shared socket-activated idle wrapper (child-process backend; the same
  # wrapper the SGLang native engine runs).
  idleWrapper = pkgs.callPackage ../idle-wrapper { };

  # Checkpoint locations (downloaded by the prep services below).
  targetDir = "/var/lib/vllm/qwen38-nvfp4-target";
  draftDir = "/var/lib/vllm/qwen38-nvfp4-draft";

  # Pinned chat template (the fork's release template; intentionally overrides
  # the different template bundled with the model).
  chatTemplate = pkgs.fetchurl {
    url =
      "https://raw.githubusercontent.com/seanyourhighness/vllm-sm12x-nvfp4-dflash2/fdb45641d9ef7d663b633037467b6949f1daecf7/chat-template.jinja";
    sha256 =
      "398edf5b5bb802fb6b9c9a8dba670d09f2aaeef6fdcaa0b2ca307265f59f78dc";
  };

  # The full `vllm serve` invocation, baked into a runner script. The JSON
  # args (--speculative-config, --compilation-config, --attention-config, ...)
  # must survive systemd's ExecStart parser, which treats double quotes as
  # quoting characters and would strip them from the JSON (vllm's argparse
  # would reject {method:dflash,...}). A bash script sidesteps that: systemd
  # passes only the script path (a plain token) to the idle wrapper, which
  # execs it; the JSON is single-quoted for bash, not systemd. `exec` replaces
  # the shell, so the wrapper's child PID is the vllm process itself (clean
  # SIGTERM/SIGKILL).
  #
  # The model is a POSITIONAL argument (vllm 0.27.1 deprecates --model for
  # `serve`), and the validated capacity-first profile (the "everything we
  # run" defaults from the community release) is applied verbatim:
  #   - DFlash2 K7 block-diffusion drafter (NVFP4 draft weights + NVFP4 KV)
  #   - explicit 8 GiB NVFP4 KV pin -> ~325k-token pool at 262K context;
  #     BF16 GDN/SSM state
  #   - FULL_DECODE_ONLY CUDA graphs (the piecewise prefill graphs are
  #     re-captured on every cold start and almost never dispatched here, so
  #     dropping them halves the capture phase with no regression on the
  #     latency-critical FULL decode/verification path)
  runScript = pkgs.writeShellScript "vllm-dflash2-serve" ''
    set -euo pipefail

    exec ${pkgs.vllmDflash2}/bin/vllm serve ${targetDir} \
      --served-model-name qwen3.8-27b-nvfp4-dflash2 \
      --host 127.0.0.1 --port ${toString childPort} \
      --quantization modelopt \
      --trust-remote-code \
      --reasoning-parser qwen3 \
      --enable-auto-tool-choice --tool-call-parser qwen3_coder \
      --chat-template ${chatTemplate} \
      --speculative-config '{"method":"dflash","model":"${draftDir}","num_speculative_tokens":7,"kv_cache_dtype":"nvfp4"}' \
      --kv-cache-dtype nvfp4 \
      --kv-cache-memory-bytes 8589934592 \
      --mamba-ssm-cache-dtype bfloat16 \
      --max-model-len 262144 \
      --max-num-seqs 4 \
      --max-num-batched-tokens 4096 \
      --long-prefill-token-threshold 2048 \
      --scheduling-policy priority \
      --enable-prefix-caching --enable-chunked-prefill \
      --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY","cudagraph_capture_sizes":[8,16,24,32]}' \
      --attention-config '{"flash_attn_version":2}' \
      --enable-mm-embeds \
      --limit-mm-per-prompt '{"image":0,"video":0}' \
      --default-chat-template-kwargs '{"enable_thinking":true,"reasoning_effort":"medium"}' \
      --override-generation-config '{"temperature":0.6}'
  '';

  # The idle wrapper's child is the runner script (a single token, so systemd
  # passes it through verbatim; the JSON lives inside the script).
  childCommand = [ runScript ];

  # Runtime download helper (unchanged from the docker version). Called by
  # normal systemd services, never by system.activationScripts.
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
    "gittensor-model-hub/Qwen3.8-27B-NVFP4-RTX5090"
    "0cc27958cefbbe231782ec8511de8c4eb5233348"
    targetDir
    [
      "model-00001-of-00003.safetensors"
      "model-00002-of-00003.safetensors"
      "model-00003-of-00003.safetensors"
      "model.safetensors.index.json"
    ];

  draftDownloadScript = downloadVllm
    "vllm-qwen38-nvfp4-draft"
    "YourHighnessLA/Qwen3.8-27B-DFlash2-NVFP4"
    "d913b0b5603a67c26f3edaf7e42a9f8cf89886be"
    draftDir
    [ "model.safetensors" ];
in
{
  systemd.tmpfiles.rules = [
    "d /var/lib/vllm/qwen38-nvfp4-target 0755 root root -"
    "d /var/lib/vllm/qwen38-nvfp4-draft 0755 root root -"
  ];

  /*
   * CHECKPOINT DOWNLOAD SERVICES
   *
   * Deliberately NOT WantedBy=multi-user.target: pulled in by the first
   * request through the preparation target below, so boot performs no HF
   * download. (The SGLang engine requires the target service directly.)
   */

  systemd.services.vllm-qwen38-dflash2-target = {
    description = "Download Qwen3.8 DFlash2 target checkpoint";

    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${targetDownloadScript}";
    };
  };

  systemd.services.vllm-qwen38-dflash2-draft = {
    description = "Download Qwen3.8 DFlash2 draft checkpoint";

    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${draftDownloadScript}";
    };
  };

  /*
   * The first request pulls this target in through the wrapper service. Both
   * downloads can run independently; the wrapper waits until this target has
   * completed. (No image pull any more: the engine is a native process.)
   */
  systemd.targets.vllm-qwen38-dflash2-prep = {
    description = "Prepare Qwen3.8 DFlash2 runtime";

    wants = [
      "vllm-qwen38-dflash2-target.service"
      "vllm-qwen38-dflash2-draft.service"
    ];

    after = [
      "vllm-qwen38-dflash2-target.service"
      "vllm-qwen38-dflash2-draft.service"
    ];
  };

  /*
   * NATIVE ENGINE (socket-activated child process)
   *
   * No wantedBy: started by the socket unit on demand and exits (code 0)
   * after the idle window, leaving nothing resident between requests. It must
   * not be pulled in at boot.
   */
  systemd.services.vllm-qwen38-dflash2 = {
    description =
      "vLLM Qwen3.8 DFlash2 native engine (socket-activated, unloads after ${toString idleSeconds}s idle)";

    /*
     * Starting the wrapper causes systemd to start the preparation target;
     * the wrapper does not run until the target's wanted services have
     * completed successfully (checkpoints present).
     */
    requires = [ "vllm-qwen38-dflash2-prep.target" ];
    after = [
      "vllm-qwen38-dflash2-prep.target"
      "vllm-qwen38-dflash2.socket"
    ];

    serviceConfig = {
      Type = "simple";

      ExecStart = lib.concatStringsSep " " ([
        "${pkgs.python3}/bin/python3"
        "${idleWrapper}/sglang_wrapper.py"
        "--child-port"
        (toString childPort)
        "--idle-seconds"
        (toString idleSeconds)
        "--ready-timeout"
        "3600"
        "--shutdown-timeout"
        "60"
        "--kill-timeout"
        "30"
        "--"
      ]
      ++ childCommand);

      # The wrapper exits 0 in every normal path (idle unload, SIGTERM, child
      # failure); only a wrapper crash (signal/coredump) restarts.
      Restart = "on-abnormal";
      RestartSec = "3";

      # The host NVIDIA driver (libcuda.so.1); the CUDA runtime libraries ship
      # inside the vllm venv (the nvidia-* wheels — nvidia/cu13/lib is on the
      # loader path so the JIT'd flashinfer modules' NEEDED libcudart.so.13
      # resolves to the same copy torch uses). The venv also bundles the C++
      # runtime at ${pkgs.vllmDflash2}/lib (libstdc++), needed by the dlopen'd
      # C-extension wheels (torch, flashinfer, ...); it is prepended so the
      # loader finds it.
      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        "LD_LIBRARY_PATH=${pkgs.vllmDflash2}/lib:${pkgs.vllmDflash2}/venv/lib/python3.12/site-packages/nvidia/cu13/lib:/run/opengl-driver/lib"
        "HF_HOME=/var/lib/vllm/hf-cache"
        "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
        "VLLM_USE_FLASHINFER_SAMPLER=0"
        "VLLM_WSL2_ENABLE_PIN_MEMORY=1"
        "VLLM_DFLASH_FORCE_EAGER=1"
        "VLLM_XQA_DEDICATED_STREAM=1"
        "TRITON_CACHE_DIR=/var/lib/vllm/vllm-cache/triton"
        # FlashInfer writes its JIT build artifacts (the compiled XQA .so +
        # ninja workdir) under $FLASHINFER_WORKSPACE_BASE/.cache/flashinfer/
        # <version>/<arch>/cached_ops. Pin the base to /var/lib/vllm so the
        # cache is persistent and in a known place (consistent with
        # TRITON_CACHE_DIR / HF_HOME) instead of the service user's ~/.cache.
        # The dir is created at runtime (flashinfer mkdir -p's it).
        "FLASHINFER_WORKSPACE_BASE=/var/lib/vllm/flashinfer"
        # Triton 3.7.1's nvidia backend locates libcuda.so.1 by shelling out
        # to `/sbin/ldconfig -p`, which does not exist on NixOS (and nixpkgs'
        # ldconfig has its cache path baked to a store path, so it could never
        # work here). TRITON_LIBCUDA_PATH is triton's override knob: it
        # short-circuits the ldconfig lookup and is used as the -L directory
        # when triton compiles its driver.c shim.
        "TRITON_LIBCUDA_PATH=/run/opengl-driver/lib"
        # Triton compiles that driver.c shim (cuda_utils) on first CUDA driver
        # init, using $CC or a gcc/clang found on PATH; the unit's default
        # PATH has no compiler. Point CC at the stdenv cc-wrapper (it carries
        # the -B/-L flags the raw gcc lacks; the result is cached under
        # TRITON_CACHE_DIR, so this only matters on the first run after a
        # triton version change).
        "CC=${pkgs.stdenv.cc}/bin/cc"
        # FlashInfer JIT-compiles the XQA decode kernel (nvcc + ninja) on the
        # first decode. Its get_cuda_path() shells out to `which nvcc` unless
        # CUDA_HOME is set (and `which` is not on the unit's PATH), so point
        # it at the derivation's $out/cuda-home — assembled from the nixpkgs
        # toolkit + the venv's libcudart (see dflash2-package.nix). The pip
        # nvidia-cuda-nvcc wheel is only the nvcc driver (no cicc/nvvm), which
        # is why the venv's own toolchain cannot do this.
        "CUDA_HOME=${pkgs.vllmDflash2}/cuda-home"
        # flashinfer's ninja build compiles the host C++ with $CXX and the
        # CUDA side with nvcc -ccbin $CC.
        "CXX=${pkgs.stdenv.cc}/bin/c++"
        # flashinfer's run_ninja() invokes bare `ninja`; the venv's ninja wheel
        # provides it. (Overrides the unit default PATH; the rest is the usual
        # NixOS fallback set.)
        "PATH=${pkgs.vllmDflash2}/venv/bin:/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
      ];

      # HF_TOKEN is not needed at serve time (the model is a local dir), but is
      # supplied optionally in case vLLM performs any HF lookup. The activation
      # script writes it (see ./default.nix); the leading '-' makes the file
      # optional so a missing file does not block startup.
      EnvironmentFile = [ "-/run/vllm/hf-token.env" ];
    };
  };

  systemd.sockets.vllm-qwen38-dflash2 = {
    description =
      "vLLM Qwen3.8 DFlash2 socket (socket activation, on-demand model residency)";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "127.0.0.1:${toString frontPort}";
    };
  };
}
