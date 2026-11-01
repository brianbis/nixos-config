# dsh packaging: builds @deepseek-ai/dsh from the pinned upstream source
#
# yz copy (2026-10-31): a verbatim fork of home/llm/dsh, kept INSIDE this
# subflake because the stick copy evaluates standalone and may import only
# ./*.nix — the same "own copy" rule hosts/yzerd/flake.nix already states for
# the uv workspace. The one intentional difference: versionCheckHomeHook
# defaults to pkgs.versionCheckHook instead of taking the llm-agents hook the
# root flake injects; this subflake has no llm-agents input, and the hook is
# only an install-check plugin.
#
#   src (dsh input)
#     -> tarball.nix        the @deepseek-ai/dsh npm tarball: the upstream
#                           release pipeline on the stock nixpkgs pnpm
#                           machinery (fetchPnpmDeps store pin +
#                           pnpmConfigHook offline install, build:official,
#                           pack)
#     -> package.nix        the installed package (node_modules unpacked from
#                           per-package fetchurl FODs pinned by
#                           package-lock.json + deps-sha256.json; no npm at
#                           build time, since `npm ci` OOMs on this tree)
#   node.nix               the official Node.js binary dsh runs on (the
#                           node-addon-require-builtin probe rejects the
#                           nixpkgs node build)
#   update-deps.py         re-pin helper for the npm side: regenerates
#                           package-lock.json + deps-sha256.json (npm
#                           closure only) from the pinned tree
#
# The pnpm side carries no committed lock data: fetchPnpmDeps reads the
# source's own pnpm-lock.yaml, so moving the dsh input cannot strand a
# stale pnpm pin (the former committed pnpm-lock.json staleness class is
# gone).
#
# Re-pin: `just dsh-repin` bumps the dsh input to the newest npm-published
# release tag, regenerates the npm pin files, and refreshes the
# fetchPnpmDeps hash. The version follows the pinned tree's root package.json.
{ pkgs, src, versionCheckHomeHook ? pkgs.versionCheckHook }:

let
  version = (builtins.fromJSON (builtins.readFile (src + "/package.json"))).version;
  commit = src.rev;
  tarball = pkgs.callPackage ./tarball.nix {
    src = src;
    version = version;
    commit = commit;
  };
  node = (import ./node.nix) { inherit pkgs; };
  package = (pkgs.callPackage ./package.nix {
    inherit versionCheckHomeHook;
    inherit version commit;
    src = "${tarball}/deepseek-ai-dsh-${version}.tgz";
    nodejs = node;
  });
in
{
  inherit version commit tarball node package;
}
