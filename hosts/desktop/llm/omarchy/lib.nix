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

  enginePatch = recipe.enginePatch or null;

  # ─── Engine runtime package ────────────────────────────────────────────────
  # The tabbyapi venv, or the sglang venv — for recipes that declare
  # enginePatch, the sglang venv with that patch applied (a hardlink copy of
  # the sglang package; only the patched file diverges, so no data duplication).
  enginePkg =
    if engine == "tabbyapi"
    then pkgs.tabbyapi
    else
      if enginePatch != null
      then
        pkgs.stdenv.mkDerivation {
          pname = "sglang-${id}";
          version = "0.5.19";
          nativeBuildInputs = [ pkgs.patch ];
          dontUnpack = true;
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            # The omarchy-pinned verification group (the same hashes the
            # container launch checks): the engine patch must match before it
            # is applied.
            echo '${recipe.enginePatchSha256}  ${enginePatch}' | sha256sum -c -
            # Copy the sglang runtime and apply the patch to the copy. A
            # plain copy (not cp -al): in a sandboxed build $out lives on a
            # different filesystem from the store, so hardlinks are EXDEV.
            cp -a ${pkgs.sglang}/. $out
            target="$out/venv/lib/python3.12/site-packages/sglang/srt/models/gemma4_unified.py"
            echo '${recipe.engineFilePreSha256}  $target' | sha256sum -c -
            # The diff is repo-root relative (python/sglang/srt/models/...);
            # the venv's site-packages is the sglang package root.
            mkdir -p "$out/python/sglang/srt/models"
            ln -s "$target" "$out/python/sglang/srt/models/gemma4_unified.py"
            (cd "$out" && patch -p0 < ${enginePatch})
            # The patched file must match the omarchy pin.
            echo '${recipe.engineFilePostSha256}  $target' | sha256sum -c -
          '';
        }
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
      [
        "${enginePkg}/bin/python3"
        "${enginePkg}/app/main.py"
        "--config"
        configPath
      ]
    else
      let
        args = recipe.sglangArgs ++ [ "--port" (toString recipe.childPort) ];
      in
      if enginePatch != null
      then
        # The omarchy launch group, undockerified: verify the pinned patch and
        # patched-file hashes, then exec the engine (mirrors the container's
        # bash -lc launch).
        [
          (pkgs.writeShellScript "omarchy-launch-${id}" ''
            set -euo pipefail
            echo '${recipe.enginePatchSha256}  ${enginePatch}' | sha256sum -c -
            echo '${recipe.engineFilePostSha256}  ${enginePkg}/venv/lib/python3.12/site-packages/sglang/srt/models/gemma4_unified.py' | sha256sum -c -
            exec "${enginePkg}/bin/sglang" serve ${lib.concatStringsSep " " args}
          '')
        ]
      else
        [ "${enginePkg}/bin/sglang" "serve" ] ++ args;

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
      # tabbyAPI config overrides: TABBY_<SECTION>_<FIELD> env vars beat the
      # config.yml values (merge order file < env < args). The asset keeps
      # port 5000 (the container default); the service serves on the child
      # port, loopback-only (the idle wrapper relays the front socket).
      "TABBY_NETWORK_PORT=${toString recipe.childPort}"
      "TABBY_NETWORK_HOST=127.0.0.1"
      "LD_LIBRARY_PATH=${enginePkg}/lib:${enginePkg}/venv/lib/python3.12/site-packages/nvidia/cu13/lib:/run/opengl-driver/lib"
      "HF_HOME=${modelDir}"
      "PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True"
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
