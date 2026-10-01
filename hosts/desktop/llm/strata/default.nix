# Strata: engine dedicated to Qwen3.8-Flash-Next GGUFs (GSQ-RCO quants by
# ISTA-DASLab). House pattern: a server per model on its own port, run as a
# lifecycle daemon under the shared idle wrapper — nothing strata-related starts
# at boot. The gate (../gate) starts a serve unit when a request names one of
# these models and the card has room; the server loads the model at process
# start (serve/server.py's main() blocks until the engine reports READY) and
# the wrapper exits (code 0) once the gate stops stamping the unit's activity
# file, releasing the VRAM and the mapped RAM experts.
#
# The server binds its own loopback port and nothing else does: there is no
# front port and no socket unit, so the before-load hook targets the sibling's
# port directly — a refused connection there means the sibling is not running
# and there is nothing to unload.
#
# Two models on this machine (62 GiB RAM, RTX 5090 32 GB), one engine instance
# each on its own port; both idle-unloading, so they time-slice the box instead
# of having to fit in RAM together:
#   - base (family qwen, IQ3_XXS, all 512 experts): 47.0 GB resident (VRAM 32
#     + RAM 15); the Q3.5 IQ3_S wants 54.8 GB resident = the whole machine with
#     nothing else open, and 262K is above the documented 64-GB ceiling for
#     this size, so IQ3_XXS/131072 is the best reasonable point: matches-
#     near-base quality with KV headroom. Binds :18086.
#   - coder (family coder, IQ1_M, the expert-pruned Coder release's only size:
#     256 of 512 experts kept for code/tools/vision): ~23 GB resident, runs the
#     full 262K qwen max (262144) — the smaller resident footprint leaves KV
#     headroom the base quant can't. Binds :18088. It also gets the engine's
#     opt-in conversation cache (0.1.30, PR #189): a 16 GiB host-RAM budget
#     parking up to 6 agent conversations, so alternating requests (main chat
#     + subagent workers) restore the other conversation instead of re-reading
#     its whole prompt — the ~24 GB free while it runs is what holds them;
#     parking is skipped when physical RAM free drops under 4 GiB (other
#     programs running). See coderConversationCache below for the detail.
#
# Both run the same strata app (setup.py's family/size selection, the served
# model id is each family's fixed server-side name) out of the ONE shared
# materialized app dir; weights live under ${modelsDir}/<family-tag+size>/.
# Two files are byte-identical across the two HF repos (sha256-verified
# 2026-09-29) and are downloaded exactly once: the 28.8 GB n-gram shard
# (00002, sha256 316b46f3...e113 — the coder's copy is a hardlink of the
# base's) and the mmproj vision encoder (b1a822...49bd0, the base oneshot's).
#
# Enable only after the weights are present (systemctl start strata-model-
# download [and strata-model-download-coder]); enabling flips nothing else;
# the engine/venv builds are already in the flake.
{ config, lib, pkgs, catalog, ... }:

