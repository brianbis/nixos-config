# Factory: transform omarchy model recipes into NixOS systemd units.
#
# Each recipe produces:
#   - systemd.services.<id>-download   (oneshot, hf download, revision-gated)
#   - systemd.services.<id>            (socket-activated engine, idle wrapper)
#   - systemd.sockets.<id>             (socket unit, on-demand activation)
#   - systemd.targets.<id>-prep        (wants the download service)
#
# Two engine backends:
#   - "tabbyapi": runs the exllamav3-based tabbyapi venv (pkgs.tabbyapi)
#   - "sglang":   runs the existing sglang venv (pkgs.sglang)

{ lib, pkgs, config, idleWrapper, hfTokenPath }:

{ id, recipe }:

let
  inherit (recipe) engine;

  # ─── Download service ──────────────────────────────────────────────────────

  modelDir =
    if recipe.weights.layout == "dir"
    then "/var/lib/omarchy/${id}"
    else "/var/lib/omarchy/hf-cache";

  downloadScript = pkgs.writeShellScript "omarchy-download-${id}" ''
    set -euo pipefail

    mkdir -p "${modelDir}"

    REVISION_FILE="${modelDir}.revision-${id}"
    recorded="none"

    if [ -f "$REVISION_FILE" ]; then
      recorded="$(cat "$REVISION_FILE")"
    fi

    missing=0

    for f in ${lib.concatStringsSep " " (map (f: ''"${f}"'') recipe.weights.sentinels)}; do
      [ -f "${modelDir}/$f" ] || missing=1
    done

    if [ "$recorded" = "${recipe.weights.revision}" ] && [ "$missing" = "0" ]; then
      echo "omarchy-${id}: revision ${recipe.weights.revision} present, skipping download"
      exit 0
    fi

    echo "omarchy-${id}: downloading ${recipe.weights.repository} @ ${recipe.weights.revision} (recorded: $recorded)"

    export HF_TOKEN="$(${pkgs.coreutils}/bin/cat ${hfTokenPath} | ${pkgs.coreutils}/bin/tr -d '\n')"
    export HF_HUB_DOWNLOAD_TIMEOUT=600
    export HF_HOME="${modelDir}"

    ${pkgs.python3Packages.huggingface-hub}/bin/hf download \
      "${recipe.weights.repository}" \
      --revision "${recipe.weights.revision}" \
      --token "$HF_TOKEN" \
      --local-dir "${modelDir}"

    echo "${recipe.weights.revision}" > "$REVISION_FILE"
    echo "omarchy-${id}: download complete"
  '';

  # ─── Engine service ────────────────────────────────────────────────────────

  idleSeconds = 120;

  # The child command (what the idle wrapper execs).
  childCommand =
    if engine == "tabbyapi"
    then
      let
        # The config file path (mounted from the Nix store asset).
        configPath = "${pkgs.writeText "omarchy-config-${id}" (builtins.readFile recipe.configAsset)}";
      in
      [
        "${pkgs.tabbyapi}/bin/python3"
        "${pkgs.tabbyapi}/main.py"
        "--config"
        configPath
      ]
    else
      # sglang: the engine binary + the recipe's args + our child port.
      [
        "${pkgs.sglang}/bin/sglang"
        "serve"
      ]
      ++ recipe.sglangArgs
      ++ [
        "--port" (toString recipe.childPort)
      ];
  

  # The full ExecStart: python3 + idle wrapper + child command.
  execStart = lib.concatStringsSep " " ([
    "${pkgs.python3}/bin/python3"
    "${idleWrapper}/sglang_wrapper.py"
    "--child-port" (toString recipe.childPort)
    "--idle-seconds" (toString idleSeconds)
    "--ready-timeout" "3600"
    "--shutdown-timeout" "60"
    "--kill-timeout" "30"
    "--"
  ]
  ++ childCommand);

  # Environment for the engine service.
  engineEnv =
    if engine == "tabbyapi"
    then [
      "CUDA_VISIBLE_DEVICES=0"
      "TABBYAPI_PORT=${toString recipe.childPort}"
      "LD_LIBRARY_PATH=${pkgs.tabbyapi}/lib:/run/opengl-driver/lib"
      "HF_HOME=${modelDir}"
      "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
    ]
    else [
      "CUDA_VISIBLE_DEVICES=0"
      "LD_LIBRARY_PATH=${pkgs.sglang}/lib:${pkgs.sglang}/venv/lib/python3.12/site-packages/nvidia/cu13/lib:/run/opengl-driver/lib"
      "HF_HOME=${modelDir}"
      "CUDA_HOME=${pkgs.sglang}/cuda-home"
      "MAX_JOBS=6"
      "TRITON_LIBCUDA_PATH=/run/opengl-driver/lib"
      "CC=${pkgs.stdenv.cc}/bin/cc"
      "CXX=${pkgs.stdenv.cc}/bin/c++"
      "PATH=${pkgs.sglang}/venv/bin:${pkgs.stdenv.cc}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"
    ];

in
{
  # ─── tmpfiles: model directories ───────────────────────────────────────────

  systemd.tmpfiles.rules = [
    "d ${modelDir} 0755 root root -"
  ];

  # ─── Download service (oneshot, revision-gated) ────────────────────────────

  systemd.services."omarchy-${id}-download" = {
    description = "Download omarchy model ${recipe.name} (${recipe.format})";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${downloadScript}";
    };
  };

  # ─── Prep target (wants the download) ──────────────────────────────────────

  systemd.targets."omarchy-${id}-prep" = {
    description = "Prepare omarchy ${recipe.name} runtime";
    wants = [ "omarchy-${id}-download.service" ];
    after = [ "omarchy-${id}-download.service" ];
  };

  # ─── Engine service (socket-activated, idle wrapper) ───────────────────────

  systemd.services."omarchy-${id}" = {
    description =
      "Omarchy ${recipe.name} ${engine} engine (socket-activated, unloads after ${toString idleSeconds}s idle)";
    requires = [ "omarchy-${id}-prep.target" ];
    after = [ "omarchy-${id}-prep.target" "omarchy-${id}.socket" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = execStart;
      Restart = "on-abnormal";
      RestartSec = "3";
      Environment = engineEnv;
      # Optional HF token (for hub-layout models that resolve at serve time).
      EnvironmentFile = [ "-/run/vllm/hf-token.env" ];
    };
  };

  # ─── Socket unit ───────────────────────────────────────────────────────────

  systemd.sockets."omarchy-${id}" = {
    description = "Omarchy ${recipe.name} socket (socket activation, on-demand model residency)";
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "127.0.0.1:${toString recipe.frontPort}";
    };
  };
}
