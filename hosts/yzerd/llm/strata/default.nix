# Strata on THIS box (yzerd): one server — the expert-pruned Coder release of
# Qwen3.8-Flash-Next (family "coder", IQ1_M, 256 of 512 experts kept) — on
# :18088 at 200K context, loaded by the engine app the flake builds (setup.py
# + serve/) and run out of a writable copy of that app in /var/lib/strata/app.
#
# This is the desktop module (hosts/desktop/llm/strata/default.nix) trimmed to
# what this box needs: no gate and no catalog here, so there is no lifecycle
# wrapper and no idle window — the serve unit is a plain Type=simple daemon the
# operator starts and stops (systemctl start strata-coder-serve /
# systemctl stop strata-coder-serve); stopping is what releases the card.
# Nothing strata-related boots-resident: the serve unit has no wantedBy, and
# strata-prep.target (the weights) is pulled in only when started by hand.
#
# The two things that differ from the desktop port, and why:
#   - the engine/vision packages are built sm_89 (package.nix / vision.nix):
#     this card is an RTX 4090 (AD102-class, CC 8.9 — nvidia-smi -q reports
#     "NVIDIA GeForce RTX 4090", VBIOS 95.02.3C.40.A4), and an sm_120-only
#     build cannot execute on it.
#   - the weights ARRIVE rather than get downloaded: they already live on the
#     desktop under the same paths (/var/lib/strata/models), so the LAN
#     transfer is preferred and this oneshot is the fallback. The exact-size
#     gate (HF API, sizes below) makes it idempotent AND LAN-preferring: a
#     complete set is left alone, a short/interrupted file is fetched.
#
# Weights: coder repo IQ1_M, two shards — 29608446496 (transformer) +
# 28800138432 (n-gram, memory-mapped, byte-identical to the base release's
# 00002) plus the 907543008-byte mmproj vision encoder; 59.3 GB total,
# ~23 GB resident on the card (24564 MiB total), the rest mmapped. The box has
# 125 GB RAM / 32 logical CPUs, so the engine's conversation cache gets its
# desktop budget unchanged (16 GiB, ~4-6 full 200K conversations).
{ config, lib, pkgs, ... }:

