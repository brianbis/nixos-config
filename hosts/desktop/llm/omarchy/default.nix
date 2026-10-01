# Omarchy model recipes: undockerified LLM engines with no port of their own.
#
# Five models on the RTX 5090 (32 GB):
#   - 2× TabbyAPI/EXL3 (Qwen3.8-27B, exllamav3 backend)
#   - 3× SGLang (Gemma-4-12B NVFP4, LFM2.5-2.6B BF16, Ornith-1.5-35B NVFP4)
#
# All engines are lifecycle daemons (on-demand VRAM residency): the gate
# (../gate) starts them when a request names their model and the idle wrapper
# exits, releasing the VRAM, once the gate stops stamping the activity file. Model weights are downloaded on-demand by oneshot services
# (revision-gated: re-downloads only when the pinned revision changes).
#
# Updatable (binaries sourced from their true bases on GitHub via flake
# inputs; `nix flake update <input>` re-pins):
#   - Model weights: change `revision` in ./recipes.nix
#   - EXL3 engine: `nix flake update exllamav3` (the release wheel is selected
#     by the input's version; a new version needs its sha256 added to
#     ./wheelhouse.nix — the build failure prints the wheel URL)
#   - TabbyAPI server: `nix flake update tabbyapi`
#   - SGLang engine: update the wheelhouse in ../sglang/

{ config, lib, pkgs, catalog, ... }:

let
  recipes = import ./recipes.nix;
  factory = import ./lib.nix {
    inherit lib pkgs config catalog;
    idleWrapper = pkgs.callPackage ../idle-wrapper { };
    hfTokenPath = config.age.secrets.hf-token.path;
  };

  # Transform each recipe into its set of systemd units.
  perRecipe = lib.mapAttrs (id: recipe: factory { inherit id recipe; }) recipes;
  recipeList = lib.attrValues perRecipe;

  # Collect unit groups across all recipes.
  allServices = lib.foldl' (acc: u: acc // (u.systemd.services or { })) { } recipeList;
  allTargets = lib.foldl' (acc: u: acc // (u.systemd.targets or { })) { } recipeList;
  allTmpfiles =
    [ "d /var/lib/omarchy 0755 root root -" ]
    ++ lib.concatMap (u: u.systemd.tmpfiles.rules or [ ]) recipeList;
in
{
  systemd.tmpfiles.rules = allTmpfiles;
  systemd.services = allServices;
  systemd.targets = allTargets;
}
