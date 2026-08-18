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
      rev = "master";
      hash = "sha256-fGyHdZOkKRTsarkHkUxYigZT2v1J+Fq/t3V3eOpAdL8=";
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

  ninferProxy = pkgs.writeText "ninfer-proxy.py" (builtins.readFile ./proxy.py);

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

  systemd.services.ninfer-serve = {
    description = "NInfer proxy for Qwen3.8-27B NVFP4 (on-demand load, unloads after ${toString idleSeconds}s idle)";
    wantedBy = [ "multi-user.target" ];
    requires = [ "network-online.target" ];
    after = [ "network-online.target" ];

    serviceConfig = {
      Type = "simple";

      ExecStart = lib.concatStringsSep " " [
        "${pkgs.python3}/bin/python3"
        "${ninferProxy}"
        "--listen" "127.0.0.1:8080"
        "--child-port" (toString childPort)
        "--idle-seconds" (toString idleSeconds)
        "--request-log" requestLog
        "--"
        "${ninfer}/bin/ninfer-serve"
        "${modelsDir}/${ninferModelFile}"
        "--host" "127.0.0.1"
        "--port" (toString childPort)
        "--max-context" "80000"
        "--kv-capacity" "auto"
        "--max-concurrency" "1"
        "--spec" "mtp"
        "--draft-tokens" "3"
        "--lm-head-draft"
        "--no-thinking"
        "--temperature" "0.7"
        "--top-p" "0.8"
        "--top-k" "20"
        "--presence-penalty" "1.5"
        "--request-log-jsonl" requestLog
      ];

      Restart = "always";
      RestartSec = "3";

      Environment = [
        "CUDA_VISIBLE_DEVICES=0"
        "LD_LIBRARY_PATH=/run/opengl-driver/lib"
      ];
    };
  };
}
