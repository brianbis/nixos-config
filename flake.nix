{
  description = "b's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nur.url = "github:nix-community/NUR";

    # Apple Music desktop client
    sidra.url = "github:wimpysworld/sidra";

    # Jailed LLM tooling
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";

    # Real-time microphone noise suppression (DPDFNet + PipeWire virtual mic)
    hushmic-nix.url = "github:Fovty/hushmic-nix";
  };

  outputs = {
    self,
    nixpkgs,
    home-manager,
    plasma-manager,
    agenix,
    nur,
    jail-nix,
    llm-agents,
    hushmic-nix,
    ...
  }@inputs:
  let
    system = "x86_64-linux";
  in
  {
    formatter.${system} =
      nixpkgs.legacyPackages.${system}.nixfmt-rfc-style;
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;

      modules = [
        ./hosts/desktop
        agenix.nixosModules.default
        home-manager.nixosModules.home-manager

        ({ config, pkgs, lib, ... }: {
          nixpkgs.config.allowUnfree = true;

          nixpkgs.overlays = [
            nur.overlays.default

            # headroom-ai: context compression layer for the jailed LLM agents.
            (final: prev: {
              python3 = prev.python3.override {
                packageOverrides = pyfinal: pyprev: {
                  ast-grep-cli = pyfinal.callPackage ./packages/ast-grep-cli.nix {
                    ast-grep = prev.ast-grep;
                  };
                };
              };

              headroom = final.python3.pkgs.callPackage ./packages/headroom.nix {
                python = final.python3;
              };
            })

            # Muse-Glimmer needs llama.cpp b10353+ (architecture merge 2026-08-10).
            # The nixpkgs pin here (2026-07-26) ships b10273, which refuses to load
            # the muse-glimmer GGUF ("architecture muse-glimmer not registered").
            # Override llama-cpp to build from a llama.cpp master tag that includes
            # the merge, with CUDA enabled for the RTX 5090. First build will fail
            # on the SRI hash; set hash to the value printed in the error.
            (final: prev: {
              llama-cpp = (prev.llama-cpp.override {
                cudaSupport = true;
                cudaPackages = prev.cudaPackages;
              }).overrideAttrs (old: {
                  version = "10353";
                  src = prev.fetchFromGitHub {
                    owner = "ggml-org";
                    repo = "llama.cpp";
                    tag = "b10353";
                    hash = "sha256-/kjqrGjkWJtlotTcZE5r+gSoce+llGwXz4gmQEOe8M0=";
                    leaveDotGit = true;
                    postFetch = ''
                      git -C "$out" rev-parse --short HEAD > $out/COMMIT
                      find "$out" -name .git -print0 | xargs -0 rm -rf
                    '';
                  };
                  # b10353 changed package-lock.json, so the nixpkgs-pinned
                  # npmDepsHash no longer matches this source.
                  npmDepsHash = "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k=";
                });
            })
          ];

          home-manager.useGlobalPkgs = true;

          home-manager.extraSpecialArgs = {
            inherit
              plasma-manager
              nur
              jail-nix
              llm-agents
              hushmic-nix
              inputs
              ;

            # Shared model/LSP catalog + config renderer, used by both
            # home/llm/default.nix and hosts/desktop/crush-system.nix.
            shared = import ./home/llm/catalog.nix {
              inherit lib pkgs jail-nix;
            };

            deepseekSecret = config.age.secrets.deepseek-api-key.path;
          };

          home-manager.users.b = import ./home;
        })
      ];

      specialArgs = {
        inherit
          nur
          inputs
          jail-nix
          llm-agents
          hushmic-nix
          ;
      };
    };
  };
}
