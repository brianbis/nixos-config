# Strata: engine dedicated to Qwen3.8-Flash-Next GGUFs (GSQ-RCO quants by
# ISTA-DASLab). House pattern: socket-activated front port, idle wrapper that
# unloads after inactivity (VRAM + the mapped RAM experts come back), revision-
# gated model download oneshot.
#
# Configuration for THIS machine (62 GiB RAM, RTX 5090 32 GB): IQ3_XXS at
# 128K context. 47.0 GB resident (VRAM 32 + RAM 15), the Q3.5 IQ3_S wants
# 54.8 GB resident = the whole machine with nothing else open, and 262K is
# above the documented 64-GB-ceiling for this size, so IQ3_XXS/131072 is the
# best reasonable point: matches-near-base quality with KV headroom.
#
# Enable only after the weights are present (systemctl start strata-model-
# download), enabling flips nothing else; the engine/venv builds are already
# in the flake.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.strata;
  modelsDir = "/var/lib/strata/models";
  appStamp = "/var/lib/strata/.app-src";
  logDir = "/var/log/strata";

  frontPort = 18085;
  childPort = 18086;
  idleSeconds = 300;

  context = 131072;
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

  idleWrapper = pkgs.callPackage ../idle-wrapper { };
  strataApp = pkgs."strata-vision-app";
  strataVenv = pkgs."strata-serve-env";

  # Materializes the (immutable store) app layout into a writable working
  # copy, then hands off to the server. Re-materializes only when the app
  # package changes; the model dir is left untouched by app rebuilds.
  launcher = pkgs.writeShellScriptBin "strata-launch" ''
    set -euo pipefail
    src=${strataApp}
    if [ ! -f ${appStamp} ] || [ "$(cat ${appStamp})" != "$src" ]; then
      rm -rf ${appDatasDir}
      cp -a "$src/app" ${appDatasDir}
      chmod -R u+w ${appDatasDir}
      echo "$src" > ${appStamp}
    fi
    cd ${appDatasDir}
    exec ${strataVenv}/bin/python3 setup.py \
      --family qwen \
      --model ${model} \
      --context ${toString context} \
      --kv int8 \
      --vision gpu \
      --host 127.0.0.1 \
      --port ${toString childPort} \
      --models-dir ${modelsDir} \
      --yes
  '';

  # The engine app dir (writable copy in state) + its stamp live under
  # /var/lib/strata; keep the path in one place.
  appDatasDir = "/var/lib/strata/app";

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
      ${lib.concatStringsSep " " (lib.map (g: "--include \"$g\"") shardGlobs)}
    # setup.py's own completion marks: without them its step 5 would not trust
    # the pre-seeded shards and would re-download them under the first request
    for f in ${lib.concatStringsSep " " shardFiles}; do
      touch ${modelsDir}/$f.done
    done
    echo ${modelRevision} > "$rev_file"
    echo "strata: download complete"
  '';
in
{
  options.services.strata = {
    enable = lib.mkEnableOption "the Strata Qwen3.8-Flash-Next server (${model} @${toString context}, front :${toString frontPort})";
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /var/lib/strata 0755 root root -"
      "d ${modelsDir} 0755 root root -"
      "d ${logDir} 0755 root root -"
    ];

    # One-shot, revision-gated weights download (75.8 GB total: 47.0 GB
    # transformer shard + 28.8 GB n-gram shard + 0.91 GB mmproj). The n-gram
    # shard is memory-mapped at runtime and does not need to stay resident.
    systemd.services.strata-model-download = {
      description = "Strata weights download (IQ3_XXS, revision-gated)";
      wantedBy = [ "strata-prep.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${downloader}/bin/strata-model-download";
      };
    };

    systemd.targets.strata-prep = {
      description = "Strata: weights present";
      after = [ "strata-model-download.service" ];
      wants = [ "strata-model-download.service" ];
    };

    systemd.sockets.strata-serve = {
      description = "Strata server socket (${model} @${toString context})";
      wantedBy = [ "sockets.target" ];
      socketConfig.ListenStream = "127.0.0.1:${toString frontPort}";
    };

    systemd.services.strata-serve = {
      description = "Strata Qwen3.8-Flash-Next server (${model}, unloads after ${toString idleSeconds}s idle)";
      requires = [ "strata-prep.target" ];
      after = [ "strata-prep.target" "strata-serve.socket" ];
      serviceConfig = {
        Type = "simple";
        # The idle wrapper relays front->child, tracks in-flight connections,
        # health-probes the child, and exits 0 after the idle window (freeing
        # the VRAM allocator and the mapped expert arena).
        ExecStart = lib.concatStringsSep " " (
          [
            "${pkgs.python3}/bin/python3"
            "${idleWrapper}/sglang_wrapper.py"
            "--child-port" (toString childPort)
            "--idle-seconds" (toString idleSeconds)
            "--ready-timeout" "3600"   # cold load maps 47 GB + warms the vision encoder
            "--shutdown-timeout" "60"
            "--kill-timeout" "30"
            "--"
            "${launcher}/bin/strata-launch"
          ]
        );
        Restart = "on-abnormal";
        RestartSec = "3";
        Environment = [
          "CUDA_VISIBLE_DEVICES=0"
          # The engine links the nixpkgs CUDA libs via rpath; this is the
          # host driver userspace (libcuda.so.1), same as the other engines.
          "LD_LIBRARY_PATH=/run/opengl-driver/lib"
        ];
      };
    };
  };
}