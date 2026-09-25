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

    # Jailed LLM tooling
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";

    # GPU-accelerated Whisper transcription (on-demand VRAM residency)
    whisper-service = {
      url = "path:hosts/desktop/whisper-service";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Linux + iPhone Continuity bridge (clipboard, files, messages, notifications).
    tether = {
      url = "github:zackb/tether/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # hushmic: real-time mic noise suppression (local build fetches the DPDFNet model).
    hushmic = {
      url = "github:Fovty/hushmic";
      flake = false;
    };

    # --- flakeless source inputs -------------------------------------------
    # Upstream source trees for packages built locally. Each is a flakeless
    # input (upstream has no flake.nix): inputs.<name> is the source tree and
    # `nix flake update <name>` re-pins it to the newest commit of the default
    # branch. The lock's `original` carries no ref/rev, so the input tracks the
    # default branch while `locked` stays at the pinned rev.
    headroom = {
      url = "github:chopratejas/headroom";
      flake = false;
    };
    # knife: reverse engineer's binary Swiss-army knife (triage/disassembly/crypto/YARA + built-in MCP).
    knife = {
      url = "github:bl4ckr0ss3/knife";
      flake = false;
    };
    # graphify: codebase -> queryable knowledge graph + stdio MCP server.
    graphify = {
      url = "github:Graphify-Labs/graphify";
      flake = false;
    };
    # graphlore: richer MCP server (28 tools) wrapping graphify's knowledge graph.
    graphlore = {
      url = "github:yasinyaman/graphlore";
      flake = false;
    };
    # echarts: interactive chart library (npm-only; local package fetches the matching npm dist).
    echarts = {
      url = "github:apache/echarts";
      flake = false;
    };
    # bend: dependently typed, affine language that blocks AI mistakes via proof.
    bend = {
      url = "github:bendlang/bend";
      flake = false;
    };
    # difftastic: structural diff that understands syntax (pure Rust).
    difftastic = {
      url = "github:Wilfred/difftastic";
      flake = false;
    };
    # ripwire: "the ripgrep of AI context" — a zero-dependency C++23 CLI + MCP server.
    ripwire = {
      url = "github:redhat-et/ripwire";
      flake = false;
    };
    minuspod = {
      url = "github:ttlequals0/MinusPod";
      flake = false;
    };
    fluent-oled = {
      url = "github:fermeridamagni/fluent-oled";
      flake = false;
    };
    nix-ide = {
      url = "github:nix-community/vscode-nix-ide";
      flake = false;
    };
    wezurrect = {
      url = "github:YedPool/Wezurrect";
      flake = false;
    };
    librepods = {
      url = "github:librepods-org/librepods";
      flake = false;
    };
    ninfer = {
      url = "github:Neroued/ninfer";
      flake = false;
    };
    ninfer-gzenz = {
      url = "github:gzenz/ninfer";
      flake = false;
    };
    # cinference: focused NInfer fork (MTP draft window 10, CUDA Graph topology); builds with the shared mkNinfer recipe.
    cinference = {
      url = "github:satellitedown/cinference";
      flake = false;
    };
    # archipelago meta-flake: bundles main source + PopTracker/apworld as nested inputs (read via outputs.archipelagoInputs.<name>).
    archipelago = {
      url = "path:hosts/desktop/archipelago";
    };
    kivymd = {
      url = "github:kivymd/KivyMD";
      flake = false;
    };
    zilliandomizer = {
      url = "github:beauxq/zilliandomizer";
      flake = false;
    };
    # recurse: AI-native IDE for reverse engineering (Tauri 2; pluggable analysis backend).
    recurse = {
      url = "github:Recurse-Labs/recurse";
      flake = false;
    };
    # serein: tiny, performant 100% native Discord client (Rust/egui/wgpu).
    serein = {
      url = "github:ViceVerse-cz/Serein";
      flake = false;
    };

    # uv2nix toolchain: build Archipelago's Python env from a uv.lock (see hosts/desktop/archipelago/uv/).
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };

    # llama.cpp: router server for the local LLM fleet; re-pinning may need a new npmDepsHash in hosts/desktop/llm/llamacpp/package.nix.
    llama-cpp = {
      url = "github:ggml-org/llama.cpp";
      flake = false;
    };

    # llama.cpp Bonsai fork: carries the ternary kernels (PTQ1_0/PQ2_0) stock llama.cpp rejects; only Ternary-Bonsai-2-27B needs it.
    llama-cpp-bonsai = {
      url = "github:PrismML-Eng/llama.cpp";
      flake = false;
    };

    # dsh (deepseek-harness) source (pnpm monorepo); built offline by home/llm/dsh/ (npm ci OOMs); re-pin via just dsh-repin.
    dsh = {
      url = "github:deepseek-ai/deepseek-harness";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , home-manager
    , plasma-manager
    , agenix
    , nur
    , jail-nix
    , llm-agents
    , whisper-service
    , tether
    , ...
    }@inputs:
    let
      system = "x86_64-linux";

      # Local agent tooling overlay (home/llm/tools/overlay.nix); applied to the base pkgs and the system nixpkgs.overlays.
      headroomOverlay = (import ./home/llm/tools/overlay.nix) inputs.headroom inputs.knife inputs.graphify inputs.graphlore inputs.echarts inputs.bend inputs.difftastic inputs.ripwire;

      # Work around a nixpkgs CUDA cccl patch already present in the CCCL 13.3.3.4.1 tarball (causes a "Reversed patch" failure); disable the cudaOlder gate.
      ccclPatchWorkaround = final: prev: {
        cudaPackages_13_2 = prev.cudaPackages_13_2.overrideScope (f: p: {
          cccl = p.cccl.override { cudaOlder = _: false; };
        });
        cudaPackages_13_3 = prev.cudaPackages_13_3.overrideScope (f: p: {
          cccl = p.cccl.override { cudaOlder = _: false; };
        });
      };

      # Base package set for the NixOS configuration.
      pkgs = import nixpkgs {
        inherit system;

        overlays = [ headroomOverlay ccclPatchWorkaround ];
      };

      # --- locally built packages -----------------------------------------
      # Built locally from the flakeless source inputs above; exposed as flake
      # packages and/or nixpkgs overlays so the NixOS modules can consume them.
      # hushmic: built locally because nixpkgs' recipe uses deprecated xorg.libX11-style names.
      hushmic = pkgs.callPackage ./hosts/desktop/hushmic/package.nix {
        src = inputs.hushmic;
        version = inputs.hushmic.shortRev;
      };

      # librepods: AirPods lifecycle daemon (Rust rewrite), patched to persist PPM state to state.json.
      librepods = pkgs.callPackage ./hosts/desktop/librepods/package.nix {
        src = inputs.librepods;
      };

      # librepodsTray: LibrePods battery system-tray indicator (StatusNotifierItem) reading the daemon's state.json.
      librepodsTray = pkgs.callPackage ./hosts/desktop/librepods/tray.nix { };

      # recurse: AI-native IDE for reverse engineering (see hosts/desktop/recurse/package.nix).
      recurse = pkgs.callPackage ./hosts/desktop/recurse/package.nix {
        src = inputs.recurse;
        version = "0.1.0";
      };

      # serein: lightweight native Discord client (see hosts/desktop/serein/package.nix).
      serein = pkgs.callPackage ./hosts/desktop/serein/package.nix {
        src = inputs.serein;
      };

      # sglangPkg: SGLang runtime (pinned CUDA wheel assembly on python313); the FlashInfer JIT needs a self-consistent CUDA toolkit from nixpkgs.
      sglangPkg =
        pkgs.callPackage ./hosts/desktop/llm/sglang/package.nix {
          cudaToolkit = cudaToolkitPkgs.cudaPackages_13.cudatoolkit;
        };

      # archipelagoPkg: Archipelago Multi-Game Randomizer and Server (pinned source + python3.13 env + entry-point wrappers).
      archipelagoPkg = pkgs.callPackage ./hosts/desktop/archipelago/package.nix {
        src = inputs.archipelago.outputs.archipelagoInputs.src;
        env = archipelagoUvEnv;
      };

      # archipelagoUvEnv: Archipelago Python env built from a uv.lock via uv2nix (single source of truth for runtime deps; see hosts/desktop/archipelago/uv/).
      archipelagoUvEnv =
        let
          workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = ./hosts/desktop/archipelago/uv;
          };
          overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
          pythonSet =
            (pkgs.callPackage inputs.pyproject-nix.build.packages {
              python = pkgs.python313;
            }).overrideScope (pkgs.lib.composeManyExtensions [
              inputs.pyproject-build-systems.overlays.wheel
              overlay
            ]);
        in
        pythonSet.mkVirtualEnv "archipelago-uv-env" (workspace.deps.default);

      # vllmDflash2Pkg / cudaToolkitPkgs: native vLLM v0.27.1 + DFlash2 K7 (undockerified Qwen3.8); the FlashInfer JIT needs a full CUDA toolkit from nixpkgs (unfree).
      cudaToolkitPkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
        # The CUDA 13.3 toolkit pulls cuda13.3-cccl, so the cccl workaround applies here too.
        overlays = [ ccclPatchWorkaround ];
      };

      vllmDflash2Pkg =
        pkgs.callPackage ./hosts/desktop/llm/vllm/dflash2-package.nix {
          cudaToolkit = cudaToolkitPkgs.cudaPackages_13.cudatoolkit;
        };

      # llama-cppPkg: llama.cpp router server (pinned source + CUDA + sleep-exit patch), built against the unfree-enabled pkgs.
      llama-cppPkg = cudaToolkitPkgs.callPackage ./hosts/desktop/llm/llamacpp/package.nix {
        src = inputs.llama-cpp;
      };

      # llama-cpp-bonsaiPkg: Bonsai fork build (same recipe, fork's npmDepsHash + a fork-specific sleep-exit patch; the stock patch no longer applies).
      llama-cpp-bonsaiPkg = cudaToolkitPkgs.callPackage ./hosts/desktop/llm/llamacpp/package.nix {
        src = inputs.llama-cpp-bonsai;
        npmDepsHash = "sha256-2Q7XhaLAArmviOLdQsNbYTfdyDE5pW9lR26cRHEVl9k=";
        sleepExitPatch = ./hosts/desktop/llm/llamacpp/llama-cpp-bonsai-sleep-exit.patch;
      };


    in
    {
      formatter.${system} =
        nixpkgs.legacyPackages.${system}.nixfmt;

      apps.${system} = {
        nixpkgs-fmt = {
          type = "app";
          program = "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt";
          meta.description = "Format Nix code (nixpkgs-fmt)";
        };
        black = {
          type = "app";
          program = "${pkgs.black}/bin/black";
          meta.description = "Python code formatter (black)";
        };
        prettier = {
          type = "app";
          program = "${pkgs.prettier}/bin/prettier";
          meta.description = "Opinionated code formatter (prettier)";
        };
        shfmt = {
          type = "app";
          program = "${pkgs.shfmt}/bin/shfmt";
          meta.description = "Shell script formatter (shfmt)";
        };
        yamllint = {
          type = "app";
          program = "${pkgs.yamllint}/bin/yamllint";
          meta.description = "YAML linter (yamllint)";
        };
        markdownlint-cli2 = {
          type = "app";
          program = "${pkgs.markdownlint-cli2}/bin/markdownlint-cli2";
          meta.description = "Markdown linter (markdownlint-cli2)";
        };
      };

      packages.${system} =
        let
          # Shared catalog for agents-md generation (needs pkgs and jail-nix only)
          sharedForAgents = import ./home/llm/catalog.nix {
            inherit (nixpkgs.lib) lib;
            inherit pkgs jail-nix;
          };

          # Same user home as declared in home/users.nix, so the generated
          # doc's mounts match the real jails.
          userHome = (import ./home/users.nix).b.homeDirectory;
        in
        {
          # Each package is testable in isolation:
          #   nix build --impure --no-link --print-out-paths .#packages.x86_64-linux.<name>
          # (--no-link required on nix 2.34: --print-out-paths alone drops a
          # result symlink in the repo root.)

          # The generated AGENTS.md doc (see home/llm/agents-gen/).
          agents-md =
            pkgs.callPackage ./home/llm/agents-gen/agents-md.nix {
              inherit jail-nix llm-agents;
              shared = sharedForAgents;
              inherit userHome;
              # Upstream dsh source (flakeless input); the agents doc builds dsh from this tree.
              dshSrc = inputs.dsh;
            };

          # Local CA + leaf cert for the Caddy-served *.local service names (see hosts/desktop/local-ca.nix).
          local-services-ca =
            (import ./hosts/desktop/local-ca.nix {
              inherit pkgs;
              lib = nixpkgs.lib;
            }).ca;

          # The pinned dsh source tree, exposed so home/llm/dsh/update-deps.py can materialize it.
          dsh-src = inputs.dsh.outPath;

          # WezTerm session-persistence plugin (resurrect.wezterm fork).
          wezurrect = pkgs.callPackage ./home/wezterm/resurrect.nix {
            src = inputs.wezurrect;
            version = inputs.wezurrect.shortRev;
          };

          # SGLang runtime.
          sglang = sglangPkg;

          # Native vLLM v0.27.1 + DFlash2 K7 runtime.
          vllm-dflash2 = vllmDflash2Pkg;

          # llama.cpp router server.
          llama-cpp = llama-cppPkg;

          # llama.cpp Bonsai fork (Ternary-Bonsai-2-27B).
          llama-cpp-bonsai = llama-cpp-bonsaiPkg;

          # Archipelago Multi-Game Randomizer and Server (see let-block).
          archipelago = archipelagoPkg;

          # Archipelago Python env (uv.lock via uv2nix; see let-block).
          archipelago-uv-env = archipelagoUvEnv;

          # Music transcription pipeline env (python312: torch CPU, demucs, librosa).
          music-transcription = pkgs.callPackage ./hosts/desktop/music-transcription/package.nix { };

          # knife: reverse engineer's binary Swiss-army knife (see home/llm/tools/knife.nix).
          knife = pkgs.knife;

          # graphify: codebase -> knowledge graph + stdio MCP server (see home/llm/tools/graphify.nix).
          graphify = pkgs.graphify;

          # graphlore: richer MCP server wrapping graphify's graph (see home/llm/tools/graphlore.nix).
          graphlore = pkgs.graphlore;

          # echarts: interactive chart library (see home/llm/tools/echarts.nix).
          echarts = pkgs.echarts;

          # bend: dependently typed affine language that blocks AI mistakes via proof (see home/llm/tools/bend.nix).
          bend = pkgs.bend;

          # difftastic: structural diff that understands syntax (see home/llm/tools/difftastic.nix).
          difftastic = pkgs.difftastic;

          # ripwire: "the ripgrep of AI context" CLI + MCP server (see home/llm/tools/ripwire.nix).
          ripwire = pkgs.ripwire;

          # open-code-review: Alibaba's AI code review CLI, invoked as ocr (see home/llm/tools/open-code-review.nix).
          open-code-review = pkgs.openCodeReview;

          # Recurse: AI-native IDE for reverse engineering (see hosts/desktop/recurse/package.nix).
          recurse = recurse;

          # Serein: lightweight native Discord client (see hosts/desktop/serein/package.nix).
          serein = serein;

          # TEMPORARY (minuspod 2.97.4 re-pin verification); uses allowUnfree pkgs (the CUDA ctranslate2 core is unfree).
          minuspod =
            let
              pkgsU = import inputs.nixpkgs {
                inherit system;
                config.allowUnfree = true;
              };
              m = import ./home/minuspod.nix {
                pkgs = pkgsU;
                lib = nixpkgs.lib;
                inherit inputs;
              };
            in
            builtins.elemAt m.home.packages 0;

          # Tether — Linux + iPhone Continuity bridge (upstream package).
          tether = inputs.tether.packages.${system}.default;

          # Repacks Tether's Firefox OTP-autofill add-on into the NUR <id>.xpi layout the firefox module wants.
          tether-firefox-extension = pkgs.runCommand "tether-firefox-extension-xpi"
            {
              tether = inputs.tether.packages.${system}.default;
            } ''
            mkdir -p "$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
            cp "$tether/share/tether/extensions/tether-browser-extension.zip" \
              "$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/tether@tether.com.xpi"
            touch "$out"
          '';
        };

      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          ./hosts/desktop
          agenix.nixosModules.default
          home-manager.nixosModules.home-manager

          ./hosts/desktop/whisper-service/module.nix
          ./hosts/desktop/archipelago/module.nix

          ({ config, pkgs, lib, ... }: {
            nixpkgs.config.allowUnfree = true;

            # Socket-activated: with autoStop it exits after the 120s idle window (VRAM + host memory freed) and re-activates on demand.
            services.whisper-service = {
              enable = true;
              package = whisper-service.packages.${system}.whisper-service;
              model = "large-v3";
              port = 8790;
              idleTimeout = 120;
              autoStop = true;
              # Host NVIDIA driver; its /lib (libcuda.so.1) is on LD_LIBRARY_PATH so ctranslate2's dlopen of the driver stub resolves.
              nvidiaDriver = config.hardware.nvidia.package;
            };

            nixpkgs.overlays = [
              # The (final: prev: { ... }) overlays below each expose a locally
              # built package under the attribute name the NixOS/home modules
              # consume (pkgs.<name>).
              nur.overlays.default

              # CUDA cccl patch workaround (see ccclPatchWorkaround); also applied to the system pkgs.
              ccclPatchWorkaround

              (final: prev: {
                hushmic = hushmic;
              })

              (final: prev: {
                librepods = librepods;
                librepodsTray = librepodsTray;
              })

              (final: prev: {
                recurse = recurse;
              })

              (final: prev: {
                serein = serein;
              })

              (final: prev: {
                sglang = sglangPkg;
              })

              (final: prev: {
                archipelago = archipelagoPkg;
              })

              (final: prev: {
                vllmDflash2 = vllmDflash2Pkg;
              })

              (final: prev: {
                llama-cpp = llama-cppPkg;
              })

              (final: prev: {
                llama-cpp-bonsai = llama-cpp-bonsaiPkg;
              })

              # Tether — Linux + iPhone Continuity bridge (upstream overlay).
              tether.overlays.default

              # headroom-ai context compression for the jailed LLM agents (same def as the base pkgs).
              headroomOverlay

              # Force Discord into X11 (XWayland): its Wayland renderer SIGSEGVs on Plasma 6 + NVIDIA; applied as an overlay so both home.packages and the autostart get the flag.
              (final: prev: {
                discord = prev.discord.override {
                  commandLineArgs = "--ozone-platform=x11";
                };
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

              # Shared model/LSP catalog + config renderer, used by both home-manager modules.
              shared = import ./home/llm/catalog.nix {
                inherit lib pkgs jail-nix;
              };

              deepseekSecret = config.age.secrets.deepseek-api-key.path;

              # NVIDIA driver (libcuda.so.1); passed to home/minuspod.nix so the minuspod service can dlopen the driver stub for CUDA whisper.
              nvidiaDriver = config.boot.kernelPackages.nvidiaPackages.latest;

              # Pinned Archipelago source inputs (the meta-flake's nested inputs); the archipelago modules build the apworld/mod zips from source (see zip-from-source.nix).
              archipelagoSources = {
                balatroap = inputs.archipelago.outputs.archipelagoInputs.balatroap;
                sts2 = inputs.archipelago.outputs.archipelagoInputs.sts2;
                universal-tracker = inputs.archipelago.outputs.archipelagoInputs."universal-tracker";
              };
            };

            home-manager.users.b = import ./home;

            # The llm agent user's home: writable state root of the "system" jail variants (run as llm via sudo -u llm).
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
