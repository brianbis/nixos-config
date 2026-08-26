# The on-demand LLM model servers: the NInfer engines (socket-activated
# child processes), the vLLM docker containers, and the llama.cpp router.
# The shared socket-activated idle wrapper (the relay/health/idle machinery
# both the NInfer and vLLM services run) lives in ./idle-wrapper.
{ lib, ... }:

{
  imports = [
    ./llamacpp
    ./ninfer
    ./vllm
  ];
}
