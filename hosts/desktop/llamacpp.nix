{ config, pkgs, lib, ... }:

let
  # GGUF models directory. The single llama.cpp slot below serves the vision
  # language model Muse-Glimmer-30B. Files are downloaded idempotently at switch
  # time by the activation script below (see system.activationScripts.museModels).
  modelsDir = "/var/lib/llama/models";

  # Model weights fetched from the GGUF repo at activation (only when missing).
  # Kept behind `--include` so we never pull the extra 17gb build / README.
  repo = "meta-models/Muse-Glimmer-30B-GGUF";
  gguf = files:
    builtins.concatStringsSep " " (map (f: "\"${f}\"") files);
  modelFiles = [
    "muse-glimmer-30B-kquant-dynamic.gguf"
    "mmproj-kquant.gguf"
    "dflash-kquant.gguf"
  ];

  # Qwen3.8-27B Q8_0 GGUF weights
  qwenRepo = "unsloth/Qwen3.8-27B-GGUF";
  qwenModelFiles = [
    "Qwen3.8-27B-Q8_0.gguf"
    "imatrix_unsloth.gguf"
  ];

  dwellSeconds = 30;

in {
  environment.systemPackages = with pkgs; [ llama-cpp ];

  # Download the GGUF weights into /var/lib/llama/models at every switch, only
  # if a file is missing. Uses the existing agenix hf-token secret for auth.
  # Runs as root during activation; `hf` is invoked from the store so this works
  # even if the user profile (and thus PATH) isn't updated yet.
  system.activationScripts.museModels.text = ''
    mkdir -p ${modelsDir}
    for f in ${gguf modelFiles}; do
      if [ ! -f "${modelsDir}/$f" ]; then
        echo "llamacpp: downloading $f (missing)"
      fi
    done
    missing=0
    for f in ${gguf modelFiles}; do
      [ -f "${modelsDir}/$f" ] || missing=1
    done
    if [ "$missing" = "1" ]; then
      export HF_TOKEN="$(cat ${config.age.secrets.hf-token.path} | tr -d '\n')"
      export HF_HUB_DOWNLOAD_TIMEOUT=600
      # `hf download` (not the deprecated huggingface-cli, which errors out).
      ${pkgs.python3Packages.huggingface-hub}/bin/hf download ${repo} \
        --token "$HF_TOKEN" \
        --local-dir ${modelsDir} \
        --include "muse-glimmer-30B-kquant-dynamic.gguf" \
        --include "mmproj-kquant.gguf" \
        --include "dflash-kquant.gguf"
      status=$?
      if [ "$status" != "0" ]; then
        echo "llamacpp: hf download failed with status $status" >&2
        exit "$status"
      fi
      chmod 0644 ${modelsDir}/*.gguf
    else
      echo "llamacpp: all model files present, skipping download"
    fi
  '';

  system.activationScripts.qwenModels.text = ''
    mkdir -p ${modelsDir}
    for f in ${gguf qwenModelFiles}; do
      if [ ! -f "${modelsDir}/$f" ]; then
        echo "llamacpp-qwen: downloading $f (missing)"
      fi
    done
    missing=0
    for f in ${gguf qwenModelFiles}; do
      [ -f "${modelsDir}/$f" ] || missing=1
    done
    if [ "$missing" = "1" ]; then
      export HF_TOKEN="$(cat ${config.age.secrets.hf-token.path} | tr -d '\n')"
      export HF_HUB_DOWNLOAD_TIMEOUT=600
      ${pkgs.python3Packages.huggingface-hub}/bin/hf download ${qwenRepo} \
        --token "$HF_TOKEN" \
        --local-dir ${modelsDir} \
        --include "Qwen3.8-27B-Q8_0.gguf" \
        --include "imatrix_unsloth.gguf"
      status=$?
      if [ "$status" != "0" ]; then
        echo "llamacpp-qwen: hf download failed with status $status" >&2
        exit "$status"
      fi
      chmod 0644 ${modelsDir}/*.gguf
    else
      echo "llamacpp-qwen: all model files present, skipping download"
    fi
  '';

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0755 root root -"
  ];

  # Single llama.cpp server for Muse-Glimmer-30B (kquant dynamic GGUF). The
  # parallel vLLM backend (hosts/desktop/vllm.nix) still owns the cached
  # Gemma-4 AWQ/NVFP4 weights; this slot adds the GGUF path. Serves the
  # OpenAI-compatible API on :8000 that the headroom proxies upstream to.
  systemd.services.llamacpp-muse = {
    description = "llama.cpp Muse-Glimmer-30B (kquant-dynamic)";
    # Auto-starts at boot, stays online. Model sleeps after idle to free VRAM.
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.llama-cpp}/bin/llama-server"
        "--model" "${modelsDir}/muse-glimmer-30B-kquant-dynamic.gguf"
        "--mmproj" "${modelsDir}/mmproj-kquant.gguf"
        # DFlash drafter for speculative decoding (~3x on RTX 5090). Flags match
        # the model card exactly: -md <drafter> -ngld 99 (llama-server).
        "-md" "${modelsDir}/dflash-kquant.gguf"
        "-ngld" "99"
        "--alias" "muse-glimmer-30B"
        "--host" "127.0.0.1"
        "--port" "8000"
        # Muse Glimmer's chat template is baked into the GGUF (same blob as the
        # base repo). --jinja is required: without it the template is not
        # applied and vision/tool/reasoning channels behave incorrectly.
        "--jinja"
        # Repo advertises a 131072-token context; the 18.3GiB weights + ~1.6GiB
        # drafter leave room for a conservative KV cache on the 32GB card. With
        # --parallel 1 the per-slot context equals -c; bump toward 131072 if
        # you never see OOM and want the model's full trained window.
        "--ctx-size" "131072"
        "--n-predict" "8192"
        "--n-gpu-layers" "99"
        "--parallel" "1"
        # b10353: --flash-attn takes an explicit boolean value.
        "--flash-attn" "true"
        "--mlock"
        "--sleep-idle-seconds" "${toString dwellSeconds}"
        # Sampling defaults recommended by the model card.
        "--temp" "1.0"
        "--top-p" "0.95"
        "--top-k" "64"
      ];
      Restart = "on-failure";
      RestartSec = "3";
    };
  };
}
