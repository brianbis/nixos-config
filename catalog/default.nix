# ─── The LLM fleet: one table, two consumers ────────────────────────────────
#
# This file is the single source of truth for the whole local-LLM fleet. It is
# pure data (no NixOS options, no shell): every fact about a model — the id it
# serves, the engine that serves it, the systemd unit that puts it in VRAM, the
# port that engine binds, its context/capabilities/cost — lives in exactly one
# row here.
#
#   home/llm/catalog.nix  imports this and renders the per-tool config documents
#                         (crush.json, opencode.json, cordis.patch.yml,
#                         settings.json, aider aliases).
#   hosts/desktop/llm/*   imports this and generates the systemd units.
#   hosts/desktop/llm/gate  imports this and renders the availability stub's
#                         routing table (the one public face agents talk to).
#
# Adding a model = one row here plus (if it needs a new engine) a recipe.
# Renaming a served id = one edit here: the router presets, the tool configs,
# the local-CA vhosts and the gate table all follow. (See the stale-reference
# traps: nothing else may hardcode a model id or a port.)
#
# Row fields
#   provider        display group a tool shows (key into `providers` below)
#   id              the served OpenAI model id — what agents send as `model`
#   name            human label
#   engine          which hosts/desktop/llm module builds this row's units
#   unit            systemd unit the gate starts to make the model live
#                   (null = already resident at boot, or not ours to start)
#   port            the port that engine binds (the gate probes it for liveness)
#   relay           port-ledger key the gate forwards the request through
#                   (a headroom compression front, or null = straight to `port`)
#   family          redirect class: engines serving the same weights/artifact
#   context/maxTok  wire facts every tool config renders
#   reason/attachments capabilities the gate checks before redirecting
#   reasoningEfforts/thinkingBudget  per-model thinking controls
#   cost            per-1M pricing (omitted = free local)
#   vramMib         free VRAM the engine needs before it can load (gate policy)
#   onDemand        the gate may start `unit` when a request names this model
#   preference      tie-break when several engines serve one `id` (higher wins)

