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
    sidra = {
      url = "github:wimpysworld/sidra";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # iMessage client via Bluetooth MAP/PBAP
    imsg = {
      url = "path:./home/imsg";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Jailed LLM tooling
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";

    # Real-time microphone noise suppression (DPDFNet + PipeWire virtual mic)
    
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
    ...
  }@inputs:
  let
    system = "x86_64-linux";

    # Base package set used by the NixOS configuration.
    pkgs = import nixpkgs {
      inherit system;
    };

    # package.nix uses deprecated/removed xorg.libX11-style names.
    # Build the package locally from the patched copy instead.
    hushmic = pkgs.callPackage ./hosts/desktop/hushmic/package.nix { };

    # pkgs with headroom overlay for agents-md.
    agentsPkgs = import nixpkgs {
      inherit system;

      overlays = [
        (final: prev: {
          headroom =
            final.python3.pkgs.callPackage ./home/llm/headroom.nix {
              python = final.python3;
            };

          python3 = prev.python3.override {
            packageOverrides = pyfinal: pyprev: {
              headroom =
                pyfinal.callPackage ./home/llm/headroom.nix {
                  python = pyfinal;
                };
            };
          };
        })
      ];
    };
  in
  {
    formatter.${system} =
      nixpkgs.legacyPackages.${system}.nixfmt-rfc-style;

    packages.${system} = {
      agents-md =
        agentsPkgs.callPackage ./home/llm/agents-gen/agents-md.nix {
          inherit jail-nix llm-agents;
        };

      imsg = inputs.imsg.packages.${system}.default;
    };

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

            # Provide the locally patched hushmic package under the same
            # attribute name consumed by hosts/desktop/audio.nix.
            (final: prev: {
              hushmic = hushmic;
            })

            # headroom-ai: context compression layer for the jailed LLM agents.
            (final: prev: {
              python3 = prev.python3.override {
                packageOverrides = pyfinal: pyprev: {
                  ast-grep-cli =
                    pyfinal.callPackage ./home/llm/ast-grep-cli.nix {
                      ast-grep = prev.ast-grep;
                    };
                };
              };

              headroom =
                final.python3.pkgs.callPackage ./home/llm/headroom.nix {
                  python = final.python3;
                };
            })

            # Muse-Glimmer needs llama.cpp b10353+ (architecture merge 2026-08-10).
            # The nixpkgs pin here (2026-07-26) ships b10273, which refuses to load
            # the muse-glimmer GGUF ("architecture muse-glimmer not registered").
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
                    git -C "$out" rev-parse --short HEAD > "$out/COMMIT"
                    find "$out" -name .git -print0 | xargs -0 rm -rf
                  '';
                };

                # b10353 changed package-lock.json, so the nixpkgs-pinned
                # npmDepsHash no longer matches this source.
                npmDepsHash =
                  "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k=";
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
          ;
      };
    };
  };
}