let
  cfg = config.services.strata;

  modelsDir = "/var/lib/strata/models";
  appStamp = "/var/lib/strata/.app-src";
  logDir = "/var/log/strata";
  appDatasDir = "/var/lib/strata/app";

  # The ledger (catalog/models.strata_qwen38_coder) owns this port on the
  # desktop; there is no catalog here, so the same number is repeated literally
  # and every consumer reaches the coder through an ssh tunnel to it.
  childPort = 18088;
  context = 200000;
  model = "IQ1_M";
  modelRepo = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF";
  modelRevision = "5348543e0147355ac9cbcb031184a3546350988e";

  # setup.py's models_dir = <models-dir>/<family-tag + model> = coder-IQ1_M,
  # while the HF repo keeps the quant under IQ1_M/ — the oneshot moves it.
  shardFiles = [
    "coder-IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf"
    "coder-IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf"
  ];
  # Exact byte sizes of the pinned revision (HF API tree, 2026-10-28): the
  # completeness gate, so a LAN-staged set passes untouched and a truncated
  # transfer re-fetches instead of serving a short shard.
  shardSizes = [ 29608446496 28800138432 ];
  mmprojFile = "mmproj-Qwen3.8-Flash-Next-BF16.gguf";
  mmprojSize = 907543008;

  stageSpec = lib.concatStringsSep "\n"
    (lib.zipListsWith (f: s: "${f} ${toString s}") shardFiles shardSizes);
  # Precomputed at the nix level: a string literal carrying its own ${...}
  # cannot appear nested inside another string's interpolation expression.
  hfIncludes = lib.concatStringsSep " "
    (map (g: "--include \"${g}\"") [ "IQ1_M/*" "mmproj-Qwen3.8-Flash-Next-BF16.gguf" ]);

  strataApp = pkgs."strata-vision-app";
  strataVenv = pkgs."strata-serve-env";

  # The card guard from the ledger row (vramMib = 22000 of the 4090's 24564
  # MiB): the engine refuses to load while something else holds the card.
  # No before_load hook — there is no sibling server on this box.
  minFreeVramMib = 22000;

  # Engine 0.1.30's opt-in conversation cache (PR #189): the coder is the model
  # agent work runs on, and without parking every switch of conversations
  # re-reads the other conversation's whole prompt. 16 GiB of host RAM ≈ 4-6
  # full 200K conversations (this box has 125 GB RAM, so the desktop's budget
  # fits with far more headroom); parking is skipped under a 4 GiB free floor.
  conversationCache =
    "--conversation-cache-mib 16384 --conversation-cache-slots 2 --conversation-cache-min-free-mib 4096";

  # The launcher: materialize the (immutable store) app layout into a writable
  # working copy (stamp-guarded, atomic swap beside the live dir), install the
  # model with setup.py --no-start (idempotent), patch in the server-side keys
  # — setup.py rewrites the per-model config on every run, so this python pass
  # is the last word on it — then exec the server itself. idle = 0: no
  # engine-side unload window, the unit is the door.
  launcherScript = name: family: familyTag: modelArg: port: ctx: idle: minFree: beforeLoad: extraEngineArgs:
    let
      cfgFile = "strata-${lib.toLower (familyTag + modelArg)}.json";
    in
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      # Surface nvidia-smi's real NVML error in the journal: setup.py's step 1
      # swallows it (subprocess capture), leaving "did not answer" as the only
      # clue. -L output goes to the journal on success, the NVML error on
      # failure — this box's driver is the open kernel module set, so a failed
      # NVML handshake here is what a start would otherwise hide.
      nvidia-smi -L >&2 || { echo "strata: nvidia-smi precheck failed" >&2; exit 1; }
      src=${strataApp}
      if [ ! -f ${appStamp} ] || [ "$(cat ${appStamp})" != "$src" ]; then
        tmp=$(mktemp -d ${appDatasDir}.new.XXXXXX)
        trap 'rm -rf "$tmp"' ERR
        cp -a "$src/app/." "$tmp"
        chmod -R u+w "$tmp"
        rm -rf ${appDatasDir}.old
        if [ -d ${appDatasDir} ]; then mv ${appDatasDir} ${appDatasDir}.old; fi
        mv -T "$tmp" ${appDatasDir}
        rm -rf ${appDatasDir}.old
        trap - ERR
        echo "$src" > ${appStamp}
      fi
      cd ${appDatasDir}
      # Install (idempotent) and write the per-model config, without starting.
      ${strataVenv}/bin/python3 setup.py \
        --family ${family} \
        --model ${modelArg} \
        --context ${toString ctx} \
        --kv int8 \
        --vision cpu \
        --host 127.0.0.1 \
        --port ${toString port} \
        --models-dir ${modelsDir} \
        --yes \
        --no-start
      # Last word on the config before the start: the server-side keys plus any
      # extra ENGINE args (setup.py owns the base arg list, so the launcher
      # appends them to cfg["args"] here).
      export STRATA_CFG="${appDatasDir}/${cfgFile}"
      export STRATA_IDLE=${toString idle}
      export STRATA_MIN_FREE=${toString minFree}
      export STRATA_BEFORE_LOAD="${beforeLoad}"
      export STRATA_EXTRA_ARGS="${extraEngineArgs}"
      ${strataVenv}/bin/python3 - <<'PY'
      import json, os
      p = os.environ["STRATA_CFG"]
      idle = float(os.environ["STRATA_IDLE"])
      min_free = int(os.environ["STRATA_MIN_FREE"])
      before = os.environ.get("STRATA_BEFORE_LOAD", "")
      extra = os.environ.get("STRATA_EXTRA_ARGS", "")
      cfg = json.load(open(p, encoding="utf-8-sig"))
      if extra:
          cfg["args"] = list(cfg.get("args", [])) + extra.split()
      cfg["min_free_vram_mib"] = min_free
      if before:
          cfg["before_load"] = before
      if idle > 0:
          cfg["idle_unload_s"] = idle
      else:
          cfg.pop("idle_unload_s", None)
      json.dump(cfg, open(p, "w", encoding="utf-8"), indent=1)
      PY
      # Start the server directly (the same command setup.py's start() builds).
      exec ${strataVenv}/bin/python3 serve/server.py \
        --engine strata \
        --config "${appDatasDir}/${cfgFile}" \
        --port ${toString port}
    '';

  coderLauncher =
    launcherScript "strata-launch-coder" "coder" "coder-" model childPort context 0
      minFreeVramMib "" conversationCache;

  # The weights, preferred over LAN: they already live on the desktop under the
  # same paths (/var/lib/strata/models), so the LAN route stages them and this
  # oneshot is the fallback. Same contract setup.py and the desktop's oneshot
  # use — the shards carry "<shard>.done" marks (without them setup.py's step 5
  # would not trust the pre-seeded files and would re-download them under the
  # first request) and the pinned revision is recorded in
  # /var/lib/strata/models.revision-coder — plus an exact-size check, so a
  # LAN transfer that was interrupted mid-file is completed instead of served
  # short. Nothing here runs at boot: strata-prep.target pulls it only when
  # started by hand.
  stage = pkgs.writeShellScriptBin "strata-coder-stage" ''
    set -euo pipefail
    trap 'echo "strata: stage failed at line $LINENO (exit $?)"' ERR
    mkdir -p ${modelsDir}/coder-IQ1_M
    rev_file=${modelsDir}.revision-coder
    recorded=$(cat "$rev_file" 2>/dev/null || echo none)
    c_shard1=${modelsDir}/coder-IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf
    c_shard2=${modelsDir}/coder-IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf
    mmproj=${modelsDir}/${mmprojFile}
    missing=0
    for f in "$c_shard1" "$c_shard2"; do
      [ -f "$f" ] && [ -f "$f.done" ] || missing=1
    done
    [ -f "$mmproj" ] || missing=1
    # Exact bytes of the pinned revision (HF API tree): a short file is a
    # half-finished transfer, not a staged set.
    [ "$(stat -c %s "$c_shard1" 2>/dev/null || echo 0)" = "29608446496" ] || missing=1
    [ "$(stat -c %s "$c_shard2" 2>/dev/null || echo 0)" = "28800138432" ] || missing=1
    [ "$(stat -c %s "$mmproj" 2>/dev/null || echo 0)" = "907543008" ] || missing=1
    if [ "$recorded" = "${modelRevision}" ] && [ "$missing" = "0" ]; then
      echo "strata: coder ${model} @ ${modelRevision} present, skipping (LAN-staged set)"
      exit 0
    fi
    # The pinned revision, one pass: both IQ1_M shards and the vision encoder
    # (the coder repo carries the same mmproj bytes the base release does, and
    # this box runs the coder alone).
    echo "strata: fetching ${modelRepo} @ ${modelRevision} (recorded: $recorded)"
    export HF_HUB_DOWNLOAD_TIMEOUT=600
    ${pkgs.python3Packages.huggingface-hub}/bin/hf download \
      ${modelRepo} \
      --revision ${modelRevision} \
      --local-dir ${modelsDir} \
      ${hfIncludes}
    # hf keeps the repo's IQ1_M/ subdir; setup.py reads coder-IQ1_M/
    mv -T ${modelsDir}/IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf "$c_shard1"
    mv -T ${modelsDir}/IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf "$c_shard2"
    rmdir ${modelsDir}/IQ1_M 2>/dev/null || true
    # setup.py's own completion marks: without them its step 5 would not trust
    # the pre-seeded shards and would re-download them under the first request
    touch "$c_shard1.done" "$c_shard2.done"
    echo ${modelRevision} > "$rev_file"
    echo "strata: coder weights staged"
  '';
