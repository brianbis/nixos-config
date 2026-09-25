# `inputs` is a NixOS specialArg (see flake.nix specialArgs); it is destructured here (not a free variable) so the flakeless `ninfer` / `ninfer-gzenz` source inputs are in scope.
{ config, pkgs, lib, inputs, ... }:

let
  modelsDir = "/var/lib/ninfer/models";
  logDir = "/var/log/ninfer";
  requestLog = "${logDir}/requests.jsonl";
  idleSeconds = 120;
  childPort = 8081;
  childPortA3B = 8083;
  childPortGzenz = 8085;
  childPortSwift = 8089;
  childPortCinference = 8092;
  requestLogGzenz = "${logDir}/requests-gzenz.jsonl";
  requestLogSwift = "${logDir}/requests-swift.jsonl";
  requestLogCinference = "${logDir}/requests-cinference.jsonl";

  # Shared build for the NInfer engine. Two engines are built from two different sources: the pinned upstream rev (with the local reasoning-effort patch) and the gzenz fork (no serve-level --reasoning-effort flag, so no patch).
  # NB: the patch-file parameter is named patchFile (not patch) so it does not shadow pkgs.patch inside the `with pkgs` build-inputs blocks.
  mkNinfer = { pname, src, patchFile ? null, homepage }:
    pkgs.stdenv.mkDerivation {
      inherit pname src;
      version = "master";

      # fetchFromGitHub in this nixpkgs pin hashes the *unpacked* tree (fetchzip, recursiveHash = true), NOT the tarball sha256 — see AGENTS.md "Assembling fetchFromGitHub hashes".

      nativeBuildInputs = with pkgs; [
        cmake
        ninja
        patch
        pkg-config
        cudaPackages_13_1.cudatoolkit
      ];

      buildInputs = with pkgs; [
        ffmpeg
        curl
        cudaPackages_13_1.cudatoolkit
      ];

      postPatch =
        if patchFile == null then "" else ''
          patch -p1 -N < ${patchFile}
        '';

      configurePhase = ''
        cmake -S . -B build \
          -G Ninja \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_CUDA_ARCHITECTURES=120a \
          -DNINFER_BUILD_APPS=ON \
          -DBUILD_TESTING=OFF \
          -DNINFER_BUILD_BENCHMARKS=OFF
      '';

      buildPhase = ''
        cmake --build build --parallel
      '';

      installPhase = ''
        mkdir -p $out/bin
        cp -v build/apps/ninfer $out/bin/
        cp -v build/apps/ninfer-serve $out/bin/
      '';

      meta = with lib; {
        description = "High-performance C++/CUDA inference engine for Qwen checkpoints";
        inherit homepage;
        license = licenses.asl20;
        platforms = [ "x86_64-linux" ];
      };
    };

  ninfer = mkNinfer {
    pname = "ninfer";
    # Source from the flakeless `ninfer` input (see flake.nix); `nix flake update ninfer` re-pins it.
    src = inputs.ninfer;
    # The pinned rev has no server-side reasoning-effort default; this patch adds --reasoning-effort so the serve binary can default Qwen3.8 to brief thinking (a per-request effort still wins).
    patchFile = ./reasoning-effort.patch;
    homepage = "https://github.com/Neroued/ninfer";
  };

  # Parallel engine from the gzenz fork (checkpoint advancement, worker recovery, thinking-signature fixes, QUASAR support). Same build inputs and app layout; the fork dropped the vendored spdlog, so the shared build inputs still cover it.
  ninferGzenz = mkNinfer {
    pname = "ninfer-gzenz";
    # Source from the flakeless `ninfer-gzenz` input (see flake.nix); `nix flake update ninfer-gzenz` re-pins it.
    src = inputs.ninfer-gzenz;
    homepage = "https://github.com/gzenz/ninfer";
  };

  # Cinference fork: a focused NInfer fork (satellitedown/cinference) that raises the MTP draft window to 10 and derives CUDA Graph topology classes from the captured graph. Its base is the same NInfer rev we pin (9e163eee), so the shared build recipe builds it unchanged and the reasoning-effort patch applies (it only touches src/serve/*).
  # Source from the flakeless `cinference` input; `nix flake update cinference` re-pins it.
  cinference = mkNinfer {
    pname = "cinference";
    src = inputs.cinference;
    patchFile = ./reasoning-effort.patch;
    homepage = "https://github.com/satellitedown/cinference";
  };

  # Socket-activated idle wrapper (shared with the vLLM containers; the relay/health/idle machinery lives in ../idle-wrapper once). systemd owns the front-port socket; the wrapper relays connections to the child and exits (code 0) once the model is idle.
  idleWrapper = pkgs.callPackage ../idle-wrapper { };

  # The wrapper's ExecStart for a serve pair: the shared idle wrapper (child backend) plus the per-model child command.
  serveExecStart = childPort: requestLog: childCommand:
    lib.concatStringsSep " " ([
      "${pkgs.python3}/bin/python3"
      "${idleWrapper}/ninfer_wrapper.py"
      "--child-port"
      (toString childPort)
      "--idle-seconds"
      (toString idleSeconds)
      "--ready-timeout"
      "1800"
      "--shutdown-timeout"
      "30"
      "--kill-timeout"
      "10"
      "--request-log"
      requestLog
      "--"
    ]
    ++ childCommand);

  # The model-serving child. Loopback-only: the wrapper (and thus the socket unit) is the only thing that can reach it.
  childCommand = [
    "${ninfer}/bin/ninfer-serve"
    "${modelsDir}/${ninferModelFile}"
    "--host"
    "127.0.0.1"
    "--port"
    (toString childPort)
    "--kv-dtype"
    "nvfp4"
    "--max-context"
    "240000"
    "--kv-capacity"
    "250000"
    "--default-max-tokens"
    "200000"
    "--pending-timeout-ms"
    "900000"
    "--prefill-chunk"
    "1024"
    "--max-concurrency"
    "2"
    "--max-pending-requests"
    "128"
    "--device-state-slots"
    "2"
    "--host-state-slots"
    "8"
    "--host-kv-mib"
    "8192"
    "--temperature"
    "0.7"
    "--presence-penalty"
    "0.0"
    "--spec"
    "mtp"
    "--draft-tokens"
    "3"
    "--lm-head-draft"
    "--reasoning-effort"
    "low"
    "--request-log-jsonl"
    requestLog
  ];

  ninferModelRepo = "neroued/Qwen3.8-27B-nvfp4-NInfer";
  ninferModelFile = "qwen3_8_27b_nvfp4.ninfer";

  # Qwen3.6-35B-A3B (sparse MoE, 3B active params). Requires ninfer rev bd265a3 or later (the pinned 8eaed53 satisfies this).
  ninferModelRepoA3B = "neroued/Qwen3.6-35B-A3B-NInfer";
  ninferModelFileA3B = "qwen3_6_35b_a3b.ninfer";

  # Swift (abliterated) Qwen3.8-27B NVFP4 — a community "abliterated" (safety training removed) NVFP4 checkpoint in the same NInfer layout as the stock qwen38-nvfp4 model. Public HF repo (no token required), downloaded declaratively like the others.
  ninferModelRepoSwift = "Dragoy/Swift-Qwen3.8-27B-abliterated-NVFP4-NInfer";
  ninferModelFileSwift = "qwen3_8_27b_swift_abliterated_nvfp4.ninfer";

  # Second serving child: Qwen3.6-35B-A3B on its own loopback port. No --reasoning-effort: the A3B chat template does not support a reasoning-effort control (the flag stays off so the server default stays unset; the template rejects an effort it cannot honor).
  childCommandA3B = [
    "${ninfer}/bin/ninfer-serve"
    "${modelsDir}/${ninferModelFileA3B}"
    "--host"
    "127.0.0.1"
    "--port"
    (toString childPortA3B)
    "--kv-dtype"
    "int8"
    "--max-context"
    "262144"
    "--default-max-tokens"
    "200000"
    "--pending-timeout-ms"
    "900000"
    "--prefill-chunk"
    "1024"
    "--max-concurrency"
    "1"
    "--max-pending-requests"
    "128"
    "--temperature"
    "0.7"
    "--spec"
    "mtp"
    "--draft-tokens"
    "3"
    "--lm-head-draft"
    "--request-log-jsonl"
    "${logDir}/requests-a3b.jsonl"
  ];

  # Third serving child: the gzenz fork engine on the SAME Qwen3.8-27B NVFP4 artifact (reused weights), on its own loopback port.
  # The point of running the fork in parallel to the stock engine is its COMPRESSED KV format (--kv-dtype nvfp4: 144 vs 264 bytes/token/KV-head, 45% less), which lets it run a HIGHER KV-cache limit than the stock int8 engine on the same 32 GB card. YaRN (--rope-scaling-factor 2.12) extends context past the 262k native limit.
  # The launch options are deliberately NOT generalized across the two engines: stock is int8 KV / 240k context; gzenz is nvfp4 KV / 555k logical ceiling (YaRN) with --kv-capacity auto (sized to fit VRAM; an explicit 555000 pool does NOT fit this card).
  # No --reasoning-effort: the fork's serve binary has no such flag (its Qwen3.8 template defaults to xhigh thinking; a per-request reasoning_effort always wins).
  # --weights-profile qwen38-nvfp4 is REQUIRED: the fork's auto-detection misroutes the qwen3.8/nvfp4 identity to the Qwen36Nvfp4 (W8G32_F16S) contract, but our artifact is the official FP8 profile (Qwen38Nvfp4); without the override the token_embedding tensor format mismatches and the child aborts at load.
  # --request-log-jsonl is required by the idle wrapper (in-flight tracking); --pending-timeout-ms 900000 and --default-max-tokens 200000 override the fork's too-aggressive defaults.
  childCommandGzenz = [
    "${ninferGzenz}/bin/ninfer-serve"
    "${modelsDir}/${ninferModelFile}"
    "--weights-profile"
    "qwen38-nvfp4"
    "--host"
    "127.0.0.1"
    "--port"
    (toString childPortGzenz)
    "--kv-dtype"
    "nvfp4"
    "--max-context"
    "555000"
    "--kv-capacity"
    "auto"
    "--rope-scaling-factor"
    "2.12"
    "--rope-scaling-original-context"
    "262144"
    "--max-concurrency"
    "2"
    "--device-state-slots"
    "2"
    "--host-state-slots"
    "8"
    "--host-kv-mib"
    "8192"
    "--spec"
    "mtp"
    "--draft-tokens"
    "3"
    "--lm-head-draft"
    "--preserve-thinking"
    # Operational overrides (fork defaults too aggressive for production):
    "--pending-timeout-ms"
    "900000"
    "--default-max-tokens"
    "200000"
    # Idle-wrapper contract (in-flight tracking via the request log).
    "--request-log-jsonl"
    requestLogGzenz
  ];

  # Fourth serving child: the Swift (abliterated) Qwen3.8-27B NVFP4 checkpoint on its own loopback port, served by the stock engine. Same layout as the stock qwen38-nvfp4 model, so it reuses that child's launch options (nvfp4 KV, 240k context, low reasoning effort), with speculative decoding switched to DFlash2 (the artifact bakes in a 5-layer DFlash2 drafter; the pinned ninfer rev supports it).
  # No --weights-profile override: like the stock model it relies on the engine's auto-detection (the abliterated checkpoint keeps the official Qwen3.8 NVFP4 tensor layout); if a load test shows a tensor-format mismatch, add --weights-profile qwen38-nvfp4.
  childCommandSwift = [
    "${ninfer}/bin/ninfer-serve"
    "${modelsDir}/${ninferModelFileSwift}"
    "--host"
    "127.0.0.1"
    "--port"
    (toString childPortSwift)
    "--kv-dtype"
    "nvfp4"
    "--max-context"
    "240000"
    "--kv-capacity"
    "250000"
    "--default-max-tokens"
    "200000"
    "--pending-timeout-ms"
    "900000"
    "--prefill-chunk"
    "1024"
    "--max-concurrency"
    "2"
    "--max-pending-requests"
    "128"
    "--device-state-slots"
    "2"
    "--host-state-slots"
    "8"
    "--host-kv-mib"
    "8192"
    "--temperature"
    "0.7"
    "--presence-penalty"
    "0.0"
    "--spec"
    "dflash2"
    "--draft-tokens"
    "7"
    "--lm-head-draft"
    "--reasoning-effort"
    "low"
    "--request-log-jsonl"
    requestLogSwift
  ];

  # Fifth serving child: the Cinference fork engine (MTP-10) on the Swift (abliterated) Qwen3.8-27B NVFP4 checkpoint, on its own loopback port.
  # The whole point of the fork is MTP-10: --draft-tokens 10 (the stock/gzenz children use 3; the Swift child uses DFlash2 K7). cinference extends the MTP window cap from 5 to 10 and derives CUDA Graph topology classes from the captured graph.
  # Model/spec pairing: the Swift artifact is documented with a DFlash2 drafter, but MTP-10 needs MTP layers; the Swift checkpoint keeps the official Qwen3.8 NVFP4 layout (which carries MTP), so --spec mtp is expected to load. If it does not, flip --spec mtp to --spec dflash2 (cinference supports DFlash2 to K=15) or point at the stock qwen3_8_27b_nvfp4.ninfer (known MTP-capable).
  childCommandCinference = [
    "${cinference}/bin/ninfer-serve"
    "${modelsDir}/${ninferModelFileSwift}"
    "--host"
    "127.0.0.1"
    "--port"
    (toString childPortCinference)
    "--kv-dtype"
    "nvfp4"
    "--max-context"
    "262144"
    "--kv-capacity"
    "262144"
    "--default-max-tokens"
    "262144"
    "--pending-timeout-ms"
    "900000"
    "--prefill-chunk"
    "1024"
    "--max-concurrency"
    "2"
    "--max-pending-requests"
    "128"
    "--device-state-slots"
    "2"
    "--host-state-slots"
    "8"
    "--host-kv-mib"
    "4096"
    "--temperature"
    "0.7"
    "--presence-penalty"
    "0.0"
    "--spec"
    "mtp"
    "--draft-tokens"
    "10"
    "--lm-head-draft"
    "--reasoning-effort"
    "low"
    "--request-log-jsonl"
    requestLogCinference
  ];

  downloadNinferModel = name: repo: dir: file: ''
    mkdir -p ${dir}
    if [ ! -f "${dir}/${file}" ]; then
      export HF_TOKEN="$(cat ${config.age.secrets.hf-token.path} | tr -d '\n')"
      export HF_HUB_DOWNLOAD_TIMEOUT=600
      ${pkgs.python3Packages.huggingface-hub}/bin/hf download ${repo} \
        --local-dir ${dir} \
        --token "$HF_TOKEN" \
        --include "${file}"
      if [ $? -ne 0 ]; then
        echo "${name}: hf download failed" >&2
        exit 1
      fi
      chmod 0644 ${dir}/${file}
    else
      echo "${name}: model present, skipping download"
    fi
  '';

