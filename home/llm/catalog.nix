# Shared rendering for the jailed LLM tooling: single source of truth for the model/LSP catalogs, provider mapping, and config builders.
# Imported by the home-manager modules (user + system homes) and the doc build, so both stay identical.
{ lib, pkgs, jail-nix, ... }:

let
  jail = jail-nix.lib.init pkgs;
  users = import ../users.nix;
  # Context-compression proxy: local llama.cpp traffic from every jailed agent routes through Headroom, which forwards upstream to llama-server on :8000.
  headroomPort = 8787;
  headroomProxyUrl = "http://127.0.0.1:${toString headroomPort}";
  headroomUpstreamUrl = "http://127.0.0.1:8000";

  # DeepSeek-facing headroom proxy (port 8788): routes cloud traffic through the same context-compression layer.
  headroomCloudPort = 8788;
  headroomCloudProxyUrl = "http://127.0.0.1:${toString headroomCloudPort}";
  headroomCloudUpstreamUrl = "https://api.deepseek.com/v1";

  # Claude Code-facing headroom proxy (port 8789): Claude Code speaks the Anthropic Messages API, so this forwards to the local llama-server (the OpenAI proxy can't be reused).
  headroomClaudePort = 8789;
  headroomClaudeProxyUrl = "http://127.0.0.1:${toString headroomClaudePort}";

  # DSH-default-model-facing headroom proxy (port 8791): the default agent model (ninfer qwen3.8-27b, upstream :8080) routes through the compression layer.
  # --lossless (marker-free): DSH has no headroom_retrieve MCP tool, so default CCR mode would inject markers it cannot redeem.
  headroomNinferPort = 8791;
  headroomNinferProxyUrl = "http://127.0.0.1:${toString headroomNinferPort}";
  headroomNinferUpstreamUrl = "http://127.0.0.1:8080";

  # NVIDIA NIM (Build) cloud proxy (port 8792): routes cloud NVIDIA traffic (Kimi K3) through the compression layer. Like the DeepSeek cloud proxy, the real API key is injected host-side by the headroom-proxy-nvidia user-service (via --openai-extra-headers), keeping it out of the agent's environ.
  headroomNvidiaPort = 8792;
  headroomNvidiaProxyUrl = "http://127.0.0.1:${toString headroomNvidiaPort}";
  headroomNvidiaUpstreamUrl = "https://integrate.api.nvidia.com/v1";

  # Single source of truth for every LLM exposed to the jailed agents; each tool (crush/opencode/aider) derives its provider + model lists from here.
  models = {
    # Local backends. vLLM serves the OpenAI API on its own host ports (:8021 NVFP4 / :8022 AWQ); llama.cpp on :8000.
    # Only one vLLM engine runs at a time (VRAM), so the vLLM ports are mutually exclusive but none collide with llama.cpp's :8000.
    gemma4awq = {
      providerName = "vllm_awq";
      id = "gemma-4-awq";
      name = "Gemma 4 26B MoE AWQ";
      url = "http://127.0.0.1:8022";
      context = 262144;
      # Single-generation cap for a 32GB card (a far-larger request won't fit one run alongside the 17GB AWQ weights; agents loop via tool calls).
      maxTok = 65536;
      reason = true;
      attachments = true;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    gemma4nvfp4 = {
      providerName = "vllm_nvfp4";
      id = "gemma-4-nvfp4";
      name = "Gemma 4 31B NVFP4";
      url = "http://127.0.0.1:8021";
      # Must match --max-model-len 32768 in hosts/desktop/llm/vllm/gemma4-nvfp4-turbo.nix.
      context = 80000;
      maxTok = 30000;
      reason = true;
      attachments = false;
      costIn = 0.14;
      costOut = 0.28;
      costInCached = 0.014;
      costOutCached = 0.28;
    };
    # Qwen3.8-27B NVFP4 + DFlash2 K7 (RTX 5090 / SM120); served by the on-demand vllm-qwen38-dflash2 NATIVE engine (socket-activated idle wrapper on :18089).
    qwen38_dflash2 = {
      providerName = "vllm_dflash2";
      id = "qwen3.8-27b-nvfp4-dflash2";
      name = "Qwen3.8-27B NVFP4 DFlash2";
      # Direct to the socket-activated front port (like the ninfer models), not via headroom; the wrapper starts the engine on the first request.
      url = "http://127.0.0.1:18089";
      # Must match --max-model-len 262144 in hosts/desktop/llm/vllm/qwen38-dflash2.nix.
      context = 262144;
      # Per-request output cap (tunable); the 262K-context model supports long generations, this is a conservative default.
      maxTok = 32768;
      reason = true;
      # Text-only: the optional CPU vision sidecar is not part of this integration.
      attachments = false;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    # Same Qwen3.8-27B NVFP4 + DFlash2 K7 checkpoint, but routed DIRECTLY to the engine's child port (:18090) instead of the socket-activated idle wrapper (:18089).
    # Use this while the engine is resident (after any request via :18089) to bypass the router/wrapper; the two entries are mutually exclusive at the port level.
    qwen38_dflash2_direct = {
      providerName = "vllm_dflash2_direct";
      # Must equal the engine's --served-model-name (vLLM rejects any other model id); the "(direct)" distinction lives in the display name only.
      id = "qwen3.8-27b-nvfp4-dflash2";
      name = "Qwen3.8-27B NVFP4 DFlash2 (direct)";
      url = "http://127.0.0.1:18090";
      # Must match --max-model-len 262144 in hosts/desktop/llm/vllm/qwen38-dflash2.nix.
      context = 262144;
      maxTok = 32768;
      reason = true;
      attachments = false;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    muse = {
      providerName = "llamacpp";
      id = "muse-glimmer-30B";
      name = "Muse-Glimmer-30B (kquant-dynamic GGUF)";
      url = headroomProxyUrl;
      # Repo advertises 131072-token context; the 18.3GiB weights on a 32GB card cap effective context to ~32k with a single generation.
      context = 131072;
      maxTok = 8192;
      reason = true;
      attachments = true;
    };
    # Qwen3.8-27B Q8_0 (llama.cpp, :8000 via headroom). Two modes — thinking and instruct — each a single catalog entry whose effort is a per-request parameter (reasoning_effort), exposed in the web UI as a dropdown like the ninfer models.
    # The router preset's chat-template-kwargs sets the default effort for requests that omit one; a selected level always wins.
    qwen38_thinking = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-thinking";
      name = "Qwen3.8-27B Q8_0 Thinking";
      url = headroomProxyUrl;
      # Repo advertises 262144-token context (matches the router's --ctx-size); the KV cache lives in system RAM (--no-kv-offload) so the full context fits alongside the ~27 GiB weights.
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
      # Thinking levels the Qwen3.8-27B chat template supports (low/medium/xhigh); declaring them makes dsh materialize the model as a reasoning model (web UI effort selector).
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
    };

    qwen38_instruct = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-q8_0-instruct";
      name = "Qwen3.8-27B Q8_0 Instruct";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
    };

    qwen38heretic_q6k = {
      providerName = "llamacpp";
      id = "qwen3-8-27b-heretic-q6_k";
      name = "Qwen3.8-27B Heretic RVN Abliterated Uncensored Q6_K";
      url = headroomProxyUrl;
      # RVN-Q6_K.gguf is ~20.6 GiB; like the base Qwen it keeps KV in system RAM (no-kv-offload) so the 131072 context fits on the 32 GB card.
      context = 131072;
      maxTok = 80000;
      reason = true;
      attachments = true;
    };
    # MiMo-V2.6-Distill-Qwen-9B (bartowski bf16 GGUF, llama.cpp :8000 via headroom); a 9B agentic distill of Qwen3.5-9B. Thinking is a boolean (enable_thinking), not a reasoning_effort level, so it's a plain reasoning model (no selector); the router preset enables thinking by default.
    # The 17.9 GiB bf16 weights leave ample VRAM headroom (KV stays on the card); the bf16 mmproj makes it vision-capable.
    mimo = {
      providerName = "llamacpp";
      id = "mimo-v2.6-9b-bf16";
      name = "MiMo-V2.6-Distill-Qwen-9B (bf16 GGUF)";
      url = headroomProxyUrl;
      context = 262144;
      maxTok = 240000;
      reason = true;
      attachments = true;
    };
    # LensVLM-9B: Apple's 9B vision-language model (Qwen3.5-9B based) for selective context expansion over compressed document images, served by the vLLM docker container (hosts/desktop/llm/vllm/lensvlm.nix) on :8023 (direct URL) from the bare repo — full bf16 weights, no quantization.
    # The 18.8 GiB weights fit the 32 GB card with an fp8 KV cache; the 131072 context must match --max-model-len. Thinking is a boolean (enable_thinking), so it's a plain reasoning model (no selector).
    lensvlm = {
      providerName = "vllm_lensvlm";
      id = "lensvlm-9b";
      name = "LensVLM-9B (bf16 vLLM)";
      url = "http://127.0.0.1:8023";
      context = 131072;
      maxTok = 32768;
      reason = true;
      attachments = true;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    # Ternary-Bonsai-2-27B (PQ2_0): the PrismML-Eng ternary 27B, served by the Bonsai fork router on :8010 (NOT via headroom, which upstreams the stock :8000 router). Direct URL, like the ninfer/vllm engines.
    # Two modes (thinking/instruct), each a single entry with a per-request reasoning_effort. The template supports xhigh/medium (low behaves like xhigh, so no low entry); the 7.2 GB weights leave ample VRAM so the 262K context fits.
    bonsai2_27b_pq2_thinking = {
      providerName = "llamacpp_bonsai";
      id = "bonsai2-27b-pq2_0-thinking";
      name = "Ternary-Bonsai-2-27B PQ2_0 Thinking";
      url = "http://127.0.0.1:8010";
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
      reasoningEfforts = {
        medium = "medium";
        xhigh = "xhigh";
      };
    };
    bonsai2_27b_pq2_instruct = {
      providerName = "llamacpp_bonsai";
      id = "bonsai2-27b-pq2_0-instruct";
      name = "Ternary-Bonsai-2-27B PQ2_0 Instruct";
      url = "http://127.0.0.1:8010";
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
      reasoningEfforts = {
        medium = "medium";
        xhigh = "xhigh";
      };
    };
    qwen38_nvfp4_ninfer = {
      providerName = "ninfer";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer";
      url = headroomNinferProxyUrl;
      context = 240000;
      maxTok = 200000;
      reason = false;
      attachments = false;
      # Thinking levels the Qwen3.8-27B chat template supports (low/medium/xhigh); declaring them makes dsh materialize the model as a reasoning model, and a selected level is sent as reasoning_effort.
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
    };
    # Same Qwen3.8-27B NVFP4 artifact as qwen38_nvfp4_ninfer, but served by the gzenz fork engine (ninfer-serve-gzenz, socket-activated front :8084). The fork's distinguishing feature is COMPRESSED KV (--kv-dtype nvfp4), letting it run a HIGHER context (~420k effective vs the stock 240k).
    # The fork's serve binary has no --reasoning-effort flag (its Qwen3.8 template defaults to xhigh thinking); a per-request reasoning_effort always wins.
    qwen38_nvfp4_ninfer_gzenz = {
      providerName = "ninfer_gzenz";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer (gzenz fork, ~420k ctx)";
      url = "http://127.0.0.1:8084";
      # Effective per-request ceiling: the engine's --kv-capacity auto pool resolves to ~420k tokens at the current ~9.75 GiB free-after-weights (still ~1.75x the stock 240000).
      context = 420000;
      maxTok = 200000;
      reason = false;
      attachments = false;
      # Thinking levels the Qwen3.8-27B chat template supports (low/medium/xhigh).
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
    };
    # Same Qwen3.8-27B NVFP4 artifact as qwen38_nvfp4_ninfer, but served by the Cinference fork engine (ninfer-serve-cinference, socket-activated front :8091). The fork's distinguishing feature is MTP-10 (--draft-tokens 10 vs the stock/gzenz 3).
    # Served on the Swift (abliterated) NVFP4 checkpoint (reused weights, no new download); the fork has the reasoning-effort patch applied, so the same low/medium/xhigh levels apply.
    qwen38_nvfp4_ninfer_cinference = {
      providerName = "ninfer_cinference";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer (Cinference fork, MTP-10)";
      url = "http://127.0.0.1:8091";
      context = 262144;
      maxTok = 262144;
      reason = false;
      attachments = false;
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
    };
    # Swift (abliterated) Qwen3.8-27B NVFP4 — community "abliterated" (safety training removed) checkpoint, served by the stock engine (ninfer-serve-swift, socket-activated front :8088); same template as qwen38_nvfp4_ninfer.
    qwen38_swift_abliterated_nvfp4_ninfer = {
      providerName = "ninfer_swift";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer (Swift abliterated)";
      url = "http://127.0.0.1:8088";
      context = 240000;
      maxTok = 200000;
      reason = false;
      attachments = false;
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
    };
    qwen36_a3b_ninfer = {
      providerName = "ninfer_a3b";
      id = "qwen3.6-35b-a3b";
      name = "Qwen3.6-35B-A3B NInfer";
      url = "http://127.0.0.1:8082";
      context = 262144;
      maxTok = 200000;
      reason = false;
      attachments = true;
      # No reasoningEfforts: the A3B chat template does not support a reasoning-effort control (the engine rejects it), so the model is a plain non-reasoning model.
    };
    # Same Qwen3.8-27B NVFP4 checkpoint as the vLLM DFlash2 / NInfer entries, but served by the native SGLang engine (sglang-serve, socket-activated front :8086, no docker); a third engine on the same weights for comparison.
    qwen38_nvfp4_sglang = {
      providerName = "sglang";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 SGLang";
      url = "http://127.0.0.1:8086";
      # Must match --context-length 32768 in hosts/desktop/llm/sglang/default.nix.
      context = 32768;
      maxTok = 32768;
      reason = false;
      attachments = false;
    };
    # K2-Horizon-MoVA-36B-A4B NVFP4: the IFM 36B MoE / 4B-active Mixture-of-Values model, served by the pinned vLLM nightly docker container (hosts/desktop/llm/vllm/k2horizon-nvfp4.nix) — k2_horizon is not in a vLLM release yet, so the container pins the exact nightly the checkpoint was validated on.
    # On its own host port (:8020, direct URL) so it no longer shares :8000 with the llama.cpp router or the Gemma containers; only one vLLM engine runs at a time (VRAM).
    k2horizon_nvfp4 = {
      providerName = "vllm_k2horizon";
      id = "k2-horizon-mova-36b-a4b-nvfp4";
      name = "K2-Horizon-MoVA-36B-A4B NVFP4";
      url = "http://127.0.0.1:8020";
      # Must match --max-model-len 32768 in hosts/desktop/llm/vllm/k2horizon-nvfp4.nix.
      context = 80000;
      maxTok = 80000;
      reason = true;
      attachments = false;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    # ─── Omarchy recipes (undockerified, socket-activated) ──────────────────
    # TabbyAPI/EXL3: Qwen3.8-27B in two EXL3 quantizations (exllamav3 backend).
    # SGLang: Gemma-4-12B NVFP4, LFM2.5-2.6B BF16, Ornith-1.5-35B NVFP4.
    # All socket-activated (on-demand VRAM); ports 18091–18100.
    qwen3827b_exl3_sc5bpw = {
      providerName = "tabbyapi_sc5bpw";
      # Must equal the tabbyapi config's model_name (the served OpenAI model id);
      # the engine resolves weights at model_dir/model_name, so this also names
      # the download subdir under /var/lib/omarchy/.
      id = "qwen3827b-exl3-sc5bpw";
      name = "Qwen3.8-27B EXL3 SC5bpw (TabbyAPI)";
      url = "http://127.0.0.1:18091";
      context = 262144;
      maxTok = 32768;
      reason = true;
      attachments = true;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    qwen3827b_exl3_4bpw = {
      providerName = "tabbyapi_4bpw";
      # Must equal the tabbyapi config's model_name (the served OpenAI model id);
      # the engine resolves weights at model_dir/model_name, so this also names
      # the download subdir under /var/lib/omarchy/.
      id = "qwen3827b-exl3-4bpw";
      name = "Qwen3.8-27B EXL3 4bpw (TabbyAPI)";
      url = "http://127.0.0.1:18093";
      context = 262144;
      maxTok = 32768;
      reason = true;
      attachments = false;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    gemma4_12b_nvfp4 = {
      providerName = "sglang_gemma4";
      id = "gemma-4-12b-nvfp4";
      name = "Gemma-4-12B-it NVFP4 (SGLang)";
      url = "http://127.0.0.1:18095";
      context = 131072;
      maxTok = 32768;
      reason = false;
      attachments = false;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    lfm25_26b_bf16 = {
      providerName = "sglang_lfm25";
      id = "lfm2.5-2.6b";
      name = "LFM2.5-2.6B BF16 (SGLang)";
      url = "http://127.0.0.1:18097";
      context = 131072;
      maxTok = 32768;
      reason = false;
      attachments = false;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    ornith15_35b_nvfp4 = {
      providerName = "sglang_ornith";
      id = "ornith-1.5-35b-a3b-nvfp4";
      name = "Ornith-1.5-35B-A3B NVFP4 (SGLang)";
      url = "http://127.0.0.1:18099";
      context = 131072;
      maxTok = 32768;
      reason = false;
      attachments = false;
      costIn = 0;
      costOut = 0;
      costInCached = 0;
      costOutCached = 0;
    };
    deepseekPro = {
      providerName = "deepseek";
      id = "deepseek-v4-pro";
      name = "DeepSeek-V4-Pro";
      url = headroomCloudProxyUrl;
      context = 1048576;
      maxTok = 32768;
      reason = true;
    };
    deepseekFlash = {
      providerName = "deepseek";
      id = "deepseek-v4-flash";
      name = "DeepSeek-V4-Flash";
      url = headroomCloudProxyUrl;
      context = 1048576;
      maxTok = 32768;
      reason = true;
    };
    # Kimi K3 (Moonshot AI) via NVIDIA NIM (Build): a free cloud OpenAI-compatible endpoint (https://integrate.api.nvidia.com/v1), routed through the headroom-proxy-nvidia cloud proxy (8792) which injects the NVIDIA API key host-side. Kimi K3 is a reasoning model that takes a top-level `reasoning_effort` (low/high/max) — the same wire shape the deepseek thinkingFormat emits — and is vision-capable.
    kimik3 = {
      providerName = "nvidia";
      id = "moonshotai/kimi-k3";
      name = "Kimi K3 (NVIDIA NIM)";
      url = headroomNvidiaProxyUrl;
      # Conservative 128k context (well within the model's limit; dsh compacts earlier rather than risk an over-long request).
      context = 131072;
      # Matches the NVIDIA example's max_tokens.
      maxTok = 16384;
      reason = true;
      attachments = true;
      reasoningEfforts = {
        low = "low";
        high = "high";
        max = "max";
      };
    };
  };

  # Map providerName (from the catalog) to the label/style each tool config needs; used only to render per-tool configs consistently.
  providerLabel = {
    llamacpp.name = "llama.cpp (local)";
    llamacpp.type = "openai-compat";
    llamacpp.api_key = "sk-local";
    llamacpp_bonsai.name = "llama.cpp Bonsai fork (local)";
    llamacpp_bonsai.type = "openai-compat";
    llamacpp_bonsai.api_key = "sk-local";
    vllm_awq.name = "vLLM AWQ (local)";
    vllm_awq.type = "openai-compat";
    vllm_awq.api_key = "sk-local";
    vllm_nvfp4.name = "vLLM NVFP4 (local)";
    vllm_nvfp4.type = "openai-compat";
    vllm_nvfp4.api_key = "sk-local";
    vllm_dflash2.name = "vLLM DFlash2 (local)";
    vllm_dflash2.type = "openai-compat";
    vllm_dflash2.api_key = "sk-local";
    vllm_dflash2_direct.name = "vLLM DFlash2 direct (local)";
    vllm_dflash2_direct.type = "openai-compat";
    vllm_dflash2_direct.api_key = "sk-local";
    vllm_k2horizon.name = "vLLM K2-Horizon NVFP4 (local)";
    vllm_k2horizon.type = "openai-compat";
    vllm_k2horizon.api_key = "sk-local";
    vllm_lensvlm.name = "vLLM LensVLM (local)";
    vllm_lensvlm.type = "openai-compat";
    vllm_lensvlm.api_key = "sk-local";
    ninfer.name = "NInfer (local)";
    ninfer.type = "openai-compat";
    ninfer.api_key = "sk-local";
    ninfer_a3b.name = "NInfer A3B (local)";
    ninfer_a3b.type = "openai-compat";
    ninfer_a3b.api_key = "sk-local";
    ninfer_gzenz.name = "NInfer gzenz fork (local)";
    ninfer_gzenz.type = "openai-compat";
    ninfer_gzenz.api_key = "sk-local";
    ninfer_cinference.name = "NInfer Cinference fork (local)";
    ninfer_cinference.type = "openai-compat";
    ninfer_cinference.api_key = "sk-local";
    ninfer_swift.name = "NInfer Swift abliterated (local)";
    ninfer_swift.type = "openai-compat";
    ninfer_swift.api_key = "sk-local";
    sglang.name = "SGLang (local)";
    sglang.type = "openai-compat";
    sglang.api_key = "sk-local";
    tabbyapi_sc5bpw.name = "TabbyAPI EXL3 SC5bpw (local)";
    tabbyapi_sc5bpw.type = "openai-compat";
    tabbyapi_sc5bpw.api_key = "sk-local";
    tabbyapi_4bpw.name = "TabbyAPI EXL3 4bpw (local)";
    tabbyapi_4bpw.type = "openai-compat";
    tabbyapi_4bpw.api_key = "sk-local";
    sglang_gemma4.name = "SGLang Gemma-4 (local)";
    sglang_gemma4.type = "openai-compat";
    sglang_gemma4.api_key = "sk-local";
    sglang_lfm25.name = "SGLang LFM2.5 (local)";
    sglang_lfm25.type = "openai-compat";
    sglang_lfm25.api_key = "sk-local";
    sglang_ornith.name = "SGLang Ornith (local)";
    sglang_ornith.type = "openai-compat";
    sglang_ornith.api_key = "sk-local";
    deepseek.name = "DeepSeek";
    deepseek.type = "openai-compat";
    deepseek.api_key = "sk-local";
    nvidia.name = "NVIDIA NIM (cloud)";
    nvidia.type = "openai-compat";
    nvidia.api_key = "sk-local";
  };

  # LSP catalog, keyed by crush language name: which language server each language uses, the package to mount (host copy, shared with home/packages.nix), and the file types / root markers for init.
  lsps = with pkgs; {
    nix = {
      pkg = nil;
      command = "nil";
      args = [ "--stdio" ];
      fileTypes = [ "nix" ];
      rootMarkers = [ "flake.nix" "shell.nix" "default.nix" ];
      # probe.sh sits next to .nix files and crush opens it in this workspace; without this exclusion nil parses it as Nix and floods diagnostics.
      initOptions = {
        nil = {
          diagnostics.excludedFiles = [ "hosts/desktop/hushmic/probe.sh" ];
        };
      };
    };
    go = {
      pkg = gopls;
      command = "gopls";
      fileTypes = [ "go" ];
      rootMarkers = [ "go.mod" "go.work" "Godeps" ];
    };
    python = {
      pkg = pyright;
      command = "pyright-langserver";
      args = [ "--stdio" ];
      fileTypes = [ "py" "pyi" ];
      rootMarkers = [ "pyproject.toml" "setup.py" "setup.cfg" "requirements.txt" "Pipfile" ".venv" ];
    };
    typescript = {
      pkg = typescript-language-server;
      command = "typescript-language-server";
      args = [ "--stdio" ];
      fileTypes = [ "ts" "tsx" "js" "jsx" ];
      rootMarkers = [ "package.json" "tsconfig.json" "jsconfig.json" ];
    };
    rust = {
      pkg = rust-analyzer;
      command = "rust-analyzer";
      fileTypes = [ "rs" ];
      rootMarkers = [ "Cargo.toml" ];
    };
    lua = {
      pkg = lua-language-server;
      command = "lua-language-server";
      fileTypes = [ "lua" ];
      rootMarkers = [ ".luarc.json" ".luacheckrc" ];
    };
    c_cpp = {
      pkg = clang-tools;
      command = "clangd";
      fileTypes = [ "c" "cc" "cpp" "h" "hpp" ];
      rootMarkers = [ "CMakeLists.txt" "compile_commands.json" "Makefile" ];
    };
    bash = {
      pkg = bash-language-server;
      command = "bash-language-server";
      args = [ "start" ];
      fileTypes = [ "sh" "bash" ];
      rootMarkers = [ ".bashrc" ".bash_profile" ];
    };
    json = {
      pkg = vscode-langservers-extracted;
      command = "vscode-json-language-server";
      args = [ "--stdio" ];
      fileTypes = [ "json" "jsonc" ];
      rootMarkers = [ "package.json" "tsconfig.json" "composer.json" ];
    };
    yaml = {
      pkg = vscode-langservers-extracted;
      command = "yaml-language-server";
      args = [ "--stdio" ];
      fileTypes = [ "yaml" "yml" ];
      rootMarkers = [ ".yamllint" ];
    };
    markdown = {
      pkg = marksman;
      command = "marksman";
      args = [ "server" ];
      fileTypes = [ "md" "mdx" ];
      rootMarkers = [ ".marksman.toml" ];
    };
    toml = {
      pkg = taplo;
      command = "taplo";
      args = [ "lsp" "stdio" ];
      fileTypes = [ "toml" ];
      rootMarkers = [ ".taplo.toml" ];
    };
    sql = {
      pkg = sqls;
      command = "sqls";
      fileTypes = [ "sql" ];
      rootMarkers = [ ".sqls.json" ];
    };
  };

  # Mount the host-installed LSP copies (shared with home/packages.nix) inside every jail once, instead of bundling the full per-tool closure.
  lspAdds = with jail.combinators; [ (add-pkg-deps (lib.unique (map (l: l.pkg) (lib.attrValues lsps)))) ];
  # The crush lsp map restricted to the languages a given tool needs; file_types + root_markers make crush start a server only when that language shows up in the mounted project.
  crushLspFor = toolLsps: lib.mapAttrs'
    (lang: entry:
      lib.nameValuePair lang ({
        inherit (entry) command;
        file_types = entry.fileTypes;
        root_markers = entry.rootMarkers;
      }
      // lib.optionalAttrs (entry ? args) { inherit (entry) args; }
      // lib.optionalAttrs (entry ? initOptions) { init_options = entry.initOptions; }))
    (lib.filterAttrs (lang: _: builtins.elem lang toolLsps) lsps);

  allModels = lib.attrValues models;
  byProvider = name: lib.filter (m: m.providerName == name) allModels;

  # Render a catalog model into the per-model object crush's openai-compat providers expect; optional fields (costs, attachments) are only included when defined, so cloud models stay lean.
  crushModelEntry = m:
    {
      id = m.id;
      name = m.name;
      context_window = m.context;
      default_max_tokens = m.maxTok;
      can_reason = m.reason;
    } // lib.optionalAttrs (m ? attachments) { supports_attachments = m.attachments; }
    // lib.optionalAttrs (m ? costIn) {
      cost_per_1m_in = m.costIn;
      cost_per_1m_out = m.costOut;
      cost_per_1m_in_cached = m.costInCached;
      cost_per_1m_out_cached = m.costOutCached;
    };

  # One crush provider per distinct upstream in the catalog (base_url, key, full model list), so crush exposes exactly the catalog's models.
  crushProviders = builtins.foldl'
    (acc: m:
      let
        p = providerLabel.${m.providerName};
      in
      lib.recursiveUpdate acc {
        ${m.providerName} = {
          name = p.name;
          type = p.type;
          base_url = "${m.url}/v1";
          api_key = p.api_key;
          models = (acc.${m.providerName}.models or [ ]) ++ [ (crushModelEntry m) ];
        } // lib.optionalAttrs (m.providerName == "llamacpp" && m ? thinkingBudget) {
          extra_body = { thinking_budget_tokens = m.thinkingBudget; };
        };
      })
    { }
    allModels;

  # opencode nests providers under provider.<name> with each model keyed by id; reuse the catalog so opencode carries the same models as crush and aider.
  opencodeProvider = pname:
    let nms = byProvider pname; in
    {
      npm = "@ai-sdk/openai-compatible";
      name = providerLabel.${pname}.name;
      options.baseURL = "${(builtins.head nms).url}/v1";
      models = builtins.listToAttrs (map
        (m: {
          name = m.id;
          value.name = m.name;
        })
        nms);
    };
  opencodeProviders = {
    provider = {
      llamacpp = opencodeProvider "llamacpp";
      llamacpp_bonsai = opencodeProvider "llamacpp_bonsai";
      vllm_awq = opencodeProvider "vllm_awq";
      vllm_nvfp4 = opencodeProvider "vllm_nvfp4";
      vllm_dflash2 = opencodeProvider "vllm_dflash2";
      vllm_dflash2_direct = opencodeProvider "vllm_dflash2_direct";
      vllm_k2horizon = opencodeProvider "vllm_k2horizon";
      vllm_lensvlm = opencodeProvider "vllm_lensvlm";
      ninfer = opencodeProvider "ninfer";
      ninfer_a3b = opencodeProvider "ninfer_a3b";
      ninfer_gzenz = opencodeProvider "ninfer_gzenz";
      ninfer_swift = opencodeProvider "ninfer_swift";
      ninfer_cinference = opencodeProvider "ninfer_cinference";
      sglang = opencodeProvider "sglang";
      tabbyapi_sc5bpw = opencodeProvider "tabbyapi_sc5bpw";
      tabbyapi_4bpw = opencodeProvider "tabbyapi_4bpw";
      sglang_gemma4 = opencodeProvider "sglang_gemma4";
      sglang_lfm25 = opencodeProvider "sglang_lfm25";
      sglang_ornith = opencodeProvider "sglang_ornith";
      deepseek = opencodeProvider "deepseek";
      nvidia = opencodeProvider "nvidia";
    };
    model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
    small_model = "${models.gemma4awq.providerName}/${models.gemma4awq.id}";
  };

  # dsh's home user layer ($DSH_HOME/cordis.patch.yml, hot-reloaded). rc.2 removed the standalone user-settings document ($DSH_HOME/settings.yaml): user settings now live in the profile patch layers, and this home-level layer applies above every profile (web/tui/headless), so one file serves them all. Every route names DEEPSEEK_API_KEY: pi-ai's openai-completions insists on a credential even for local endpoints.
  dshHomePatch =
    let
      providers = lib.mapAttrs'
        (pname: ms:
          lib.nameValuePair pname {
            displayName = providerLabel.${pname}.name;
            apiKeyEnv = "DEEPSEEK_API_KEY";
            api = "openai-completions";
            baseURL = "${(builtins.head ms).url}/v1";
            models = map
              (m:
                let
                  # Base local-gateway compat pair (every non-deepseek route); reasoning models additionally select the deepseek wire format (the only openai-completions shape that emits a top-level `reasoning_effort`).
                  compat =
                    (if pname == "deepseek" then { } else {
                      supportsDeveloperRole = false;
                      maxTokensField = "max_tokens";
                    })
                    // (if m ? reasoningEfforts then {
                      thinkingFormat = "deepseek";
                      supportsReasoningEffort = true;
                    } else { });
                in
                {
                  id = m.id;
                  name = m.name;
                  contextWindow = m.context;
                  maxTokens = m.maxTok;
                }
                // lib.optionalAttrs (compat != { }) { inherit compat; }
                // lib.optionalAttrs (m ? reasoningEfforts) {
                  # Expose the declared thinking levels so dsh materializes the model as a reasoning model (the web UI's effort selector reads this).
                  reasoningEfforts = m.reasoningEfforts;
                }
              )
              ms;
          })
        (lib.groupBy (m: m.providerName) allModels);
      # Default agent model: the home layer wins over the base bundle's built-in default (deepseek-official), so new sessions start on the local NVFP4 route.
      defaultModel = models.qwen38_nvfp4_ninfer;
    in
    ''
      # Managed by home-manager (writeDshHomePatch); do not edit by hand.
      - id: llm-pi-ai
        config:
          providers: ${builtins.toJSON providers}
      - id: agent-default-model
        config:
          provider: ${defaultModel.providerName}
          model: ${defaultModel.id}
          reasoningEffort: low
    '';

  # The dsh web profile's patch layer ($DSH_HOME/profiles/web/cordis.patch.yml) is a static dotfile (dotfiles/dsh/cordis.patch.yml), installed by home/llm/jail-home.nix (writeDshWebProfilePatch).

  # Crush PreToolUse hook that rewrites bash commands to use rtk for token savings, transparently (the model still sees its original command); requires rtk and jq, both in commonPkgs.
  rtkRewriteHook = ''
    #!/usr/bin/env bash
    set -euo pipefail

    if ! command -v jq &>/dev/null; then
      exit 0
    fi
    if ! command -v rtk &>/dev/null; then
      exit 0
    fi
    CMD="''${CRUSH_TOOL_INPUT_COMMAND:-}"
    if [ -z "$CMD" ]; then
      exit 0
    fi

    REWRITTEN=$(rtk rewrite "$CMD" 2>/dev/null) && EXIT_CODE=0 || EXIT_CODE=$?

    case $EXIT_CODE in
    0 | 3)
      [ "$CMD" = "$REWRITTEN" ] && exit 0
      jq -n --arg cmd "$REWRITTEN" \
        "{\"decision\":\"allow\",\"updated_input\":({\"command\":\$cmd}|tostring)}"
      ;;
    *)
      exit 0
      ;;
    esac
  '';

  # Identity of the llm agent user (single source of truth: home/users.nix); the "system" jail variants run as this user via `sudo -u llm` instead of root.
  agentHome = users.llm.homeDirectory;
  agentUsername = users.llm.username;

  # Render the crush config for a given state root (user variants under $HOME, system variants under the llm agent user's home); both from the same shared catalogs, so content stays identical.
  crushConfigFor = base: builtins.toJSON {
    "$schema" = "https://charm.land/crush.json";

    # Force the per-project data dir out of the working directory: the system jail runs crush from /etc/nixos, so without this it would mkdir /etc/nixos/.crush and the justfile's auto-stage would sweep the state into git.
    options.data_directory = "${base}/.local/share/crush";
    options.context_paths = [ "AGENTS.md" ];
    options.tui.transparent = true;
    options.tui.compact_mode = true;
    options.tui.scrollbar = "never";

    # Rewrite bash tool calls through rtk to compress token-heavy command output before it reaches the model.
    hooks.PreToolUse = [
      {
        name = "rtk-rewrite";
        matcher = "^bash$";
        command = "${base}/.config/crush/hooks/rtk-rewrite.sh";
        timeout = 10;
      }
    ];

    # Headroom MCP server: exposes headroom_retrieve (plus headroom_compress / headroom_stats) as callable tools so the model can turn the proxy's hash= compression markers back into original content.
    mcp.headroom = {
      type = "stdio";
      command = "headroom";
      args = [ "mcp" "serve" "--proxy-url" "${headroomProxyUrl}" ];
    };

    # Language servers derived from the shared LSP catalog; each is annotated with file_types + root_markers so crush only initializes a server when that language appears in the mounted project.
    lsp = crushLspFor [ "nix" "go" "python" "typescript" "rust" "lua" "c_cpp" "bash" "json" "yaml" "markdown" "toml" "sql" ];

    # Providers derived from the shared model catalog, so crush exposes exactly the same models as opencode and aider.
    providers = crushProviders;
  };

  # Claude Code user settings (settings.json); the env block routes the agent through the Claude-facing headroom proxy to the local llama.cpp, using the catalog's default local model.
  claudeConfig = builtins.toJSON {
    env = {
      ANTHROPIC_BASE_URL = headroomClaudeProxyUrl;
      ANTHROPIC_AUTH_TOKEN = "sk-local";
      ANTHROPIC_MODEL = models.gemma4awq.id;
      ANTHROPIC_SMALL_FAST_MODEL = models.gemma4awq.id;
    };
  };

in
{
  inherit
    headroomPort
    headroomProxyUrl
    headroomUpstreamUrl
    headroomCloudPort
    headroomCloudProxyUrl
    headroomCloudUpstreamUrl
    headroomClaudePort
    headroomClaudeProxyUrl
    headroomNinferPort
    headroomNinferProxyUrl
    headroomNinferUpstreamUrl
    headroomNvidiaPort
    headroomNvidiaProxyUrl
    headroomNvidiaUpstreamUrl
    models
    providerLabel
    lsps
    lspAdds
    crushLspFor
    allModels
    byProvider
    crushModelEntry
    crushProviders
    opencodeProvider
    opencodeProviders
    dshHomePatch
    rtkRewriteHook
    agentHome
    agentUsername
    crushConfigFor
    claudeConfig
    ;
}
