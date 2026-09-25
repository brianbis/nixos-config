# dsh packaging: builds @deepseek-ai/dsh from the pinned upstream source
# (the flakeless `dsh` flake input).
#
#   src (dsh input)
#     -> tarball.nix        the @deepseek-ai/dsh npm tarball (upstream release
#                           pipeline: offline pnpm install from a
#                           per-package-fetched store, build:official, pack)
#     -> package.nix        the installed package (node_modules unpacked from
#                           per-package fetchurl FODs; no npm at build time)
#   node.nix               the official Node.js binary dsh runs on (the
#                           node-addon-require-builtin probe rejects the
#                           nixpkgs node build)
#   update-deps.py         the re-pin helper: regenerates package-lock.json
#                           + deps-sha256.json from the pinned tree (the
#                           npm-closure data files; the .nix files carry no
#                           hashes).
#
# Re-pin: `just dsh-repin` (= `nix flake update dsh` + update-deps.py); the
# version follows the pinned tree's root package.json.
{ pkgs, src, versionCheckHomeHook }:

let
  version = (builtins.fromJSON (builtins.readFile (src + "/package.json"))).version;
  tarball = pkgs.callPackage ./tarball.nix {
    inherit src version;
    commit = src.rev;
  };
  node = (import ./node.nix) { inherit pkgs; };
  package = (pkgs.callPackage ./package.nix {
    inherit versionCheckHomeHook;
    inherit version;
    src = "${tarball}/deepseek-ai-dsh-${version}.tgz";
    nodejs = node;
  });
in {
  inherit version tarball node package;
}
