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

    # GPU-accelerated Whisper transcription (on-demand VRAM residency)
    whisper-service = {
      url = "path:hosts/desktop/whisper-service";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    whisper-service,
    ...
  }@inputs:
  let
    system = "x86_64-linux";

    # Base package set for the NixOS configuration. The headroom overlay is
    # applied here (not only in nixosConfigurations) so pkgs.headroom exists
    # for every consumer of this flake's pkgs, including the agents-md build.
    pkgs = import nixpkgs {
      inherit system;

      overlays = [
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
      ];
    };

    # package.nix uses deprecated/removed xorg.libX11-style names.
    # Build the package locally from the patched copy instead.
    hushmic = pkgs.callPackage ./hosts/desktop/hushmic/package.nix { };


  in
  {
    formatter.${system} =
      nixpkgs.legacyPackages.${system}.nixfmt-rfc-style;

    packages.${system} = let
      # Shared catalog for agents-md generation (needs pkgs and jail-nix only)
      sharedForAgents = import ./home/llm/catalog.nix {
        inherit (nixpkgs.lib) lib;
        inherit pkgs jail-nix;
      };

      # Same user home as declared in home/users.nix, so the generated
      # doc's mounts match the real jails.
      userHome = (import ./home/users.nix).b.homeDirectory;
    in {
      agents-md =
        pkgs.callPackage ./home/llm/agents-gen/agents-md.nix {
          inherit jail-nix llm-agents;
          shared = sharedForAgents;
          inherit userHome;
        };

      imsg = inputs.imsg.packages.${system}.default;

      # Local CA + leaf certificate for the Caddy-served *.local service
      # names (see hosts/desktop/local-ca.nix).
      local-services-ca =
        (import ./hosts/desktop/local-ca.nix {
          inherit pkgs;
          lib = nixpkgs.lib;
        }).ca;
    };

    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;

      modules = [
        ./hosts/desktop
        agenix.nixosModules.default
        home-manager.nixosModules.home-manager

        ./hosts/desktop/whisper-service/module.nix

        ({ config, pkgs, lib, ... }: {
          nixpkgs.config.allowUnfree = true;

          # Socket-activated: the process only exists between a request and the
          # model's release; with autoStop it exits after the 120s idle window
          # (VRAM and host memory freed) and the socket re-activates on demand.
          services.whisper-service = {
            enable = true;
            package = whisper-service.packages.${system}.whisper-service;
            model = "large-v3";
            port = 8790;
            idleTimeout = 120;
            autoStop = true;
            # Host NVIDIA driver package; its /lib (libcuda.so.1) is added to
            # the service's LD_LIBRARY_PATH so ctranslate2's runtime dlopen of
            # the driver stub resolves and CUDA initialises.
            nvidiaDriver = config.hardware.nvidia.package;
          };

          nixpkgs.overlays = [
            nur.overlays.default

            # Provide the locally patched hushmic package under the same
            # attribute name consumed by hosts/desktop/audio.nix.
            (final: prev: {
              hushmic = hushmic;
            })

            # headroom-ai: context compression layer for the jailed LLM agents.
            # (Also applied to the base `pkgs` in the let-block so the
            # standalone agents-md doc build can evaluate jails.nix.)
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

            # The nixpkgs-pinned llama.cpp (b10273) predates the muse-glimmer
            # architecture merge and refuses to load its GGUF; pin b10353.
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

                # Exit the child process on idle-sleep so the OS reclaims all
                # VRAM. CUDA's allocator caches freed device memory in a
                # per-process pool, so destroy() alone leaves the DFlash
                # drafter's weights and KV cache resident in nvidia-smi. The
                # router detects the exit via stdout EOF and respawns the
                # child on the next request.
                postPatch = (old.postPatch or "") + ''
                  patch -p1 -N < ${./patches/llama-cpp-sleep-exit.patch}
                '';
              });
            })
          ];

          home-manager.useGlobalPkgs = true;
          home-manager.backupFileExtension = ".bak";

          home-manager.extraSpecialArgs = {
            inherit
              plasma-manager
              nur
              jail-nix
              llm-agents
              inputs
              ;

            # Shared model/LSP catalog + config renderer, used by both home-manager
            # modules (b's home and the llm agent user's home).
            shared = import ./home/llm/catalog.nix {
              inherit lib pkgs jail-nix;
            };

            deepseekSecret = config.age.secrets.deepseek-api-key.path;
            imsgMacSecret = config.age.secrets.imsg-mac.path;
          };

          home-manager.users.b = import ./home;

          # The llm agent user's home: the writable state root of the
          # "system" jail variants (run as llm via `sudo -u llm`). Managed
          # declaratively here instead of seeded by a root activation script.
          home-manager.users.llm = import ./home/llm/agent-home.nix;
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