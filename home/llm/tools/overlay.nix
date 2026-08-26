# headroom-ai: context compression layer for the jailed LLM agents.
#
# Single source of truth for the headroom overlay. flake.nix applies it at two
# sites from this one definition:
#   - the base `pkgs` (so pkgs.headroom exists for every consumer of this
#     flake's pkgs, including the agents-md build)
#   - the NixOS system's nixpkgs.overlays
final: prev: {
  python3 = prev.python3.override {
    packageOverrides = pyfinal: pyprev: {
      ast-grep-cli =
        pyfinal.callPackage ./ast-grep-cli.nix {
          ast-grep = prev.ast-grep;
        };
    };
  };

  headroom =
    final.python3.pkgs.callPackage ./headroom.nix {
      python = final.python3;
    };
}
