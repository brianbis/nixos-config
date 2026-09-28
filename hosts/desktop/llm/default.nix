# The on-demand LLM model servers: the NInfer engines (socket-activated
# child processes), the vLLM docker containers, the SGLang native engine
# (socket-activated child process), and the llama.cpp router.
# The shared socket-activated idle wrapper (the relay/health/idle machinery
# the NInfer, vLLM, and SGLang services run) lives in ./idle-wrapper.
{ lib, ... }:

{
  imports = [
    ./llamacpp
    ./ninfer
    ./sglang
    ./vllm
    ./omarchy
    ./strata
  ];

  # The llama.cpp router module (stock :8000 + Bonsai fork :8010) and Strata
  # (Qwen3.8-Flash-Next GGUF, off until weights are present) are the llm
  # services with enable gates; the others are always-on when imported.
  services.llamacpp.enable = true;
}
