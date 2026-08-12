{ pkgs, lib, ... }:

let
  # GGUF models directory. The single llama.cpp slot below serves the vision
  # language model Muse-Glimmer-30B. No build-time download: fetch it once,
  # e.g.:
  #   huggingface-cli download meta-models/Muse-Glimmer-30B-GGUF \
  #     muse-glimmer-30B-kquant-dynamic.gguf mmproj-kquant.gguf dflash-kquant.gguf \
  #     --local-dir /var/lib/llama/models
  #
  # REQUIRED llama.cpp build: Muse Glimmer support needs b10353+ (merged
  # 2026-08-10). The pinned nixpkgs snapshot here is 2026-07-26, which predates
  # that merge, so the stock pkgs.llama-cpp may reject these files with
  # "architecture muse-glimmer not registered". If so, override llama-cpp with a
  # newer overlay/package before nixos-rebuild.
  modelsDir = "/var/lib/llama/models";

in {
  environment.systemPackages = with pkgs; [ llama-cpp ];

  systemd.tmpfiles.rules = [
    "d ${modelsDir} 0755 root root -"
  ];

  # Single llama.cpp server for Muse-Glimmer-30B (kquant dynamic GGUF). The
  # parallel vLLM backend (hosts/desktop/vllm.nix) still owns the cached
  # Gemma-4 AWQ/NVFP4 weights; this slot adds the GGUF path. Serves the
  # OpenAI-compatible API on :8000 that the headroom proxies upstream to.
  systemd.services.llamacpp-muse = {
    description = "llama.cpp Muse-Glimmer-30B (kquant-dynamic)";
    enable = false;
    wantedBy = [];

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
        "--ctx-size" "32768"
        "--n-predict" "8192"
        "--n-gpu-layers" "99"
        "--parallel" "1"
        "--flash-attn"
        "--mlock"
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
