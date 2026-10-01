# Omarchy model recipes for the RTX 5090 (32 GB) — single source of truth.
#
# Each recipe declares: the model weights (HF repo + pinned revision), the
# inference engine (tabbyapi/exllamav3 or sglang), the launch arguments, and
# the serving parameters. The lib.nix factory transforms each recipe into:
#   - the oneshot download service (hf download, revision-gated)
#   - a lifecycle engine service (idle wrapper, on-demand VRAM)
#   - the prep target (wants the download)
#
# "Updatable": change the `revision` here (or `nix flake update exllamav3`
# for the engine) and the next service activation re-downloads / rebuilds.

{
  # ─── TabbyAPI / EXL3 (Qwen3.8-27B) ─────────────────────────────────────────

  qwen3827b-exl3-sc5bpw = {
    name = "Qwen3.8-27B";
    servedName = "Qwen3.8-27B-EXL3-SC5bpw-H6-V6";
    engine = "tabbyapi";
    family = "qwen";
    format = "EXL3 · SC 5.00bpw H6 V6";
    capabilities = {
      chat = true;
      reasoning = true;
      tools = true;
      vision = true;
    };
    sizeGb = 18.24;
    weights = {
      repository = "turboderp/Qwen3.8-27B-exl3";
      revision = "f33f26d929e2b20ef21361145d582f5239e3831f";
      layout = "dir";
      # The repo lays config.json / model-*.safetensors at its ROOT (no per-model
      # subdir), so they land directly in the download dir.
      # Sentinel files that must exist for the download to be considered complete.
      sentinels = [
        "model.safetensors.index.json"
      ];
    };
    serving = {
      ctxTokens = 262144;
      kvTokens = 263168;
    };
    # The ledger row in ../../../catalog/default.nix owns this model's port
    # and systemd unit name, so the gate's table and these units cannot drift.
    catalogKey = "qwen3827b_exl3_sc5bpw";
    # The tabbyapi config asset (mounted into the engine's working dir).
    configAsset = ./assets/qwen3827b-exl3-sc5bpw-config.yml;
    # Memory settings for the idle wrapper.
    shm = "8g";
  };

  qwen3827b-exl3-4bpw = {
    name = "Qwen3.8-27B";
    servedName = "Qwen3.8-27B-EXL3-4bpw";
    engine = "tabbyapi";
    family = "qwen";
    format = "EXL3 · 4 bpw";
    capabilities = {
      chat = true;
      reasoning = true;
      tools = true;
      vision = false;
    };
    sizeGb = 15.73;
    weights = {
      repository = "turboderp/Qwen3.8-27B-exl3";
      revision = "113cf7ab958054860e43fb7f3063b1af19171095";
      layout = "dir";
      # The repo lays config.json / model-*.safetensors at its ROOT (no per-model
      # subdir), so they land directly in the download dir.
      sentinels = [
        "model.safetensors.index.json"
      ];
    };
    serving = {
      ctxTokens = 262144;
      kvTokens = 262144;
    };
    # The ledger row in ../../../catalog/default.nix owns this model's port
    # and systemd unit name, so the gate's table and these units cannot drift.
    catalogKey = "qwen3827b_exl3_4bpw";
    configAsset = ./assets/qwen3827b-exl3-4bpw-config.yml;
    shm = "8g";
  };

  # ─── SGLang models ─────────────────────────────────────────────────────────

  gemma4-12b-nvfp4 = {
    name = "Gemma-4-12B-it";
    servedName = "unsloth/gemma-4-12b-it-NVFP4";
    engine = "sglang";
    family = "gemma";
    format = "ModelOpt · NVFP4";
    capabilities = {
      chat = true;
      reasoning = false;
      tools = false;
      vision = false;
    };
    sizeGb = 8.7;
    weights = {
      repository = "unsloth/gemma-4-12b-it-NVFP4";
      revision = "b1f649734b34aa5575b03d186abd1b9be3d0d5c4";
      layout = "hub";
      dir = "";
      # HF-hub layout: the model is downloaded to the HF cache and served via
      # --model-path <repo-id> (sglang resolves it from HF_HOME).
      sentinels = [
        "models--unsloth--gemma-4-12b-it-NVFP4/refs/b1f649734b34aa5575b03d186abd1b9be3d0d5c4"
      ];
    };
    serving = {
      ctxTokens = 131072;
      kvTokens = 133368;
    };
    # The ledger row in ../../../catalog/default.nix owns this model's port
    # and systemd unit name, so the gate's table and these units cannot drift.
    catalogKey = "gemma4_12b_nvfp4";
    shm = "16g";
    # SGLang launch arguments (beyond the shared engine flags).
    sglangArgs = [
      "--model-path" "unsloth/gemma-4-12b-it-NVFP4"
      "--revision" "b1f649734b34aa5575b03d186abd1b9be3d0d5c4"
      "--tp" "1"
      "--host" "127.0.0.1"
      "--context-length" "131072"
      "--mem-fraction-static" "0.8827875"
      "--attention-backend" "triton"
      "--enable-cache-report"
      "--trust-remote-code"
      "--reasoning-parser" "gemma4"
      "--tool-call-parser" "gemma4"
    ];
    # The gemma4 engine patch (NVFP4 republished config compat), applied to a
    # hardlink copy of the sglang venv at build time. The omarchy-pinned
    # hashes (the container launch's verification group) gate both the patch
    # and the result.
    enginePatch = ./assets/gemma4-engine-patch.diff;
    enginePatchSha256 = "dede8848dbcbfcfc6507da963a65d120add93101b6ff5fb54a03f19e86233d11";
    engineFilePreSha256 = "d5498b253f35e83ab0aaf219a2c2bf2f42c6bbd3f95ffce02760e78b2e38a4e9";
    engineFilePostSha256 = "b0614b99a0d7fe654ed102fb5db04c578e3be6042896f73f9418965e6672c737";
  };

  lfm25-26b-bf16 = {
    name = "LFM2.5-2.6B";
    servedName = "LiquidAI/LFM2.5-2.6B";
    engine = "sglang";
    family = "lfm";
    format = "safetensors · BF16";
    capabilities = {
      chat = true;
      reasoning = false;
      tools = false;
      vision = false;
    };
    sizeGb = 5.024;
    weights = {
      repository = "LiquidAI/LFM2.5-2.6B";
      revision = "a334ee78cd38458bb71eda24109ac42dcec1309d";
      layout = "hub";
      dir = "";
      sentinels = [
        "models--LiquidAI--LFM2.5-2.6B/refs/a334ee78cd38458bb71eda24109ac42dcec1309d"
      ];
    };
    serving = {
      ctxTokens = 131072;
      kvTokens = 731831;
    };
    # The ledger row in ../../../catalog/default.nix owns this model's port
    # and systemd unit name, so the gate's table and these units cannot drift.
    catalogKey = "lfm25_26b_bf16";
    shm = "16g";
    sglangArgs = [
      "--model-path" "LiquidAI/LFM2.5-2.6B"
      "--revision" "a334ee78cd38458bb71eda24109ac42dcec1309d"
      "--host" "127.0.0.1"
      "--tp" "1"
      "--context-length" "131072"
      "--mem-fraction-static" "0.874"
      "--attention-backend" "flashinfer"
      "--max-running-requests" "4"
      "--cuda-graph-max-bs-decode" "4"
      "--enable-cache-report"
      "--trust-remote-code"
      "--reasoning-parser" "qwen3-thinking"
      "--tool-call-parser" "lfm2"
    ];
  };

  ornith15-35b-nvfp4 = {
    name = "Ornith-1.5-35B-A3B";
    servedName = "ornith-ai/Ornith-1.5-35B-A3B-NVFP4";
    engine = "sglang";
    family = "ornith";
    format = "ModelOpt · NVFP4";
    capabilities = {
      chat = true;
      reasoning = false;
      tools = false;
      vision = false;
    };
    sizeGb = 21.8;
    weights = {
      repository = "ornith-ai/Ornith-1.5-35B-A3B-NVFP4";
      revision = "0f0b1b59b879ccde1353e6ebd0fb10c204d4c544";
      layout = "hub";
      dir = "";
      sentinels = [
        "models--ornith-ai--Ornith-1.5-35B-A3B-NVFP4/refs/0f0b1b59b879ccde1353e6ebd0fb10c204d4c544"
      ];
    };
    serving = {
      ctxTokens = 131072;
      kvTokens = 381008;
    };
    # The ledger row in ../../../catalog/default.nix owns this model's port
    # and systemd unit name, so the gate's table and these units cannot drift.
    catalogKey = "ornith15_35b_nvfp4";
    shm = "16g";
    sglangArgs = [
      "--model-path" "ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
      "--revision" "0f0b1b59b879ccde1353e6ebd0fb10c204d4c544"
      "--tp" "1"
      "--host" "127.0.0.1"
      "--context-length" "131072"
      "--mem-fraction-static" "0.90"
      "--max-running-requests" "4"
      "--cuda-graph-max-bs-decode" "4"
      "--enable-cache-report"
      "--trust-remote-code"
      "--reasoning-parser" "qwen3"
      "--tool-call-parser" "qwen3_coder"
      "--kv-cache-dtype" "fp8_e4m3"
      "--attention-backend" "flashinfer"
      "--moe-runner-backend" "flashinfer_cutlass"
    ];
  };
}
