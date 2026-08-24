{ config, pkgs, lib, ... }:

let
  modelsDir = "/var/lib/ninfer/models";
  logDir = "/var/log/ninfer";
  requestLog = "${logDir}/requests.jsonl";
  idleSeconds = 30;
  childPort = 8081;

  ninfer = pkgs.stdenv.mkDerivation {
    pname = "ninfer";
    version = "master";

    src = pkgs.fetchFromGitHub {
      owner = "Neroued";
      repo = "ninfer";
      rev = "feaf4dd0983fdaeb2ba4c06eec6da350e644fb3a";
      hash = "sha256-99ci7v85ldqrgTXzcCkHtis2YBimLKuodn2vwNuXwpI=";
    };

    nativeBuildInputs = with pkgs; [
      cmake
      ninja
      pkg-config
      cudaPackages_13_1.cudatoolkit
    ];

    buildInputs = with pkgs; [
      ffmpeg
      curl
      cudaPackages_13_1.cudatoolkit
    ];

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

  # Socket-activated idle wrapper: systemd owns the front-port socket; the
  # wrapper relays connections to the child and exits (code 0) once the
  # model is idle, so no process is resident between requests.
  ninferWrapper = pkgs.writeText "ninfer-wrapper.py" (builtins.readFile ./wrapper.py);

  # The model-serving child. Loopback-only: the wrapper (and thus the
  # socket unit) is the only thing that can reach it.
  childCommand = [
    "${ninfer}/bin/ninfer-serve"
    "${modelsDir}/${ninferModelFile}"
    "--host" "127.0.0.1"
    "--port" (toString childPort)
    "--kv-dtype" "int8"
    "--max-context" "240000"
    "--default-max-tokens" "200000"
    "--pending-timeout-ms" "900000"
    "--prefill-chunk" "1024"
    "--max-concurrency" "1"
    "--max-pending-requests" "6"
    "--temperature" "0.7"
    "--spec" "mtp"
    "--draft-tokens" "3"
    "--lm-head-draft"
    "--request-log-jsonl" requestLog
  ];

  ninferModelRepo = "neroued/Qwen3.8-27B-nvfp4-NInfer";
  ninferModelFile = "qwen3_8_27b_nvfp4.ninfer";

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

in {
  environment.systemPackages = [ ninfer ];

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0755 root root -"
    "d ${logDir} 0755 root root -"
  ];

  system.activationScripts.ninferModel.text = downloadNinferModel "ninfer-qwen38-nvfp4" ninferModelRepo modelsDir ninferModelFile;

  # Socket activation: the kernel-held socket owns the front port; the
  # service process only exists between a connection and the idle window.
  #
  # Deliberately no After=network.target: this socket is pulled in by
  # sockets.target (ordered *before* basic.target), while network.target on
  # this host sits after wpa_supplicant.service, which sits after
  # basic.target. Ordering the socket after network.target creates a cycle
  # and systemd breaks it by deleting the socket's start job. Binding a
  # loopback socket needs no network; the child only starts when a client
  # connects. (Same reasoning as whisper-service's socket unit.)
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

      ExecStart = lib.concatStringsSep " " ([
        "${pkgs.python3}/bin/python3"
        "${ninferWrapper}"
        "--child-port" (toString childPort)
        "--idle-seconds" (toString idleSeconds)
        "--ready-timeout" "1800"
        "--shutdown-timeout" "30"
        "--kill-timeout" "10"
        "--request-log" requestLog
        "--"
      ]
      ++ childCommand);

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
}
