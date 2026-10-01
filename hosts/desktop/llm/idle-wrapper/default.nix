# The shared idle wrapper for the on-demand LLM model servers (ninfer, vLLM,
# sglang): each unit's model server is a child process the wrapper owns.
#
# Builds a store directory holding the shared library (idle_wrapper.py) and
# the thin per-backend entry points (ninfer_wrapper.py, vllm_wrapper.py,
# sglang_wrapper.py). Each service runs `python3 <dir>/<backend>_wrapper.py`;
# Python puts the script's own directory on sys.path, so the entry point
# imports the shared library directly. The idle/health/lifecycle machinery
# lives in idle_wrapper.py once; an entry point supplies only its backend
# (how to start the engine, how to stop it, its own defaults).
{ stdenv, lib }:

stdenv.mkDerivation {
  pname = "llm-idle-wrapper";
  version = "1.0.0";

  src = ./.;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    mkdir -p $out
    cp $src/idle_wrapper.py $src/ninfer_wrapper.py $src/vllm_wrapper.py $src/sglang_wrapper.py $out/
  '';

  meta = with lib; {
    description = "Lifecycle idle wrapper for on-demand LLM model servers";
    license = licenses.asl20;
    platforms = platforms.all;
  };
}
