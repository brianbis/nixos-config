# SGLang engine for Qwen3.8-27B NVFP4, served as a native (non-docker)
# process on the RTX 5090. Nix-side counterpart to the vLLM DFlash2 container,
# but with no container runtime: the engine is the pkgs.sglang derivation (a
# under the shared idle wrapper. Between requests no process is resident and
# the model's VRAM is released: the gate (../gate) starts this unit on demand
# and the wrapper exits once the gate stops stamping its activity file.
#
# The weights are the SAME artifact the vLLM DFlash2 container uses
# (gittensor-model-hub/Qwen3.8-27B-NVFP4-RTX5090, downloaded to
# /var/lib/vllm/qwen38-nvfp4-target by the vLLM prep service). Requiring that
# download service (not the full prep target, which also pulls the docker
# image + DFlash2 draft) guarantees the checkpoint is present before the first
# request, without re-downloading it.
{ config, lib, pkgs, catalog, ... }:

let
  idleSeconds = 120;
  # The engine's port and unit come from the ledger (../../../catalog), which
  # is also the gate's routing table — there is no front port to own here.
  row = catalog.models.qwen38_nvfp4_sglang;
  childPort = row.port;

  # The shared idle wrapper (child-process backend).
  idleWrapper = pkgs.callPackage ../idle-wrapper { };

  # Reuse the vLLM DFlash2 target checkpoint (same NVFP4 artifact).
  modelDir = "/var/lib/vllm/qwen38-nvfp4-target";

  # The native sglang child. `sglang serve` launches the OpenAI-compatible
  # server; modelopt_fp4 loads the pre-quantized ModelOpt NVFP4 weights
  # (matching how the vLLM container loads this checkpoint with
  # --quantization modelopt).
  childCommand = [
    "${pkgs.sglang}/bin/sglang"
    "serve"
    "--model-path"
    modelDir
    "--host"
    "127.0.0.1"
    "--port"
    (toString childPort)
    "--quantization"
    "modelopt_fp4"
    # Single 32 GB card: one process, ~90% of VRAM for weights + KV.
    "--tp"
    "1"
    "--mem-fraction-static"
    "0.85"
    # Conservative context for a first cut (tunable; raise as the KV pool
    # allows). sglang errors at startup if the KV pool cannot fit.    "--context-length"
    "32768"
    "--trust-remote-code"
  ];
in
{
  /*
   * No wantedBy: started by the socket unit on demand and exits (code 0)
   * after the idle window, leaving nothing resident between requests. It must
   * not be pulled in at boot.
   */
  systemd.services.sglang-serve = {
    description =
      "SGLang engine for Qwen3.8-27B NVFP4 (on-demand, unloads after ${toString idleSeconds}s idle)";



    # The checkpoint is downloaded by the vLLM DFlash2 prep service (same
    # artifact); require it so the weights are present before the first
    # request (a no-op when the checkpoint is already on disk).
    requires = [ "vllm-qwen38-dflash2-target.service" ];

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
        # Lifecycle mode: no port bound, nothing relayed — the gate forwards
        # to --child-port and stamps the activity file that keeps this model
        # resident.
        "--lifecycle-only"
        "--activity-file"
        "${catalog.gate.activityDir}/${row.unit}"
        "--"
      ]
      ++ childCommand);

      # The wrapper exits 0 in every normal path (idle unload, SIGTERM, child
      # failure); only a wrapper crash (signal/coredump) restarts.
      Restart = "on-abnormal";
      RestartSec = "3";

      # The host NVIDIA driver (libcuda.so.1) plus the host C/C++ and audio
      # libraries the venv's compiled extensions need (bundled under
      # ${pkgs.sglang}/lib by the package); the CUDA runtime libraries ship
      # inside the sglang venv (the nvidia-* wheels).
      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        # FlashInfer JIT-compiles its kernels (batch_prefill / XQA decode) at
        # startup and locates the CUDA toolkit via CUDA_HOME (else `which
        # nvcc`, else /usr/local/cuda). Point at the derivation's $out/cuda-home
        # — assembled from the nixpkgs toolkit (nvcc + headers + cicc/nvvm, one
        # self-consistent version) plus the venv's libcudart (see package.nix).
        # The venv's own nvidia/cu13 cannot serve as this home: its nvcc
        # (13.4.59) and runtime headers (13.0.96) disagree, so the CCCL
        # cuda_toolkit.h compatibility check aborts every JIT compile.
        "CUDA_HOME=${pkgs.sglang}/cuda-home"
        # deep_ep's JIT locates the compiler via EP_JIT_NVCC_COMPILER (else
        # $CUDA_HOME/bin/nvcc). Pin it to the same nixpkgs-toolkit nvcc so
        # deep_ep and flashinfer both use one consistent toolkit (and the JIT
        # never falls back to a `which nvcc` PATH lookup).        "EP_JIT_NVCC_COMPILER=${pkgs.sglang}/cuda-home/bin/nvcc"
        # Cap the flashinfer JIT's parallelism. Its run_ninja() passes no -j
        # when MAX_JOBS is unset, so ninja defaults to one `nvcc -O3` per CPU
        # core; that parallel fan-out (right after the 17 GB model load) spikes
        # host RAM and OOM-kills the box (64 GB, no swap). Capping it bounds the
        # peak. The JIT is a one-time cold-start cost (cached under
        # /root/.cache/sglang), so a modest cap only slows the first start.        "MAX_JOBS=6"
        # The venv's nvidia/cu13/lib (libcudart.so.13) is on the loader path so
        # the JIT'd flashinfer modules' NEEDED libcudart.so.13 resolves to the
        # same copy torch uses.        "LD_LIBRARY_PATH=${pkgs.sglang}/lib:${pkgs.sglang}/venv/lib/python3.12/site-packages/nvidia/cu13/lib:/run/opengl-driver/lib"
        # Same triton 3.7.1 wheel as the vLLM DFlash2 runtime: its nvidia
        # backend locates libcuda.so.1 by shelling out to `/sbin/ldconfig -p`,
        # which does not exist on NixOS. TRITON_LIBCUDA_PATH is triton's
        # override knob: it short-circuits the ldconfig lookup and is used as
        # the -L directory when triton compiles its driver.c shim.        "TRITON_LIBCUDA_PATH=/run/opengl-driver/lib"
        # Triton compiles that driver.c shim (cuda_utils) on first CUDA driver
        # init, using $CC or a gcc/clang found on PATH; the unit's default PATH
        # has no compiler. Point CC at the stdenv cc-wrapper (it carries the
        # -B/-L flags the raw gcc lacks; the result is cached in triton's
        # default cache dir, so this only matters on the first run after a
        # triton version change).        "CC=${pkgs.stdenv.cc}/bin/cc"
        # deep_ep's JIT drives nvcc, and nvcc itself needs a host C/C++
        # compiler on PATH: before compiling it runs `gcc` to "preprocess host
        # compiler properties" and uses g++ for the host portion of each kernel
        # (it passes no -ccbin). The unit's default PATH has no compiler, so
        # prepend the stdenv cc-wrapper (gcc, g++, cc, c++) plus the
        # coreutils/findutils nvcc's subprocesses invoke. The venv bin comes
        # first: flashinfer's run_ninja() invokes bare `ninja`, which must
        # resolve to the venv's (patchelf'd) ninja wheel binary.        "PATH=${pkgs.sglang}/venv/bin:${pkgs.stdenv.cc}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"
      ];
    };
  };


}