let
  cfg = config.services.strata;
  modelsDir = "/var/lib/strata/models";
  appStamp = "/var/lib/strata/.app-src";
  logDir = "/var/log/strata";

  # The ledger rows own the ports and the unit names: each server binds its
  # own loopback port and there is no front port to hold — the gate (../gate)
  # is the only door.
  baseRow = catalog.models.strata_qwen38;
  coderRow = catalog.models.strata_qwen38_coder;
  childPort = baseRow.port;
  coderChildPort = coderRow.port;
  idleSeconds = 300;
  # How long the wrapper may wait for the child to become ready: the server
  # loads the model at process start; a cold load maps tens of GB into RAM and
  # warms the vision encoder, so the bound is generous (the value the
  # single-model setup ran with before the rework).
  readyTimeout = 3600;

  # The server-side idle/unload settings (injected into each model's config by
  # the launcher, below). The free-VRAM guard keeps a model from loading into a
  # GPU the sibling (or a game) is using; the before-load hook unloads the
  # sibling first so the two can time-slice one card. The hook targets the
  # sibling's CHILD port (see the header): refused connection = the sibling is
  # not running, nothing to unload; `|| true` keeps that normal answer from
  # reading as a hook failure.
  # The same numbers the gate reads before it starts these units.
  baseMinFreeVramMib = baseRow.vramMib;
  coderMinFreeVramMib = coderRow.vramMib;
  baseBeforeLoad = "curl -s -X POST http://127.0.0.1:${toString coderChildPort}/unload || true";
  coderBeforeLoad = "curl -s -X POST http://127.0.0.1:${toString childPort}/unload || true";

  context = 131072; # base: IQ3_XXS at 262K is above the documented 64-GB ceiling
  coderContext = 200000; # coder: IQ1_M (~23 GB resident) runs the full 262K qwen max
  model = "IQ3_XXS";
  modelRepo = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF";
  # Revision gate for the download oneshot (repo main at pin time).
  modelRevision = "2a55d75962e22f7a4a1d9963ab6eae3678537831";
  # The HF repo keeps each quant under <size>/, and setup.py reads
  # <models-dir>/IQ3_XXS/<shard> for its shards and <models-dir>/<mmproj> for the
  # vision encoder (setup.py: models_dir = <models-dir>/<family-tag + model>).
  shardFiles = [
    "IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf"
    "IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf"
  ];
  mmprojFile = "mmproj-Qwen3.8-Flash-Next-BF16.gguf";
  shardGlobs = [ "IQ3_XXS/*" "mmproj-Qwen3.8-Flash-Next-BF16.gguf" ];
  # Precomputed at nix level: a string literal carrying its own ${...} cannot
  # appear nested inside another string's interpolation expression.
  hfIncludes = lib.concatStringsSep " " (lib.map (g: "--include \"${g}\"") shardGlobs);

  # The Coder release: one expert-pruned quant (IQ1_M), its own HF repo; setup.py
  # (family "coder", tag "coder-") reads <models-dir>/coder-IQ1_M/<shard>.
  coderModel = "IQ1_M";
  coderModelRepo = "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-Coder-GGUF";
  coderModelRevision = "5348543e0147355ac9cbcb031184a3546350988e";
  coderShardFiles = [
    "coder-IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf"
    "coder-IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf"
  ];

  strataApp = pkgs."strata-vision-app";
  strataVenv = pkgs."strata-serve-env";

  # The engine app dir (writable copy in state) + its stamp live under
  # /var/lib/strata; keep the path in one place.
  appDatasDir = "/var/lib/strata/app";

  # Materializes the (immutable store) app layout into a writable working
  # copy, then installs the model (setup.py --no-start, idempotent) and hands
  # off to the server. Re-materializes only when the app package changes; the
  # model dir is left untouched by app rebuilds. One instance per listening
  # port; BOTH models run out of the same app dir (setup.py plants a per-model
  # run config in it), and launchers of different models may cold-start
  # concurrently: materialize beside the live dir and swap in with an atomic
  # rename (identical store content, so a swap racing one is harmless) instead
  # of overwriting the live trees in place.
  #
  # idle: the server's own idle-unload window (0 = the "direct" debug mode, the
  # model stays loaded). minFree/beforeLoad: the free-VRAM guard and the
  # before-load hook (see the header). setup.py rewrites the per-model config on
  # every run, so those settings are patched in after the write, before the
  # start; the server is then started directly (the same command setup.py's
  # start() builds).
  launcherScript = name: family: familyTag: modelArg: port: ctx: idle: minFree: beforeLoad: extraEngineArgs:
    let
      cfgFile = "strata-${lib.toLower (familyTag + modelArg)}.json";
    in
    pkgs.writeShellScriptBin name ''
      set -euo pipefail
      # Surface nvidia-smi's real NVML error in the journal: setup.py's step 1
      # swallows it (subprocess capture), leaving "did not answer" as the only
      # clue. -L output goes to the journal on success (one useful line per
      # start) and the NVML error to it on failure.
      nvidia-smi -L >&2 || { echo "strata: nvidia-smi precheck failed" >&2; exit 1; }
      src=${strataApp}
      if [ ! -f ${appStamp} ] || [ "$(cat ${appStamp})" != "$src" ]; then
        tmp=$(mktemp -d ${appDatasDir}.new.XXXXXX)
        trap 'rm -rf "$tmp"' ERR
        # Copy the CONTENTS into the tmp dir (cp -a into an existing dir would
        # nest the app under $tmp/app/); $tmp then swaps in as the app dir.
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
      # Patch in the server-side idle/unload settings (setup.py rewrote the
      # config above, so this is the last word on it before the start), plus
      # any extra ENGINE args: setup.py owns the base arg list, so the
      # launcher appends them to cfg["args"] here — the same "last word"
      # rule as the server keys below.
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
  # serve units run the child-port variant: the server binds its loopback port
  # and the gate forwards to it. The direct (manual debug) units bind the
  # ledger port themselves, with no idle unload — the model stays resident.
  # The coder's engine-arg extras: the conversation cache (engine 0.1.30's
  # opt-in, PR #189). Without it the engine keeps ONE conversation live: an
  # agent client that alternates requests (main chat + subagent workers)
  # re-reads the other conversation's whole prompt on every switch, which is
  # the ~25% cache rate seen while the coder runs. Parking turns that into a
  # restore: up to N conversations live in a bounded host-RAM cache (a cap,
  # not a reservation — snapshots are captured on demand, ~13.7 KB/token of
  # int8 KV + the ~118 MB checkpoints, so a 16 GiB budget holds ~4 full
  # 200K-token conversations or many shorter agent ones). The box has ~24 GB
  # free while the coder is resident (~23 GB experts + KV + checkpoints of
  # its 62 GB), so 16 GiB of it goes to the cache; the min-free floor makes
  # the engine skip parking (gracefully: ordinary prompt processing) when
  # other programs have taken the RAM below 4 GiB, which is the
  # "other stuff may be running" guard. Slots 6 > the docs' 4 so a wider
  # agent fan-out stays parked; the budget evicts the oldest first.
  # Snapshots do not persist across an idle unload — the cache rebuilds as
  # the conversations come back. Base (IQ3_XXS, 47 GB resident) deliberately
  # stays uncached: it is not the model the agent work runs on and its
  # resident footprint plus 16 GiB would leave no headroom.
  coderConversationCache =
    "--conversation-cache-mib 16384 --conversation-cache-slots 6 --conversation-cache-min-free-mib 4096";

  launcherChild = launcherScript "strata-launch-child" "qwen" "" model childPort context idleSeconds baseMinFreeVramMib baseBeforeLoad "";
  launcherDirect = launcherScript "strata-launch-direct" "qwen" "" model childPort context 0 baseMinFreeVramMib baseBeforeLoad "";
  coderLauncherChild = launcherScript "strata-launch-coder-child" "coder" "coder-" coderModel coderChildPort coderContext idleSeconds coderMinFreeVramMib coderBeforeLoad coderConversationCache;
  coderLauncherDirect = launcherScript "strata-launch-coder-direct" "coder" "coder-" coderModel coderChildPort coderContext 0 coderMinFreeVramMib coderBeforeLoad coderConversationCache;

  downloader = pkgs.writeShellScriptBin "strata-model-download" ''
    set -euo pipefail
    trap 'echo "strata: download failed at line $LINENO (exit $?)"' ERR
    mkdir -p ${modelsDir}
    rev_file=${modelsDir}.revision
    recorded=$(cat "$rev_file" 2>/dev/null || echo none)
    missing=0
    for f in ${lib.concatStringsSep " " shardFiles} ${mmprojFile}; do
      [ -f ${modelsDir}/$f ] || missing=1
    done
    for f in ${lib.concatStringsSep " " shardFiles}; do
      [ -f ${modelsDir}/$f.done ] || missing=1
    done
    if [ "$recorded" = "${modelRevision}" ] && [ "$missing" = "0" ]; then
      echo "strata: ${model} @ ${modelRevision} present, skipping download"
      exit 0
    fi
    echo "strata: downloading ${modelRepo} @ ${modelRevision} (recorded: $recorded)"
    export HF_HUB_DOWNLOAD_TIMEOUT=600
    ${pkgs.python3Packages.huggingface-hub}/bin/hf download \
      ${modelRepo} \
      --revision ${modelRevision} \
      --local-dir ${modelsDir} \
      ${hfIncludes}
    # setup.py's own completion marks: without them its step 5 would not trust
    # the pre-seeded shards and would re-download them under the first request
    for f in ${lib.concatStringsSep " " shardFiles}; do
      touch ${modelsDir}/$f.done
    done
    echo ${modelRevision} > "$rev_file"
    echo "strata: download complete"
  '';

  # The coder needs only its 29.6 GB transformer shard of its own: the 28.8 GB
  # n-gram shard (00002) is content-identical to the base's (see header) and
  # comes back as a hardlink (this unit runs after strata-model-download); the
  # mmproj is the base oneshot's file. If the base copy is not usable yet the
  # oneshot falls back to downloading the shard from the coder repo itself.
  coderDownloader = pkgs.writeShellScriptBin "strata-model-download-coder" ''
    set -euo pipefail
    trap 'echo "strata: coder download failed at line $LINENO (exit $?)"' ERR
    mkdir -p ${modelsDir}/coder-IQ1_M
    rev_file=${modelsDir}.revision-coder
    recorded=$(cat "$rev_file" 2>/dev/null || echo none)
    c_shard1=${modelsDir}/coder-IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf
    c_shard2=${modelsDir}/coder-IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf
    b_shard2=${modelsDir}/IQ3_XXS/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf
    missing=0
    for f in "$c_shard1" "$c_shard2"; do
      [ -f "$f" ] && [ -f "$f.done" ] || missing=1
    done
    if [ "$recorded" = "${coderModelRevision}" ] && [ "$missing" = "0" ]; then
      echo "strata: coder ${coderModel} @ ${coderModelRevision} present, skipping download"
      exit 0
    fi
    # Reuse the base's n-gram shard (complete = .done marked, or the exact 28.8 GB
    # size in case the mark is missing) instead of re-downloading it.
    if [ ! -f "$c_shard2" ]; then
      if [ -f "$b_shard2" ] && { [ -f "$b_shard2.done" ] || [ "$(stat -c %s "$b_shard2")" = "28800138432" ]; }; then
        ln "$b_shard2" "$c_shard2"
      else
        echo "strata: base n-gram shard not usable yet, downloading it from the coder repo"
        export HF_HUB_DOWNLOAD_TIMEOUT=600
        ${pkgs.python3Packages.huggingface-hub}/bin/hf download \
          ${coderModelRepo} \
          --revision ${coderModelRevision} \
          --local-dir ${modelsDir} \
          --include "IQ1_M/*00002*"
        # hf keeps the repo's IQ1_M/ subdir; setup.py reads coder-IQ1_M/
        mv -T ${modelsDir}/IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf "$c_shard2"
      fi
    fi
    echo "strata: downloading ${coderModelRepo} @ ${coderModelRevision} (recorded: $recorded)"
    if [ ! -f "$c_shard1" ]; then
      export HF_HUB_DOWNLOAD_TIMEOUT=600
      ${pkgs.python3Packages.huggingface-hub}/bin/hf download \
        ${coderModelRepo} \
        --revision ${coderModelRevision} \
        --local-dir ${modelsDir} \
        --include "IQ1_M/*00001*"
      # hf keeps the repo's IQ1_M/ subdir; setup.py reads coder-IQ1_M/
      mv -T ${modelsDir}/IQ1_M/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf "$c_shard1"
    fi
    # Remove the repo subdir hf leaves behind (empty after the moves above; may
    # also be a leftover from an earlier run)
    rmdir ${modelsDir}/IQ1_M 2>/dev/null || true
    # setup.py's own completion marks: without them its step 5 would not trust
    # the pre-seeded shards and would re-download them under the first request
    touch "$c_shard1.done" "$c_shard2.done"
    echo ${coderModelRevision} > "$rev_file"
    echo "strata: coder download complete"
  '';
