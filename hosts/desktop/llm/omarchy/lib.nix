# Factory: transform omarchy model recipes into NixOS systemd units.
#
# Each recipe produces:
#   - systemd.services.<id>-download   (oneshot, hf download, revision-gated)
#   - systemd.services.<id>            (lifecycle engine, idle wrapper)
#   - systemd.targets.<id>-prep        (wants the download service)
#
# Two engine backends:
#   - "tabbyapi": runs the exllamav3-based tabbyapi venv (pkgs.tabbyapi)
#   - "sglang":   runs the existing sglang venv (pkgs.sglang)

{ lib, pkgs, config, hfTokenPath, catalog }:

{ id, recipe }:

let
  inherit (recipe) engine;

  # The ledger row in ../../../catalog/default.nix is the single source of
  # truth for this model's port and systemd unit name.
  row = catalog.models.${recipe.catalogKey};
  childPort = row.port;
  unit = row.unit;

  # The shared lifecycle unit shape (../lifecycle.nix): the idle wrapper in
  # lifecycle mode, no wantedBy, the activity file named after the unit.
  lifecycle = import ../lifecycle.nix { inherit lib pkgs catalog; };
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

  # ─── Engine runtime package ────────────────────────────────────────────────
  # The tabbyapi venv, or the sglang venv.
  enginePkg =
    if engine == "tabbyapi"
    then pkgs.tabbyapi
    else pkgs.sglang;

  # The child command (what the idle wrapper execs).
  childCommand =
    if engine == "tabbyapi"
    then
      let
        # tabbyAPI's `--config` flag ("Path to an overriding config.yml file");
        # the TABBY_NETWORK_* env vars below override the port/host from it.
        configPath = "${pkgs.writeText "omarchy-config-${id}" (builtins.readFile recipe.configAsset)}";
      in
      # Launch the venv's own python (not a thin $out/bin symlink): CPython
        # detects the venv from the launch path's parent dir (pyvenv.cfg), so a
        # symlink rooted elsewhere makes sys.prefix the base interpreter's.
      [
        "${enginePkg}/venv/bin/python3"
        "${enginePkg}/app/main.py"
        "--config"
        configPath
      ]
    else
      let
        args = recipe.sglangArgs ++ [ "--port" (toString childPort) ];
      in
      [ "${enginePkg}/bin/sglang" "serve" ] ++ args;
  # Environment for the engine service.
  engineEnv =
    if engine == "tabbyapi"
    then [
      "CUDA_VISIBLE_DEVICES=0"
      # tabbyAPI config: the TABBY_NETWORK_* env vars set the child port +
      # loopback host. They are intentionally NOT in the --config asset,
      # because the --config file has the highest merge priority (it is
      # merged last) and would otherwise override them.
      # The child listens here; the gate forwards to it. Loopback-only.
      "TABBY_NETWORK_PORT=${toString childPort}"
      "TABBY_NETWORK_HOST=127.0.0.1"
      "LD_LIBRARY_PATH=${enginePkg}/lib:${enginePkg}/venv/lib/python3.12/site-packages/nvidia/cu13/lib:/run/opengl-driver/lib"
      "HF_HOME=${modelDir}"
      "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
      # Triton JIT (exllamav3's gated-delta-net conv1d kernels) resolves
      # libcuda via TRITON_LIBCUDA_PATH; without it it shells out to
      # /sbin/ldconfig, which NixOS does not provide. CC/CXX + PATH let
      # triton's _build find a C compiler for the CUDA extension.
      "TRITON_LIBCUDA_PATH=/run/opengl-driver/lib"
      "CC=${pkgs.stdenv.cc}/bin/cc"
      "CXX=${pkgs.stdenv.cc}/bin/c++"
      "PATH=${enginePkg}/venv/bin:${pkgs.stdenv.cc}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"
    ]
    else [
      "CUDA_VISIBLE_DEVICES=0"
      "LD_LIBRARY_PATH=${enginePkg}/lib:${enginePkg}/venv/lib/python3.12/site-packages/nvidia/cu13/lib:/run/opengl-driver/lib"
      "HF_HOME=${modelDir}"
      "CUDA_HOME=${enginePkg}/cuda-home"
      "MAX_JOBS=6"
      "TRITON_LIBCUDA_PATH=/run/opengl-driver/lib"
      "CC=${pkgs.stdenv.cc}/bin/cc"
      "CXX=${pkgs.stdenv.cc}/bin/c++"
      "PATH=${enginePkg}/venv/bin:${pkgs.stdenv.cc}/bin:${pkgs.coreutils}/bin:${pkgs.findutils}/bin:/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin"
    ];

in
assert
# Guard: the recipe id and the ledger's unit name must agree, or the gate
# would start a unit that does not exist.
row.unit == "omarchy-${id}";
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

  # ─── Engine service (lifecycle daemon, idle wrapper) ───────────────────────

  systemd.services.${unit} = lifecycle {
    inherit unit childPort idleSeconds childCommand;
    wrapper = "sglang_wrapper.py";
    readyTimeoutSeconds = 3600;
    shutdownTimeoutSeconds = 60;
    killTimeoutSeconds = 30;

    description =
      "Omarchy ${recipe.name} ${engine} engine (lifecycle daemon, unloads after ${toString idleSeconds}s idle)";

    requires = [ "omarchy-${id}-prep.target" ];
    after = [ "omarchy-${id}-prep.target" ];

    environment = engineEnv;

    # Optional HF token (for hub-layout models that resolve at serve time).
    extraServiceConfig = {
      EnvironmentFile = [ "-/run/vllm/hf-token.env" ];
    };
  };


}
