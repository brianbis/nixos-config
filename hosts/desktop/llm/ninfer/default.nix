{ config, pkgs, lib, ... }:

let
  modelsDir = "/var/lib/ninfer/models";
  logDir = "/var/log/ninfer";
  requestLog = "${logDir}/requests.jsonl";
  idleSeconds = 120;
  childPort = 8081;
  childPortA3B = 8083;

  ninfer = pkgs.stdenv.mkDerivation {
    pname = "ninfer";
    version = "master";

    # fetchFromGitHub in this nixpkgs pin downloads
    # https://github.com/OWNER/REPO/archive/REV.tar.gz and hashes the
    # *unpacked* tree (fetchzip, recursiveHash = true) — NOT the tarball
    # sha256. Assemble the hash with (substitute OWNER/REPO/REV):
    #   d=$(mktemp -d) && curl -sL "https://github.com/OWNER/REPO/archive/REV.tar.gz" | tar -xz -C "$d" --strip-components=1 && nix hash path "$d" && rm -rf "$d"
    src = pkgs.fetchFromGitHub {
      owner = "Neroued";
      repo = "ninfer";
      rev = "ad0f3d384b5cbcec4a48a3951c287b4e9831443e";
      hash = "sha256-tJdT99C8TarRwHQW/aoH5wjNGUEk3X7d1230EzogLoc=";
    };

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

    # The pinned rev has no server-side reasoning-effort default; this patch
    # adds --reasoning-effort so the serve binary can default Qwen3.8 to brief
    # thinking (a per-request effort still wins over the flag).
    postPatch = ''
      patch -p1 -N < ${./reasoning-effort.patch}
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
      homepage = "https://github.com/Neroued/ninfer";
      license = licenses.asl20;
      platforms = [ "x86_64-linux" ];
    };
  };

  # Socket-activated idle wrapper (shared with the vLLM containers; the
  # relay/health/idle machinery lives in ../idle-wrapper once). systemd owns
  # the front-port socket; the wrapper relays connections to the child and
  # exits (code 0) once the model is idle, so no process is resident between
  # requests.
  idleWrapper = pkgs.callPackage ../idle-wrapper { };

  # The wrapper's ExecStart for a serve pair: the shared idle wrapper (child
  # backend) plus the per-model child command. Both serve pairs share this
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
    "int8"
    "--max-context"
    "240000"
    "--kv-capacity"
    "240000"
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
    "32768"
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
  # bd265a3 or later (the pinned ad0f3d3 satisfies this).
  ninferModelRepoA3B = "neroued/Qwen3.6-35B-A3B-NInfer";
  ninferModelFileA3B = "qwen3_6_35b_a3b.ninfer";

  # Second serving child: Qwen3.6-35B-A3B on its own loopback port.
  # No --reasoning-effort: the A3B chat template does not support a
  # reasoning-effort control, and the engine rejects the flag at startup
  # ("default reasoning effort is not supported by the loaded chat template").
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
  environment.systemPackages = [ ninfer ];

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0755 root root -"
    "d ${logDir} 0755 root root -"
  ];

  system.activationScripts.ninferModel.text = downloadNinferModel "ninfer-qwen38-nvfp4" ninferModelRepo modelsDir ninferModelFile;

  system.activationScripts.ninferModelA3B.text = downloadNinferModel "ninfer-qwen36-a3b" ninferModelRepoA3B modelsDir ninferModelFileA3B;

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
}