# The two serve stacks: same unit shape per model (lifecycle serve unit with the
  # server's own idle unload, plus a manual "direct" debug mode).
  # Base keeps the historic unit names (suffix ""), the coder is suffixed.
  # The served model ids: the server's fixed family names (setup.py FAMILIES,
  # served by serve/server.py and advertised on /v1/models). They must match
  # the catalog ids (home/llm/catalog.nix strata_qwen38 / strata_qwen38_coder).
  baseArgs = {
    suffix = "";
    family = "qwen";
    model = model;
    context = context;
    child = childPort;
    serveBin = "${launcherChild}/bin/strata-launch-child";
    directBin = "${launcherDirect}/bin/strata-launch-direct";
  };
  coderArgs = {
    suffix = "-coder";
    family = "coder";
    model = coderModel;
    context = coderContext;
    child = coderChildPort;
    serveBin = "${coderLauncherChild}/bin/strata-launch-coder-child";
    directBin = "${coderLauncherDirect}/bin/strata-launch-coder-direct";
  };
  allModelArgs = [ baseArgs coderArgs ];

  # The shared lifecycle unit shape (../lifecycle.nix): the idle wrapper in
  # lifecycle mode, no wantedBy, the activity file named after the unit.
  lifecycle = import ../lifecycle.nix { inherit lib pkgs catalog; };

  serveUnit = args:
    let
      unit = "strata${args.suffix}-serve";
    in
    lifecycle {
      unit = unit;
      wrapper = "sglang_wrapper.py";
      childPort = args.child;
      idleSeconds = idleSeconds;
      readyTimeoutSeconds = readyTimeout;
      shutdownTimeoutSeconds = 60;
      killTimeoutSeconds = 30;
      childCommand = [ args.serveBin ];
      description = "Strata Qwen3.8-Flash-Next server (${args.family} ${args.model}, lifecycle daemon, unloads after ${toString idleSeconds}s idle)";

      # No wantedBy: the gate (../gate) starts this unit when a request names
      # the model and the card has room. strata-prep.target (the weight downloads)
      # is pulled in on first use, not at boot; unloading releases the model's
      # VRAM and its mapped RAM experts.
      requires = [ "strata-prep.target" ];
      after = [ "strata-prep.target" ];

      # setup.py's step 1 shells out to a bare `nvidia-smi` (it probes the GPU
      # through that helper binary, not the device nodes directly); the
      # service's default PATH lacks it. nvidia-smi ships in the driver
      # package's `bin` output, not its main `out` (which only carries
      # nvidia-sleep.sh), so the .bin output must be named explicitly.
      # (The NixOS `path` option, not serviceConfig.EnvironmentPATH — that
      # lvalue is not a systemd directive and is silently ignored.)
      # curl is on the PATH for the server's before-load hook (it POSTs /unload
      # to the sibling model).
      path = [ config.hardware.nvidia.package.bin pkgs.curl ];

      environment = [
        "CUDA_VISIBLE_DEVICES=0"
        # The engine links the nixpkgs CUDA libs via rpath; this is the
        # host driver userspace (libcuda.so.1), same as the other engines.
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
      ];

      # The engine's CPU expert pool (one worker per logical CPU) shares the CFS
      # pie with the llamacpp fleet (llamacpp-muse/bonsai stay online at boot),
      # headroom's compression calls and the agent toolchain. At equal weight the
      # decode stalls whenever those are busy; CPUWeight (a raw [Service] lvalue,
      # no NixOS module option for it in this pin) doubles strata's share under
      # contention without starving the rest (they keep the remainder of the pie).
      extraServiceConfig = { CPUWeight = 200; };
    };

  # The per-model "direct" debug channel (the unit bodies above carry the
  # shared rationale for the serve units).
  directUnit = args:
    let
      unit = "strata${args.suffix}";
    in
    {
      description = "Strata direct debug mode (${args.family} ${args.model}, no idle unload, resident on :${toString args.child})";
      requires = [ "strata-prep.target" ];
      after = [ "strata-prep.target" ];
      # Manual start only (no wantedBy), for debugging in the foreground:
      #   systemctl start strata-coder-direct    # stops strata-coder-serve
      #   journalctl -u strata-coder-direct -f
      #   systemctl stop strata-coder-direct
      #   systemctl start strata-coder-serve     # the gate re-stamps it on the next request
      # (same pair without the -coder suffix for the base model). Both bind the
      # same loopback port, so they must not run at once.
      conflicts = [ "${unit}-serve.service" ];
      path = [ config.hardware.nvidia.package.bin pkgs.curl ];
      serviceConfig = {
        Type = "simple";
        # The launcher's setup.py run stays in the foreground; the engine
        # dies only when the service is asked to (no idle window). No Restart:
        # a crash should be visible in the journal, not respawn during debug.
        ExecStart = args.directBin;
        CPUWeight = 200;
        Environment = [
          "CUDA_VISIBLE_DEVICES=0"
          "LD_LIBRARY_PATH=/run/opengl-driver/lib"
        ];
      };
    };
