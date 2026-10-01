# `inputs` is a NixOS specialArg (see flake.nix specialArgs); it is destructured here (not a free variable) so the flakeless `ninfer` / `ninfer-gzenz` source inputs are in scope.
{ config, pkgs, lib, inputs, catalog, ... }:

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

  # Cinference fork: a focused NInfer fork (satellitedown/cinference) that raises the MTP draft window to 10 and derives CUDA Graph topology classes from the captured graph. The fork rebases onto a newer NInfer than the stock pin, and the drift touches src/serve/*: the fork's own --verify-tree flag shifts the usage-text layout the reasoning-effort patch edits, so it gets its own rebased copy of that patch (reasoning-effort-cinference.patch) instead of the shared stock one. Re-sync that copy whenever the fork is re-pinned.
  # Source from the flakeless `cinference` input; `nix flake update cinference` re-pins it.
  cinference = mkNinfer {
    pname = "cinference";
    src = inputs.cinference;
    patchFile = ./reasoning-effort-cinference.patch;
    homepage = "https://github.com/satellitedown/cinference";
  };

  # Shared idle wrapper (../idle-wrapper): the child-process backend's lifecycle
  # machinery, once. Lifecycle mode binds no port — the gate owns the door.
  # The shared lifecycle unit shape (../lifecycle.nix): the idle wrapper in
  # lifecycle mode, no wantedBy, the activity file named after the unit.
  lifecycle = import ../lifecycle.nix { inherit lib pkgs catalog; };

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
  # --request-log-jsonl is what ninfer-serve itself writes (the gate, not the
  # wrapper, decides when the model is idle); --pending-timeout-ms 900000 and
  # --default-max-tokens 200000 override the fork's too-aggressive defaults.
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

  # The serve units, generated from the ledger: the port, the unit name, and
  # the model's display name come from catalog/default.nix, so the gate's
  # routing table and these units cannot drift apart.
  serveEngines = [
    {
      row = catalog.models.qwen38_nvfp4_ninfer;
      childCommand = childCommand;
    }
    {
      row = catalog.models.qwen36_a3b_ninfer;
      childCommand = childCommandA3B;
    }
    {
      row = catalog.models.qwen38_nvfp4_ninfer_gzenz;
      childCommand = childCommandGzenz;
    }
    {
      row = catalog.models.qwen38_swift_abliterated_nvfp4_ninfer;
      childCommand = childCommandSwift;
    }
    {
      row = catalog.models.qwen38_nvfp4_ninfer_cinference;
      childCommand = childCommandCinference;
    }
  ];

in
{
  environment.systemPackages = [ ninfer ninferGzenz cinference ];

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0755 root root -"
    "d ${logDir} 0755 root root -"
  ];

  system.activationScripts.ninferModel.text = downloadNinferModel "ninfer-qwen38-nvfp4" ninferModelRepo modelsDir ninferModelFile;

  system.activationScripts.ninferModelA3B.text = downloadNinferModel "ninfer-qwen36-a3b" ninferModelRepoA3B modelsDir ninferModelFileA3B;
  # No socket unit and no front port: the gate owns the one public door, so an
  # engine's own loopback port is private plumbing that only the gate forwards
  # to. Each unit is the shared lifecycle shape (../lifecycle.nix): started on
  # demand, resident only while the gate stamps its activity file, and it exits
  # (code 0) once that file ages past the idle window — which releases the VRAM.
  systemd.services = lib.listToAttrs (map
    (e: {
      name = e.row.unit;
      value = lifecycle {
        unit = e.row.unit;
        wrapper = "ninfer_wrapper.py";
        childPort = e.row.port;
        idleSeconds = idleSeconds;
        readyTimeoutSeconds = 1800;
        shutdownTimeoutSeconds = 30;
        killTimeoutSeconds = 10;
        childCommand = e.childCommand;
        description = "NInfer engine for ${e.row.name} (${e.row.provider}) — lifecycle daemon, unloads after ${toString idleSeconds}s idle";
        environment = [
          "CUDA_VISIBLE_DEVICES=0"
          "LD_LIBRARY_PATH=/run/opengl-driver/lib"
        ];
      };
    })
    serveEngines);
}
