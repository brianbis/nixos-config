# `inputs` is a NixOS specialArg (see flake.nix specialArgs); it is
# destructured here (not a free variable) so the flakeless `ninfer` /
# `ninfer-gzenz` source inputs are in scope.
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
  requestLogGzenz = "${logDir}/requests-gzenz.jsonl";
  requestLogSwift = "${logDir}/requests-swift.jsonl";

  # Shared build for the NInfer engine. Two engines are built from two
  # different sources: the pinned upstream rev (with the local
  # reasoning-effort patch) and the gzenz fork (which has no serve-level
  # --reasoning-effort flag, so no patch).
  # NB: the patch-file parameter is named patchFile (not patch) so it does not
  # shadow pkgs.patch inside the `with pkgs` build-inputs blocks below.
  mkNinfer = { pname, src, patchFile ? null, homepage }:
    pkgs.stdenv.mkDerivation {
      inherit pname src;
      version = "master";

      # fetchFromGitHub in this nixpkgs pin downloads
      # https://github.com/OWNER/REPO/archive/REV.tar.gz and hashes the
      # *unpacked* tree (fetchzip, recursiveHash = true) — NOT the tarball
      # sha256. Assemble the hash with (substitute OWNER/REPO/REV):
      #   d=$(mktemp -d) && curl -sL "https://github.com/OWNER/REPO/archive/REV.tar.gz" | tar -xz -C "$d" --strip-components=1 && nix hash path "$d" && rm -rf "$d"

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
    # Source from the flakeless `ninfer` input (see flake.nix);
    # `nix flake update ninfer` re-pins it.
    src = inputs.ninfer;
    # The pinned rev has no server-side reasoning-effort default; this patch
    # adds --reasoning-effort so the serve binary can default Qwen3.8 to brief
    # thinking (a per-request effort still wins over the flag).
    patchFile = ./reasoning-effort.patch;
    homepage = "https://github.com/Neroued/ninfer";
  };

  # Parallel engine from the gzenz fork (checkpoint advancement, worker
  # recovery, thinking-signature fixes, QUASAR support). Same build inputs and
  # app layout (ninfer / ninfer-serve); the fork dropped the vendored spdlog,
  # so the shared build inputs still cover it.
  ninferGzenz = mkNinfer {
    pname = "ninfer-gzenz";
    # Source from the flakeless `ninfer-gzenz` input (see flake.nix);
    # `nix flake update ninfer-gzenz` re-pins it.
    src = inputs.ninfer-gzenz;
    homepage = "https://github.com/gzenz/ninfer";
  };

  # Socket-activated idle wrapper (shared with the vLLM containers; the
  # relay/health/idle machinery lives in ../idle-wrapper once). systemd owns
  # the front-port socket; the wrapper relays connections to the child and
  # exits (code 0) once the model is idle, so no process is resident between
  # requests.
  idleWrapper = pkgs.callPackage ../idle-wrapper { };

  # The wrapper's ExecStart for a serve pair: the shared idle wrapper (child
  # backend) plus the per-model child command. All serve pairs share this
  # exact shape.
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

  # The model-serving child. Loopback-only: the wrapper (and thus the
  # socket unit) is the only thing that can reach it.
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

  # Qwen3.6-35B-A3B (sparse MoE, 3B active params). Requires ninfer rev
  # bd265a3 or later (the pinned 8eaed53 satisfies this).
  ninferModelRepoA3B = "neroued/Qwen3.6-35B-A3B-NInfer";
  ninferModelFileA3B = "qwen3_6_35b_a3b.ninfer";

  # Swift (abliterated) Qwen3.8-27B NVFP4 — a community "abliterated" (safety
  # training removed) NVFP4 checkpoint in the same NInfer layout as the stock
  # qwen38-nvfp4 model. Public HF repo (no token required), downloaded
  # declaratively like the others.
  ninferModelRepoSwift = "Dragoy/Swift-Qwen3.8-27B-abliterated-NVFP4-NInfer";
  ninferModelFileSwift = "qwen3_8_27b_swift_abliterated_nvfp4.ninfer";

  # Second serving child: Qwen3.6-35B-A3B on its own loopback port.
  # No --reasoning-effort: the A3B chat template does not support a
  # reasoning-effort control. The flag stays off for this child so the server
  # default stays unset; the template layer rejects an effort it cannot honor
  # at prepare time (the old serve-level startup check was removed upstream).
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

  # Third serving child: the gzenz fork engine on the SAME Qwen3.8-27B NVFP4
  # artifact (reused weights — no new download), on its own loopback port.
  #
  # The point of running the fork in parallel to the stock engine is its
  # COMPRESSED KV format: --kv-dtype nvfp4 stores the KV cache at 144
  # bytes/token/KV-head vs 264 for int8 (45% less), which is what lets this
  # engine run a HIGHER KV-cache limit than the stock int8 engine on the same
  # 32 GB card. YaRN (--rope-scaling-factor) extends context past the 262k
  # native limit. The launch options are therefore deliberately NOT generalized
  # across the two engines:
  #   - stock (ninfer-serve):        int8 KV,  240k context
  #   - gzenz (ninfer-serve-gzenz):  nvfp4 KV, 555k logical ceiling (YaRN 2.12),
  #                                  KV pool auto-sized to fit VRAM (~420k here)
  # Concretely:
  #   - --kv-dtype nvfp4: the compressed format (stock uses int8).
  #   - --max-context 555000: the logical per-request ceiling (YaRN 2.12 extends
  #     the native 262k limit). Stock is 240000.
  #   - --kv-capacity auto: the shared KV pool is sized by the engine to fit the
  #     free VRAM at load time (available minus a 1 GiB headroom), which is the
  #     fork's own 555k pattern (docs/maintainer/kv-nvfp4-yarn.md). An explicit
  #     555000 pool does NOT fit this card: the 555k reservation is ~11.0 GiB
  #     (KV + MTP draft head + state slots) vs ~9.75 GiB free after the ~16 GiB
  #     weights, so the child aborts at load with "requested Engine runtime
  #     reservation requires ... but only ... available for runtime capacity".
  #     Auto resolves to ~420k tokens at the current ~9.75 GiB (still 1.75x the
  #     stock 240k) and grows toward 555k as more VRAM is free at load time.
  #   - --rope-scaling-factor 2.12 / --rope-scaling-original-context 262144:
  #     YaRN extension (262144 * 2.12 ~= 555k); required to exceed the native
  #     262k limit.
  #   - --host-kv-mib 36864: pinned host-RAM KV buffer scaled to the larger KV
  #     (the doc's 555k value; stock uses 32768, the 240k model card 8192).
  #   - --max-concurrency 2: matches stock (the doc's 600k figure is c=1).
  #   - no --reasoning-effort: the fork's serve binary has no such flag (it was
  #     upstream-local to our patch); its Qwen3.8 template defaults to xhigh
  #     thinking, and a per-request reasoning_effort always wins.
  # Two operational flags are kept because the fork's built-in defaults are too
  # aggressive for a production server:
  #   - --pending-timeout-ms 900000 (fork default is 30000 = 30s; long
  #     generations would be cancelled mid-stream)
  #   - --default-max-tokens 200000 (fork default is 8192; matches the catalog
  #     maxTok so requests omitting max_tokens still get the long ceiling)
  # --request-log-jsonl is required by the idle wrapper (it tails the log for
  # in-flight tracking), so it is not a fork launch option.
  # --weights-profile qwen38-nvfp4 is REQUIRED: the fork's auto-detection
  # (targets/qwen3_6_27b/impl/package.cpp resolve_weights) routes the
  # qwen3.8/nvfp4 identity to Qwen36Nvfp4 (W8G32_F16S endpoints) because the
  # fork author's local artifact was an Ostfralla-derived Qwen3.6-layout build.
  # Our artifact is the official neroued/Qwen3.8-27B-nvfp4-NInfer one, which is
  # the FP8 profile (Qwen38Nvfp4, FP8_E4M3FN_ROW_BF16S endpoints). Without the
  # override the token_embedding tensor format mismatches the Qwen36Nvfp4
  # contract and the child aborts at load with
  # "tensor descriptor does not match target contract: text/token_embedding".
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

  # Fourth serving child: the Swift (abliterated) Qwen3.8-27B NVFP4 checkpoint
  # on its own loopback port, served by the stock engine. Same Qwen3.8-27B NVFP4
  # layout as the stock qwen38-nvfp4 model, so it reuses that child's launch
  # options (nvfp4 KV, 240k context, low reasoning effort), with speculative
  # decoding switched to DFlash2: the artifact (2026-09-18 re-conversion) bakes
  # in a 5-layer DFlash2 drafter and the README calls --spec dflash2 the fastest
  # path (1-15 token draft window). The pinned ninfer rev (f76e19c0) is >= the
  # DFlash2 minimum (98dada0e), so the engine supports it. No --weights-profile
  # override: like the stock model it relies on the engine's auto-detection
  # (the abliterated checkpoint keeps the official Qwen3.8 NVFP4 tensor layout).
  # If a load test shows a tensor-format mismatch, add --weights-profile
  # qwen38-nvfp4 here.
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
  environment.systemPackages = [ ninfer ninferGzenz ];

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0755 root root -"
    "d ${logDir} 0755 root root -"
  ];

  system.activationScripts.ninferModel.text = downloadNinferModel "ninfer-qwen38-nvfp4" ninferModelRepo modelsDir ninferModelFile;

  system.activationScripts.ninferModelA3B.text = downloadNinferModel "ninfer-qwen36-a3b" ninferModelRepoA3B modelsDir ninferModelFileA3B;

  system.activationScripts.ninferModelSwift.text = downloadNinferModel "ninfer-qwen38-swift-abliterated" ninferModelRepoSwift modelsDir ninferModelFileSwift;

  # No After=network.target: sockets.target orders before basic.target, but
  # network.target on this host does not (via wpa_supplicant); ordering the
  # socket after network.target would cycle and systemd would drop its job.
  systemd.sockets.ninfer-serve = {
    description = "NInfer engine socket (socket activation, on-demand model residency)";
    wantedBy = [ "sockets.target" ];

    socketConfig = {
      ListenStream = "127.0.0.1:8080";
    };
  };

  systemd.services.ninfer-serve = {
    description = "NInfer engine for Qwen3.8-27B NVFP4 (socket-activated, unloads after ${toString idleSeconds}s idle)";
    # No wantedBy: the service is started by the socket unit on demand and
    # exits (code 0) after the idle window, leaving nothing resident
    # between requests. It must not be pulled in at boot.
    after = [ "ninfer-serve.socket" ];

    serviceConfig = {
      Type = "simple";

      ExecStart = serveExecStart childPort requestLog childCommand;

      # The wrapper exits 0 in every normal path (idle unload, SIGTERM,
      # child failure); only a wrapper crash (signal/coredump) restarts.
      Restart = "on-abnormal";
      RestartSec = "3";

      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
      ];
    };
  };

  # Second socket-activated service: Qwen3.6-35B-A3B on port 8082 (front) /
  # 8083 (child). Same idle-unload pattern as the Qwen3.8 service.
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

  # Third socket-activated service: the gzenz fork engine on port 8084 (front)
  # / 8085 (child), serving the same Qwen3.8-27B NVFP4 artifact as the
  # upstream engine (8080/8081). Same idle-unload pattern; the two are
  # mutually exclusive in practice (one 32 GB card, both socket-activated).
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

  # Fourth socket-activated service: the Swift (abliterated) Qwen3.8-27B NVFP4
  # checkpoint on port 8088 (front) / 8089 (child), served by the stock engine.
  # Same idle-unload pattern as the other three; mutually exclusive in practice
  # (one 32 GB card, all socket-activated on demand).
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
}
