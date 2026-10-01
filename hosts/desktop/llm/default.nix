# The model fleet and its one front door.
#
# ./gate is the single boot-resident availability stub (the ledger's gate
# port, llm.local): it answers availability, decides which model serves a
# request, starts the engine units it needs, and forwards to each engine's own
# loopback port. The engines below own no public port — their engines' ports
# are private plumbing the gate forwards to, and their idle wrappers run in
# lifecycle mode (no socket, no relay: the gate's activity file is what keeps
# a model resident and what releases the VRAM).
#
# The engines: the NInfer forks, the vLLM docker containers, SGLang native,
# the omarchy wheelhouse recipes, Strata, and the llama.cpp router. The shared
# idle wrapper (the load/health/idle machinery) lives in ./idle-wrapper once.
{ lib, ... }:

{
  imports = [
    ./gate
    ./llamacpp
    ./ninfer
    ./sglang
    ./vllm
    ./omarchy
    ./strata
  ];

  # The llama.cpp router module (stock :8000 + Bonsai fork :8010) and Strata
  # (Qwen3.8-Flash-Next GGUF; weights land via the strata-model-download
  # oneshot, revision-gated) are the llm services with enable gates; the
  # others are always-on when imported.
  services.llamacpp.enable = true;
  services.strata.enable = true;
}