in
{
  options.services.strata = {
    enable = lib.mkEnableOption "the Strata Qwen3.8-Flash-Next servers (base ${model} on :${toString childPort} @${toString context}, coder ${coderModel} on :${toString coderChildPort} @${toString coderContext})";
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /var/lib/strata 0755 root root -"
      "d ${modelsDir} 0755 root root -"
      "d ${logDir} 0755 root root -"
    ];

    systemd.services = lib.listToAttrs (
      [
        # One-shot, revision-gated weight downloads: base is 75.8 GB (47.0 GB
        # transformer shard + 28.8 GB n-gram shard + 0.91 GB mmproj); the coder
        # adds one 29.6 GB transformer shard, its n-gram shard being a hardlink
        # of the base's and its mmproj the base's identical file, so each of
        # those is downloaded exactly once across both models. The n-gram
        # shards are memory-mapped at runtime and do not need to stay resident.
        (lib.nameValuePair "strata-model-download" {
          description = "Strata weights download (IQ3_XXS, revision-gated)";
          wantedBy = [ "strata-prep.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${downloader}/bin/strata-model-download";
          };
        })
        (lib.nameValuePair "strata-model-download-coder" {
          description = "Strata weights download (coder IQ1_M, revision-gated)";
          wantedBy = [ "strata-prep.target" ];
          after = [ "strata-model-download.service" ]; # the n-gram hardlink points at its output
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${coderDownloader}/bin/strata-model-download-coder";
          };
        })
      ]
      ++ (map (a: lib.nameValuePair "strata${a.suffix}-serve" (serveUnit a)) allModelArgs)
      ++ (map (a: lib.nameValuePair "strata${a.suffix}-direct" (directUnit a)) allModelArgs)
    );

    systemd.targets.strata-prep = {
      description = "Strata: weights present";
      after = [ "strata-model-download.service" "strata-model-download-coder.service" ];
      wants = [ "strata-model-download.service" "strata-model-download-coder.service" ];
    };
  };
}
