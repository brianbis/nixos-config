# The llama.cpp router server, built from the flakeless `llama-cpp` source
# input (see the flake inputs block) with CUDA support and the sleep-exit patch.
#
# This is an override of the nixpkgs `llama-cpp` package, not a from-scratch
# derivation: the build recipe (CMake + CUDA + the npm webui deps) comes from
# nixpkgs, and we only (a) enable CUDA, (b) point `src` at the flake input so
# `nix flake update llama-cpp` re-pins it to the newest master commit, and
# (c) apply the sleep-exit patch.
#
# The source is a flakeless input, so the fetch hash lives in flake.lock (owned
# by `nix flake update`), not here. The build runs on a source tree WITHOUT
# `.git` (the flake fetcher's checkout), which is exactly what the previous
# fetchFromGitHub+postFetch arrangement produced before it stripped `.git`.
#
# Testable in isolation: nix build .#packages.x86_64-linux.llama-cpp
#
# This recipe is shared by two source trees:
#   - the stock ggml-org/llama.cpp router (default npmDepsHash + sleep-exit
#     patch, consumed by flake.nix as llama-cppPkg), and
#   - the PrismML-Eng Bonsai fork (the fork's npmDepsHash + fork-specific
#     sleep-exit patch, consumed as llama-cpp-bonsaiPkg). The fork's
#     server-context.cpp shifted the sleep-state context, so its patch is a
#     separate file.
{ llama-cpp
, cudaPackages
, src
, npmDepsHash ? "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k="
, sleepExitPatch ? ./llama-cpp-sleep-exit.patch
}:

(llama-cpp.override {
  cudaSupport = true;
  cudaPackages = cudaPackages;
}).overrideAttrs (old: {
  # The flake input's short SHA is a stable, traceable version that
  # `nix flake update llama-cpp` advances.
  version = src.shortRev;
  src = src;

  # The pinned commit changed package-lock.json, so the nixpkgs-pinned
  # npmDepsHash no longer matches this source.
  # TODO(re-pin): carried over from the previous pin; if the build fails on
  # npmDepsHash, copy the "got: sha256-..." value from the error into the
  # caller's npmDepsHash argument (flake.nix).
  npmDepsHash = npmDepsHash;

  # Exit the child process on idle-sleep so the OS reclaims all VRAM. CUDA's
  # allocator caches freed device memory in a per-process pool, so destroy()
  # alone leaves the DFlash drafter's weights and KV cache resident in
  # nvidia-smi. The router detects the exit via stdout EOF and respawns the
  # child on the next request.
  postPatch = (old.postPatch or "") + ''
    patch -p1 -N < ${sleepExitPatch}
  '';
})