in
{
  environment.systemPackages = [ ninfer ninferGzenz cinference ];

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0755 root root -"
    "d ${logDir} 0755 root root -"
  ];

  system.activationScripts.ninferModel.text = downloadNinferModel "ninfer-qwen38-nvfp4" ninferModelRepo modelsDir ninferModelFile;

  system.activationScripts.ninferModelA3B.text = downloadNinferModel "ninfer-qwen36-a3b" ninferModelRepoA3B modelsDir ninferModelFileA3B;

  system.activationScripts.ninferModelSwift.text = downloadNinferModel "ninfer-qwen38-swift-abliterated" ninferModelRepoSwift modelsDir ninferModelFileSwift;

  # No After=network.target: sockets.target orders before basic.target, but network.target on this host does not (via wpa_supplicant); ordering the socket after network.target would cycle and systemd would drop its job.
  systemd.sockets.ninfer-serve = {
    description = "NInfer engine socket (socket activation, on-demand model residency)";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "127.0.0.1:8080";
    };
  };

  systemd.services.ninfer-serve = {
    description = "NInfer engine for Qwen3.8-27B NVFP4 (socket-activated, unloads after ${toString idleSeconds}s idle)";
    # No wantedBy: the service is started by the socket unit on demand and exits (code 0) after the idle window, leaving nothing resident; it must not be pulled in at boot.
    after = [ "ninfer-serve.socket" ];

    serviceConfig = {
      Type = "simple";

      ExecStart = serveExecStart childPort requestLog childCommand;

      # The wrapper exits 0 in every normal path (idle unload, SIGTERM, child failure); only a wrapper crash (signal/coredump) restarts.
      Restart = "on-abnormal";
      RestartSec = "3";

      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
      ];
    };
  };

  # Second socket-activated service: Qwen3.6-35B-A3B on port 8082 (front) / 8083 (child). Same idle-unload pattern as the Qwen3.8 service.
  systemd.sockets.ninfer-serve-a3b = {
    description = "NInfer engine socket for Qwen3.6-35B-A3B (socket activation, on-demand model residency)";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "127.0.0.1:8082";
    };
  };

  systemd.services.ninfer-serve-a3b = {
    description = "NInfer engine for Qwen3.6-35B-A3B (socket-activated, unloads after ${toString idleSeconds}s idle)";
    after = [ "ninfer-serve-a3b.socket" ];

    serviceConfig = {
      Type = "simple";

      ExecStart = serveExecStart childPortA3B "${logDir}/requests-a3b.jsonl" childCommandA3B;

      Restart = "on-abnormal";
      RestartSec = "3";

      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
      ];
    };
  };

  # Third socket-activated service: the gzenz fork engine on port 8084 (front) / 8085 (child), serving the same Qwen3.8-27B NVFP4 artifact as the upstream engine (8080/8081). Same idle-unload pattern; the two are mutually exclusive in practice (one 32 GB card).
  systemd.sockets.ninfer-serve-gzenz = {
    description = "NInfer (gzenz fork) engine socket (socket activation, on-demand model residency)";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "127.0.0.1:8084";
    };
  };

  systemd.services.ninfer-serve-gzenz = {
    description = "NInfer (gzenz fork) engine for Qwen3.8-27B NVFP4 (socket-activated, unloads after ${toString idleSeconds}s idle)";
    after = [ "ninfer-serve-gzenz.socket" ];

    serviceConfig = {
      Type = "simple";

      ExecStart = serveExecStart childPortGzenz requestLogGzenz childCommandGzenz;

      Restart = "on-abnormal";
      RestartSec = "3";

      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
      ];
    };
  };

  # Fourth socket-activated service: the Swift (abliterated) Qwen3.8-27B NVFP4 checkpoint on port 8088 (front) / 8089 (child), served by the stock engine. Same idle-unload pattern; mutually exclusive in practice (one 32 GB card).
  systemd.sockets.ninfer-serve-swift = {
    description = "NInfer (Swift abliterated) engine socket (socket activation, on-demand model residency)";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "127.0.0.1:8088";
    };
  };

  systemd.services.ninfer-serve-swift = {
    description = "NInfer (Swift abliterated) engine for Qwen3.8-27B NVFP4 (socket-activated, unloads after ${toString idleSeconds}s idle)";
    after = [ "ninfer-serve-swift.socket" ];

    serviceConfig = {
      Type = "simple";

      ExecStart = serveExecStart childPortSwift requestLogSwift childCommandSwift;

      Restart = "on-abnormal";
      RestartSec = "3";

      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
      ];
    };
  };

  # Fifth socket-activated service: the Cinference fork engine (MTP-10) on port 8091 (front) / 8092 (child), serving the Swift (abliterated) Qwen3.8-27B NVFP4 checkpoint. Same idle-unload pattern; mutually exclusive in practice (one 32 GB card).
  systemd.sockets.ninfer-serve-cinference = {
    description = "Cinference (MTP-10 fork) engine socket (socket activation, on-demand model residency)";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "127.0.0.1:8091";
    };
  };

  systemd.services.ninfer-serve-cinference = {
    description = "Cinference (MTP-10 fork) engine for Qwen3.8-27B NVFP4 (socket-activated, unloads after ${toString idleSeconds}s idle)";
    after = [ "ninfer-serve-cinference.socket" ];

    serviceConfig = {
      Type = "simple";

      ExecStart = serveExecStart childPortCinference requestLogCinference childCommandCinference;

      Restart = "on-abnormal";
      RestartSec = "3";

      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
      ];
    };
  };
}