in
{
  options.services.strata = {
    enable = lib.mkEnableOption
      "the Strata Qwen3.8-Flash-Next Coder server (${model} on :${toString childPort} @${toString context})";
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /var/lib/strata 0755 root root -"
      "d ${modelsDir} 0755 root root -"
      "d ${logDir} 0755 root root -"
    ];

    systemd.services = {
      strata-coder-stage = {
        description = "Strata coder weights (${model}, revision-gated: LAN-staged or HF-fetched)";
        # Manual start only (the LAN route stages the files instead); nothing
        # fetches tens of GB at boot.
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${stage}/bin/strata-coder-stage";
        };
      };

      strata-coder-serve = {
        description = "Strata Qwen3.8-Flash-Next Coder server (${model}, resident on :${toString childPort} while started)";
        # Manual start only: no gate on this box, so the operator is the door —
        #   systemctl start strata-coder-serve   (loads ~23 GB onto the card)
        #   journalctl -u strata-coder-serve -f
        #   curl -s http://127.0.0.1:18088/health
        #   systemctl stop strata-coder-serve    (releases the card)
        # Start strata-prep.target first, or stage the weights over the LAN.
        requires = [ "strata-prep.target" ];
        after = [ "strata-prep.target" ];

        path = [ config.hardware.nvidia.package.bin pkgs.curl ];

        # setup.py's step 1 shells out to a bare nvidia-smi (the driver package's
        # bin output, not its main out); curl is for the server's own hooks.
        # LD_LIBRARY_PATH is the host driver's userspace (libcuda.so.1) — the
        # engine links nixpkgs' CUDA libs by rpath, the device side is this box's
        # 615.78.08 open-module driver.
        environment = [
          "CUDA_VISIBLE_DEVICES=0"
          "LD_LIBRARY_PATH=/run/opengl-driver/lib"
        ];

        serviceConfig = {
          Type = "simple";
          ExecStart = "${coderLauncher}/bin/strata-launch-coder";
          # The engine's CPU expert pool (one worker per logical CPU) shares the
          # CFS pie with whatever else runs here; double its share under
          # contention (a raw [Service] lvalue — no NixOS option for it).
          CPUWeight = 200;
        };
      };
    };

    systemd.targets.strata-prep = {
      description = "Strata: coder weights staged";
      after = [ "strata-coder-stage.service" ];
      wants = [ "strata-coder-stage.service" ];
    };
  };
}