rec {

  # ─── Port ledger ──────────────────────────────────────────────────────────
  # The only place a port number appears. `gate` is the single public face for
  # local models; everything below it is internal plumbing that is bound only
  # while that engine is resident. local-ca.nix derives its vhosts//etc-hosts/
  # CA SANs from this ledger, so a freed port frees all three at once.
  #
  # Freed (never reuse — these were the front ports the gate replaced):
  #   8080 8082 8084 8086 8088 8091 18085 18087 18089 18091 18093 18095 18097 18099
  ports = {
    # The one public face for every local model.
    gate = 8100;

    # Context-compression fronts (headroom). Boot-resident user services; the
    # gate relays through them so the compression markers + the headroom MCP
    # retrieve flow keep working on the routes that want them.
    headroom = 8787; # -> llamacpp router
    headroomCloud = 8788; # -> api.deepseek.com (host-side key injection)
    headroomClaude = 8789; # -> llamacpp router, Anthropic-shaped face
    headroomNinfer = 8791; # -> ninfer child
    headroomNvidia = 8792; # -> integrate.api.nvidia.com (host-side key)

    # Boot-resident engines (always live; llama.cpp sleeps per-model internally).
    llamacpp = 8000;
    llamacppBonsai = 8010;

    # On-demand engines: each binds ONLY its own loopback port while resident.
    ninfer = 8081;
    ninferA3B = 8083;
    ninferGzenz = 8085;
    ninferSwift = 8089;
    ninferCinference = 8092;
    sglang = 8087;
    dflash2 = 18090;
    strata = 18086;
    strataCoder = 18088;
    tabbyapiSc5bpw = 18092;
    tabbyapi4bpw = 18094;
    sglangGemma4 = 18096;
    sglangLfm25 = 18098;
    sglangOrnith = 18100;

    # vLLM docker containers: manual start (just vllm-*), never auto-loaded.
    vllmGemma4Nvfp4 = 8021;
    vllmGemma4Awq = 8022;
    vllmLensvlm = 8023;
    vllmK2horizon = 8020;
  };

  # ─── Provider groups ──────────────────────────────────────────────────────
  # The display grouping each tool config renders under. `hosted = true` means
  # the model is reached through a cloud headroom front (key injected host-side)
  # rather than through the gate.
  providers = {
    llamacpp = {
      label = "llama.cpp (local)";
      hosted = false;
    };
    llamacpp_bonsai = {
      label = "llama.cpp Bonsai fork (local)";
      hosted = false;
    };
    vllm_awq = {
      label = "vLLM AWQ (local)";
      hosted = false;
    };
    vllm_nvfp4 = {
      label = "vLLM NVFP4 (local)";
      hosted = false;
    };
    vllm_k2horizon = {
      label = "vLLM K2-Horizon NVFP4 (local)";
      hosted = false;
    };
    vllm_lensvlm = {
      label = "vLLM LensVLM (local)";
      hosted = false;
    };
    vllm_dflash2 = {
      label = "vLLM DFlash2 (local)";
      hosted = false;
    };
    ninfer = {
      label = "NInfer (local)";
      hosted = false;
    };
    ninfer_a3b = {
      label = "NInfer A3B (local)";
      hosted = false;
    };
    ninfer_gzenz = {
      label = "NInfer gzenz fork (local)";
      hosted = false;
    };
    ninfer_cinference = {
      label = "NInfer Cinference fork (local)";
      hosted = false;
    };
    ninfer_swift = {
      label = "NInfer Swift abliterated (local)";
      hosted = false;
    };
    sglang = {
      label = "SGLang (local)";
      hosted = false;
    };
    tabbyapi_sc5bpw = {
      label = "TabbyAPI EXL3 SC5bpw (local)";
      hosted = false;
    };
    tabbyapi_4bpw = {
      label = "TabbyAPI EXL3 4bpw (local)";
      hosted = false;
    };
    sglang_gemma4 = {
      label = "SGLang Gemma-4 (local)";
      hosted = false;
    };
    sglang_lfm25 = {
      label = "SGLang LFM2.5 (local)";
      hosted = false;
    };
    sglang_ornith = {
      label = "SGLang Ornith (local)";
      hosted = false;
    };
    strata = {
      label = "Strata (local)";
      hosted = false;
    };
    strata_coder = {
      label = "Strata Coder (local)";
      hosted = false;
    };
    deepseek = {
      label = "DeepSeek";
      hosted = true;
    };
    nvidia = {
      label = "NVIDIA NIM (cloud)";
      hosted = true;
    };
  };

  # ─── The models ───────────────────────────────────────────────────────────
  models = {

    # ── llama.cpp router (:8000, boot-resident) ─────────────────────────────
    # Requests reach these through the headroom compression front (8787) so the
    # proxy's hash= markers + the headroom MCP retrieve flow keep working.
    muse = {
      provider = "llamacpp";
      id = "muse-glimmer-30B";
      name = "Muse-Glimmer-30B (kquant-dynamic GGUF)";
      engine = "llamacpp";
      unit = null;
      port = ports.llamacpp;
      relay = "headroom";
      family = "muse";
      context = 131072;
      maxTok = 8192;
      reason = true;
      attachments = true;
      vramMib = 30000;
      onDemand = false;
    };
    qwen38_thinking = {
      provider = "llamacpp";
      id = "qwen3-8-27b-q8_0-thinking";
      name = "Qwen3.8-27B Q8_0 Thinking";
      engine = "llamacpp";
      unit = null;
      port = ports.llamacpp;
      relay = "headroom";
      family = "qwen3.8";
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
      vramMib = 27000;
      onDemand = false;
    };
    qwen38_instruct = {
      provider = "llamacpp";
      id = "qwen3-8-27b-q8_0-instruct";
      name = "Qwen3.8-27B Q8_0 Instruct";
      engine = "llamacpp";
      unit = null;
      port = ports.llamacpp;
      relay = "headroom";
      family = "qwen3.8";
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
      vramMib = 27000;
      onDemand = false;
    };
    qwen38heretic_q6k = {
      provider = "llamacpp";
      id = "qwen3-8-27b-heretic-q6_k";
      name = "Qwen3.8-27B Heretic RVN Abliterated Uncensored Q6_K";
      engine = "llamacpp";
      unit = null;
      port = ports.llamacpp;
      relay = "headroom";
      family = "qwen3.8";
      context = 131072;
      maxTok = 80000;
      reason = true;
      attachments = true;
      vramMib = 21000;
      onDemand = false;
    };
    mimo = {
      provider = "llamacpp";
      id = "mimo-v2.6-9b-bf16";
      name = "MiMo-V2.6-Distill-Qwen-9B (bf16 GGUF)";
      engine = "llamacpp";
      unit = null;
      port = ports.llamacpp;
      relay = "headroom";
      family = "mimo";
      context = 262144;
      maxTok = 240000;
      reason = true;
      attachments = true;
      vramMib = 18000;
      onDemand = false;
    };

    # ── llama.cpp Bonsai fork router (:8010, boot-resident) ─────────────────
    # Two modes (thinking/instruct) over one router; effort is per-request.
    bonsai2_27b_pq2_thinking = {
      provider = "llamacpp_bonsai";
      id = "bonsai2-27b-pq2_0-thinking";
      name = "Ternary-Bonsai-2-27B PQ2_0 Thinking";
      engine = "llamacpp";
      unit = null;
      port = ports.llamacppBonsai;
      relay = null;
      family = "bonsai";
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
      reasoningEfforts = {
        medium = "medium";
        xhigh = "xhigh";
      };
      vramMib = 8000;
      onDemand = false;
    };
    bonsai2_27b_pq2_instruct = {
      provider = "llamacpp_bonsai";
      id = "bonsai2-27b-pq2_0-instruct";
      name = "Ternary-Bonsai-2-27B PQ2_0 Instruct";
      engine = "llamacpp";
      unit = null;
      port = ports.llamacppBonsai;
      relay = null;
      family = "bonsai";
      context = 262144;
      maxTok = 8192;
      reason = true;
      attachments = true;
      thinkingBudget = -1;
      reasoningEfforts = {
        medium = "medium";
        xhigh = "xhigh";
      };
      vramMib = 8000;
      onDemand = false;
    };

    # ── NInfer (native, lifecycle idle wrapper) ─────────────────────────────
    # Four engines over the SAME Qwen3.8-27B NVFP4 artifact; they share the
    # served id, so `preference` decides which one a bare `qwen3.8-27b` request
    # gets when none is resident (the stock engine wins).
    qwen38_nvfp4_ninfer = {
      provider = "ninfer";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer";
      engine = "ninfer";
      unit = "ninfer-serve";
      port = ports.ninfer;
      relay = "headroomNinfer";
      family = "qwen3.8";
      context = 240000;
      maxTok = 200000;
      reason = false;
      attachments = false;
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
      vramMib = 22000;
      onDemand = true;
      preference = 100;
    };
    qwen38_nvfp4_ninfer_gzenz = {
      provider = "ninfer_gzenz";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer (gzenz fork, ~420k ctx)";
      engine = "ninfer";
      unit = "ninfer-serve-gzenz";
      port = ports.ninferGzenz;
      relay = null;
      family = "qwen3.8";
      # Effective per-request ceiling: the fork's --kv-capacity auto pool
      # resolves to ~420k tokens at the current free-after-weights headroom.
      context = 420000;
      maxTok = 200000;
      reason = false;
      attachments = false;
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
      vramMib = 22000;
      onDemand = true;
      preference = 40;
    };
    qwen38_nvfp4_ninfer_cinference = {
      provider = "ninfer_cinference";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer (Cinference fork, MTP-10)";
      engine = "ninfer";
      unit = "ninfer-serve-cinference";
      port = ports.ninferCinference;
      relay = null;
      family = "qwen3.8";
      context = 262144;
      maxTok = 262144;
      reason = false;
      attachments = false;
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
      vramMib = 22000;
      onDemand = true;
      preference = 30;
    };
    qwen38_swift_abliterated_nvfp4_ninfer = {
      provider = "ninfer_swift";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 NInfer (Swift abliterated)";
      engine = "ninfer";
      unit = "ninfer-serve-swift";
      port = ports.ninferSwift;
      relay = null;
      family = "qwen3.8";
      context = 240000;
      maxTok = 200000;
      reason = false;
      attachments = false;
      reasoningEfforts = {
        low = "low";
        medium = "medium";
        xhigh = "xhigh";
      };
      vramMib = 22000;
      onDemand = true;
      preference = 20;
    };
    qwen36_a3b_ninfer = {
      provider = "ninfer_a3b";
      id = "qwen3.6-35b-a3b";
      name = "Qwen3.6-35B-A3B NInfer";
      engine = "ninfer";
      unit = "ninfer-serve-a3b";
      port = ports.ninferA3B;
      relay = null;
      family = "qwen3.6-a3b";
      context = 262144;
      maxTok = 200000;
      reason = false;
      attachments = true;
      vramMib = 24000;
      onDemand = true;
      # No reasoningEfforts: the A3B chat template rejects an effort control.
    };

    # ── SGLang (native, lifecycle idle wrapper) ─────────────────────────────
    qwen38_nvfp4_sglang = {
      provider = "sglang";
      id = "qwen3.8-27b";
      name = "Qwen3.8-27B NVFP4 SGLang";
      engine = "sglang";
      unit = "sglang-serve";
      port = ports.sglang;
      relay = null;
      family = "qwen3.8";
      # Must match --context-length in hosts/desktop/llm/sglang/default.nix.
      context = 32768;
      maxTok = 32768;
      reason = false;
      attachments = false;
      vramMib = 22000;
      onDemand = true;
      preference = 10;
    };

    # ── vLLM DFlash2 (native, lifecycle idle wrapper) ───────────────────────
    # One row: the gate replaces the wrapper, so the child port is the only
    # port and there is no "(direct)" twin to carry a second baseURL.
    qwen38_dflash2 = {
      provider = "vllm_dflash2";
      id = "qwen3.8-27b-nvfp4-dflash2";
      name = "Qwen3.8-27B NVFP4 DFlash2";
      engine = "dflash2";
      unit = "vllm-qwen38-dflash2";
      port = ports.dflash2;
      relay = null;
      family = "qwen3.8";
      context = 262144;
      maxTok = 32768;
      reason = true;
      attachments = false;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 24000;
      onDemand = true;
      preference = 50;
    };

    # ── Strata (dedicated engine, built from source) ────────────────────────
    strata_qwen38 = {
      provider = "strata";
      id = "qwen3.8-flash-next";
      name = "Qwen3.8-Flash-Next IQ3_XXS (Strata)";
      engine = "strata";
      unit = "strata-serve";
      port = ports.strata;
      relay = null;
      family = "strata";
      context = 131072;
      maxTok = 32768;
      reason = true;
      attachments = true;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      # Matches strata baseMinFreeVramMib: the 125B MoE experts need the whole
      # card, so the gate refuses to load this row over anything already live.
      vramMib = 30000;
      onDemand = true;
    };
    strata_qwen38_coder = {
      provider = "strata_coder";
      id = "qwen3.8-flash-next-coder";
      name = "Qwen3.8-Flash-Next Coder IQ1_M (Strata)";
      engine = "strata";
      unit = "strata-coder-serve";
      port = ports.strataCoder;
      relay = null;
      family = "strata";
      context = 200000;
      maxTok = 32768;
      reason = true;
      attachments = true;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      # Matches strata coderMinFreeVramMib; the coder expert-pruned release
      # leaves room to be loaded while a smaller engine is live.
      vramMib = 22000;
      onDemand = true;
    };

    # ── Omarchy recipes (undockerified, on-demand) ──────────────────────────
    # ids must equal the recipe's servedName / TabbyAPI model_name.
    qwen3827b_exl3_sc5bpw = {
      provider = "tabbyapi_sc5bpw";
      id = "qwen3827b-exl3-sc5bpw";
      name = "Qwen3.8-27B EXL3 SC5bpw (TabbyAPI)";
      engine = "omarchy";
      unit = "omarchy-qwen3827b-exl3-sc5bpw";
      port = ports.tabbyapiSc5bpw;
      relay = null;
      family = "qwen3.8";
      context = 262144;
      maxTok = 32768;
      reason = true;
      attachments = true;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 20000;
      onDemand = true;
    };
    qwen3827b_exl3_4bpw = {
      provider = "tabbyapi_4bpw";
      id = "qwen3827b-exl3-4bpw";
      name = "Qwen3.8-27B EXL3 4bpw (TabbyAPI)";
      engine = "omarchy";
      unit = "omarchy-qwen3827b-exl3-4bpw";
      port = ports.tabbyapi4bpw;
      relay = null;
      family = "qwen3.8";
      context = 262144;
      maxTok = 32768;
      reason = true;
      attachments = false;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 16000;
      onDemand = true;
    };
    gemma4_12b_nvfp4 = {
      provider = "sglang_gemma4";
      id = "gemma-4-12b-nvfp4";
      name = "Gemma-4-12B-it NVFP4 (SGLang)";
      engine = "omarchy";
      unit = "omarchy-gemma4-12b-nvfp4";
      port = ports.sglangGemma4;
      relay = null;
      family = "gemma-4";
      context = 131072;
      maxTok = 32768;
      reason = false;
      attachments = false;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 12000;
      onDemand = true;
    };
    lfm25_26b_bf16 = {
      provider = "sglang_lfm25";
      id = "lfm2.5-2.6b";
      name = "LFM2.5-2.6B BF16 (SGLang)";
      engine = "omarchy";
      unit = "omarchy-lfm25-26b-bf16";
      port = ports.sglangLfm25;
      relay = null;
      family = "lfm2.5";
      context = 131072;
      maxTok = 32768;
      reason = false;
      attachments = false;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 6000;
      onDemand = true;
    };
    ornith15_35b_nvfp4 = {
      provider = "sglang_ornith";
      id = "ornith-1.5-35b-a3b-nvfp4";
      name = "Ornith-1.5-35B-A3B NVFP4 (SGLang)";
      engine = "omarchy";
      unit = "omarchy-ornith15-35b-nvfp4";
      port = ports.sglangOrnith;
      relay = null;
      family = "ornith";
      context = 131072;
      maxTok = 32768;
      reason = false;
      attachments = false;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 26000;
      onDemand = true;
    };

    # ── vLLM docker containers (manual start: just vllm-*) ──────────────────
    # onDemand = false: a container cold-starts in minutes, so the gate never
    # loads one behind a request — it serves these only while already live,
    # otherwise it redirects. Start them with `just vllm-*`.
    gemma4awq = {
      provider = "vllm_awq";
      id = "gemma-4-awq";
      name = "Gemma 4 26B MoE AWQ";
      engine = "vllmDocker";
      unit = "docker-vllm-gemma4-awq";
      port = ports.vllmGemma4Awq;
      relay = null;
      family = "gemma-4";
      context = 262144;
      # Single-generation cap for a 32GB card alongside the 17GB AWQ weights.
      maxTok = 65536;
      reason = true;
      attachments = true;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 20000;
      onDemand = false;
    };
    gemma4nvfp4 = {
      provider = "vllm_nvfp4";
      id = "gemma-4-nvfp4";
      name = "Gemma 4 31B NVFP4";
      engine = "vllmDocker";
      unit = "docker-vllm-gemma4-nvfp4-turbo";
      port = ports.vllmGemma4Nvfp4;
      relay = null;
      family = "gemma-4";
      # Must match --max-model-len in hosts/desktop/llm/vllm/gemma4-nvfp4-turbo.nix.
      context = 32768;
      maxTok = 30000;
      reason = true;
      attachments = false;
      cost = {
        input = 0.14;
        output = 0.28;
        inputCached = 0.014;
        outputCached = 0.28;
      };
      vramMib = 24000;
      onDemand = false;
    };
    k2horizon_nvfp4 = {
      provider = "vllm_k2horizon";
      id = "k2-horizon-mova-36b-a4b-nvfp4";
      name = "K2-Horizon-MoVA-36B-A4B NVFP4";
      engine = "vllmDocker";
      unit = "docker-vllm-k2horizon-nvfp4";
      port = ports.vllmK2horizon;
      relay = null;
      family = "k2-horizon";
      # Must match --max-model-len in hosts/desktop/llm/vllm/k2horizon-nvfp4.nix.
      context = 80000;
      maxTok = 80000;
      reason = true;
      attachments = false;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 24000;
      onDemand = false;
    };
    lensvlm = {
      provider = "vllm_lensvlm";
      id = "lensvlm-9b";
      name = "LensVLM-9B (bf16 vLLM)";
      engine = "vllmDocker";
      unit = "docker-vllm-lensvlm";
      port = ports.vllmLensvlm;
      relay = null;
      family = "lensvlm";
      # Must match --max-model-len in hosts/desktop/llm/vllm/lensvlm.nix.
      context = 131072;
      maxTok = 32768;
      reason = true;
      attachments = true;
      cost = {
        input = 0;
        output = 0;
        inputCached = 0;
        outputCached = 0;
      };
      vramMib = 22000;
      onDemand = false;
    };

    # ── Hosted (cloud headroom fronts, key injected host-side) ──────────────
    # The gate's last-resort fallback: when no local engine can serve a request
    # (VRAM, or every local engine idle-and-cold), these are always live.
    deepseekPro = {
      provider = "deepseek";
      id = "deepseek-v4-pro";
      name = "DeepSeek-V4-Pro";
      engine = "hosted";
      unit = null;
      port = ports.headroomCloud;
      relay = null;
      family = "hosted";
      context = 1048576;
      maxTok = 32768;
      reason = true;
      vramMib = 0;
      onDemand = false;
      hosted = true;
    };
    deepseekFlash = {
      provider = "deepseek";
      id = "deepseek-v4-flash";
      name = "DeepSeek-V4-Flash";
      engine = "hosted";
      unit = null;
      port = ports.headroomCloud;
      relay = null;
      family = "hosted";
      context = 1048576;
      maxTok = 32768;
      reason = true;
      vramMib = 0;
      onDemand = false;
      hosted = true;
    };
    kimik3 = {
      provider = "nvidia";
      id = "moonshotai/kimi-k3";
      name = "Kimi K3 (NVIDIA NIM)";
      engine = "hosted";
      unit = null;
      port = ports.headroomNvidia;
      relay = null;
      family = "hosted";
      # Conservative window: dsh compacts before the model's real limit.
      context = 262144;
      maxTok = 16384;
      reason = true;
      attachments = true;
      reasoningEfforts = {
        low = "low";
        high = "high";
        max = "max";
      };
      vramMib = 0;
      onDemand = false;
      hosted = true;
    };
  };

  # ─── Gate policy ──────────────────────────────────────────────────────────
  # The availability stub's decisions, as data.
  gate = {
    # The one public face every jailed tool talks to (llm.local).
    port = ports.gate;
    # The model a request with no usable `model` (or an unknown one) gets.
    default = models.qwen38_nvfp4_ninfer;
    # Free VRAM the card reports before the gate will even consider loading.
    cardFreeMib = 32768;
    # Where the gate stamps "this engine is still wanted": one file per unit
    # under this directory, whose mtime is the engine's residency signal.
    activityDir = "/run/llm-gate/activity";
    # Poll interval / ceiling for "the engine finished loading".
    readyTimeoutSeconds = 120;
    # A local engine stays "live" this many seconds past its last request,
    # matching the idle wrapper's own window so the gate and the engine agree.
    liveGraceSeconds = 90;
  };
}
