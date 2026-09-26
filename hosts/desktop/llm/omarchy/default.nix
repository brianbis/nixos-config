# Omarchy model recipes: undockerified, socket-activated LLM engines.
#
# Five models on the RTX 5090 (32 GB):
#   - 2× TabbyAPI/EXL3 (Qwen3.8-27B, exllamav3 backend)
#   - 3× SGLang (Gemma-4-12B NVFP4, LFM2.5-2.6B BF16, Ornith-1.5-35B NVFP4)
#
# All engines are socket-activated (on-demand VRAM residency) with the shared
# idle wrapper. Model weights are downloaded on-demand by oneshot services
# (revision-gated: re-downloads only when the pinned revision changes).
#
# Updatable:
#   - Model weights: change `revision` in ./recipes.nix
#   - EXL3 engine: `nix flake update exllamav3`
#   - SGLang engine: update the wheelhouse in ../sglang/

{ config, lib, pkgs, ... }:

let
  recipes = import ./recipes.nix;
  factory = import ./lib.nix {
    inherit lib pkgs config;
    idleWrapper = pkgs.callPackage ../idle-wrapper { };
    hfTokenPath = config.age.secrets.hf-token.path;
  };

  # Transform each recipe into its set of systemd units.
  perRecipe = lib.mapAttrs (id: recipe: factory { inherit id recipe; }) recipes;

  # Merge all per-recipe results into a single module body.
  merged = lib.foldl'
    (acc: units: lib.recursiveUpdate acc units)
    { }
    (lib.attrValues perRecipe);
in
{
  # The shared /var/lib/omarchy base dir.
  systemd.tmpfiles.rules = [
    "d /var/lib/omarchy 0755 root root -"
  ];

  # All the generated units (download services, engine services, sockets, targets).
  config = lib.recursiveUpdate config merged;
}
