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
  ];
}
