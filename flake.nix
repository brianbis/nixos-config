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
    # Upstream flake: one package (tether, tetherd, tether-gtk, tether-dialog,
    # browser native-messaging hosts, extension bundles, systemd unit) plus a
    # programs.tether NixOS module (wifi/avahi, bluetooth, extensions).
    tether = {
      url = "github:zackb/tether/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Crystal Forge: NixOS fleet monitoring / build coordination / compliance.
    # Upstream flake: Rust server (embedded web UI), API-mode builder, agent,
    # cf-keygen, a `services.crystal-forge` NixOS module and a nixpkgs overlay
    # exposing `pkgs.crystal-forge.*`. Pinned to the `dev` branch; `nix flake
    # update crystal-forge` re-pins to the newest dev commit.
    crystal-forge = {
      url = "gitlab:crystal-forge/crystal-forge/dev";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Upstream hushmic source (real-time mic noise suppression). Not a flake
    # (no flake.nix upstream), so this is a flakeless input: inputs.hushmic is
    # the source tree, and `nix flake update hushmic` re-pins it to the newest
    # commit of the default branch. The local package (hosts/desktop/hushmic/
    # package.nix) builds it, fetching the DPDFNet model and wrapping the binary.
    hushmic = {
      url = "github:Fovty/hushmic";
      flake = false;
    };

    # --- flakeless source inputs -------------------------------------------
    # Upstream source trees for packages that are built locally (see the
    # package.nix files) but were previously pinned with fetchFromGitHub. Each
    # is a flakeless input (upstream has no flake.nix): inputs.<name> is the
    # source tree, and `nix flake update <name>` re-pins it to the newest
    # commit of the default branch. The lock's `original` carries no ref/rev so
    # the input tracks the default branch, while `locked` stays at the
    # currently-pinned rev (same pattern as hushmic).
    headroom = {
      url = "github:chopratejas/headroom";
      flake = false;
    };
    # knife: a reverse engineer's binary Swiss-army knife (PE/ELF/Mach-O triage,
    # disassembly, function/CFG recovery, crypto-constant + YARA scanning) that
    # ships a built-in `knife mcp` stdio server. Not a flake upstream, so this is
    # a flakeless input: inputs.knife is the source tree, and `nix flake update
    # knife` re-pins it to the newest commit of the default branch. The local
    # package (home/llm/tools/knife.nix) builds it.
    knife = {
      url = "github:bl4ckr0ss3/knife";
      flake = false;
    };
    # graphify: codebase -> queryable knowledge graph (Graphify-Labs/graphify).
    # A Claude Code skill + CLI (pip `graphifyy`) that ships a built-in
    # `graphify-mcp` stdio MCP server. Not in nixpkgs; built from the flakeless
    # input (home/llm/tools/graphify.nix). `nix flake update graphify` re-pins it.
    graphify = {
      url = "github:Graphify-Labs/graphify";
      flake = false;
    };
    # graphlore: richer third-party MCP server (28 tools) that wraps graphify's
    # knowledge graph (span engine, semantic locate, impact/blast-radius). Not on
    # PyPI; built from the flakeless input (home/llm/tools/graphlore.nix).
    graphlore = {
      url = "github:yasinyaman/graphlore";
      flake = false;
    };
    # echarts: rich interactive chart library (Apache-2.0). npm-only, so this is
    # a flakeless input: inputs.echarts is the source tree, and `nix flake update
    # echarts` re-pins it to the newest commit of the default branch (master).
    # The local package (home/llm/tools/echarts.nix) reads the version from the
    # source's package.json and fetches the matching pre-built npm dist.
    echarts = {
      url = "github:apache/echarts";
      flake = false;
    };
    # bend: a dependently typed, affine language that blocks AI mistakes via
    # proof (bendlang/bend). TypeScript compiler/interpreter/checker run by
    # bun; `bend <f> -o` emits C compiled by clang. Not a flake upstream, so
    # this is a flakeless input: inputs.bend is the source tree, and `nix flake
    # update bend` re-pins it to the newest commit of the default branch. The
    # local package (home/llm/tools/bend.nix) builds it.
    bend = {
      url = "github:bendlang/bend";
      flake = false;
    };
    # difftastic: a structural diff that understands syntax
    # (Wilfred/difftastic). Pure Rust (tree-sitter + four vendored C parsers).
    # Not a flake upstream, so this is a flakeless input: inputs.difftastic is
    # the source tree, and `nix flake update difftastic` re-pins it to the
    # newest commit of the default branch (master). The local package
    # (home/llm/tools/difftastic.nix) builds it.
    difftastic = {
      url = "github:Wilfred/difftastic";
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
    # Archipelago meta-flake (hosts/desktop/archipelago/flake.nix). Bundles the
    # main Archipelago source + the PopTracker / apworld repos as nested
    # inputs, so `nix flake update archipelago` re-pins them all in one shot.
    # Each nested input tracks its upstream default branch (no hardcoded ref);
    # the flake.lock records the locked rev for each. The top-level flake and
    # the home-manager modules read the nested inputs via
    # `inputs.archipelago.outputs.archipelagoInputs.<name>` (src / poptracker /
    # balatroap / sts2 / universal-tracker / balatroap-poptracker).
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

    # uv2nix: build Archipelago's Python environment from a uv.lock (see
    # hosts/desktop/archipelago/uv/). pyproject-nix is the core library that
    # turns PEP 508 / lock data into Nix derivations; uv2nix ingests uv
    # workspaces (pyproject.toml + uv.lock); pyproject-build-systems provides
    # the wheel/build-system overlays. All follow our nixpkgs so the whole
    # graph pins to one nixpkgs revision.
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

    # llama.cpp: the router server for the local LLM fleet (Muse-Glimmer-30B,
    # Qwen3.8-27B, Heretic-RVN). Not a flake upstream, so this is a flakeless
    # input: inputs.llama-cpp is the source tree, and `nix flake update
    # llama-cpp` re-pins it to the newest commit of the default branch
    # (master). The local package (hosts/desktop/llm/llamacpp/package.nix)
    # builds it (CUDA + sleep-exit patch) and the flake exposes it as
    # pkgs.llama-cpp for the NixOS module. Re-pinning may require updating
    # npmDepsHash in that package.nix — see the "got: sha256-…" re-pin note
    # there.
    llama-cpp = {
      url = "github:ggml-org/llama.cpp";
      flake = false;
    };

    # llama.cpp Bonsai fork: the PrismML-Eng fork carrying the custom ternary
    # hybrid-attention kernels (PTQ1_0 / PQ2_0) that stock llama.cpp rejects
    # (it loads PQ2_0 as Q2_0 and produces garbage). Only the Ternary-Bonsai-2-27B
    # model needs it; the stock llama-cpp input above keeps serving the Muse /
    # Qwen / Heretic fleet. Pinned the same way: `nix flake update
    # llama-cpp-bonsai` re-pins to the newest commit of the fork's default
    # branch (prism).
    llama-cpp-bonsai = {
      url = "github:PrismML-Eng/llama.cpp";
      flake = false;
    };

    # Upstream dsh (deepseek-harness) source. Not a flake (no flake.nix
    # upstream), so this is a flakeless input: inputs.dsh is the source tree
    # (a pnpm monorepo), and `nix flake update dsh` re-pins it to the newest
    # commit of the default branch (the exact pin lives in flake.lock). The
    # local package (home/llm/dsh-package.nix) builds the @deepseek-ai/dsh
    # npm tarball from this tree by replicating the upstream release pipeline
    # (pnpm install --frozen-lockfile, pnpm run build:official, pnpm pack of
    # apps/cli), then runs the usual buildNpmPackage recipe on the tarball.
    # The version follows the pinned tree's root package.json (see jails.nix).
    # Re-pinning may also require updating the two npm-closure sub-pins
    # (pnpmDeps.hash in home/llm/dsh-source.nix and npmDepsHash +
    # home/llm/dsh-package-lock.json in home/llm/dsh-package.nix) — see the
    # "got: sha256-…" re-pin note in each file.
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

      # Local agent tooling (headroom-ai context compression + knife RE
      # Swiss-army knife + graphify knowledge graph + graphlore MCP). Defined
      # once in home/llm/tools/overlay.nix; applied both to the base `pkgs`
      # below (so pkgs.headroom / pkgs.knife / pkgs.graphify / pkgs.graphlore
      # exist for every consumer of this flake's pkgs, including the agents-md
      # build) and to the NixOS system's nixpkgs.overlays. The overlay takes the
      # flakeless `headroom`, `knife`, `graphify` and `graphlore` inputs as its
      # sources, so `nix flake update <name>` re-pins each.
      headroomOverlay = (import ./home/llm/tools/overlay.nix) inputs.headroom inputs.knife inputs.graphify inputs.graphlore inputs.echarts inputs.bend inputs.difftastic;

      # Base package set for the NixOS configuration.
      pkgs = import nixpkgs {
        inherit system;

        overlays = [ headroomOverlay ];
      };

      # package.nix uses deprecated/removed xorg.libX11-style names, so the
      # package is built locally from the patched recipe instead of nixpkgs.
      # The upstream source comes from the flakeless `hushmic` input (see the
      # inputs block); `nix flake update hushmic` re-pins it to the newest
      # commit of the default branch.
      hushmic = pkgs.callPackage ./hosts/desktop/hushmic/package.nix {
        src = inputs.hushmic;
        version = inputs.hushmic.shortRev;
      };

      # LibrePods (Rust rewrite) — AirPods lifecycle daemon, patched to persist
      # the parsed PPM state to state.json. Built locally (heavy: iced/wgpu +
      # bluer + libpulse + dbus) under the justfile build-flags caps. Source
      # from the flakeless `librepods` input; `nix flake update librepods`
      # re-pins it.
      librepods = pkgs.callPackage ./hosts/desktop/librepods/package.nix {
        src = inputs.librepods;
      };

      # LibrePods battery system-tray indicator (StatusNotifierItem). Slim,
      # mostly-textual SNI icon that reads the daemon's state.json.
      librepodsTray = pkgs.callPackage ./hosts/desktop/librepods/tray.nix { };

      # SGLang runtime (pinned CUDA wheel assembly on python313). Built once
      # here and exposed both as a flake package (testable in isolation) and
      # via a nixpkgs overlay so the NixOS module can consume pkgs.sglang.
      # The FlashInfer JIT needs a self-consistent CUDA toolkit (nvcc +
      # headers); see the vllmDflash2Pkg comment below for why it comes from
      # nixpkgs (cudaToolkitPkgs, defined further down in this let-block — Nix
      # let-bindings are order-independent).
      sglangPkg =
        pkgs.callPackage ./hosts/desktop/llm/sglang/package.nix {
          cudaToolkit = cudaToolkitPkgs.cudaPackages_13.cudatoolkit;
        };

      # Archipelago Multi-Game Randomizer and Server: pinned upstream source +
      # python3.13 environment with all runtime deps, entry-point wrappers
      # (archipelago-webhost/server/generate/launcher) and a custom-world
      # skeleton under share/archipelago/worlds/. The source comes from the
      # archipelago meta-flake's `src` nested input (ArchipelagoMW/Archipelago);
      # `nix flake update archipelago` re-pins it to the newest main commit.
      archipelagoPkg = pkgs.callPackage ./hosts/desktop/archipelago/package.nix {
        src = inputs.archipelago.outputs.archipelagoInputs.src;
        env = archipelagoUvEnv;
      };

      # Archipelago Python environment built from a uv.lock via uv2nix — the
      # single source of truth for the runtime deps. The lock + pyproject.toml
      # live in hosts/desktop/archipelago/uv/ (regenerated from the upstream
      # requirements*.txt via `uv lock`; see the agent workflow template).
      # sourcePreference = "wheel" prefers prebuilt wheels (e.g. kivy 2.3.1's
      # self-contained SDL2 wheel) and builds the git deps (kivymd, pony fork,
      # zilliandomizer) from source. deps.default = the base `dependencies`
      # (no extras/groups, which this virtual project does not declare).
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

      # Native (non-docker) vLLM v0.27.1 + DFlash2 K7 all-NVFP4 overlays: the
      # pinned vLLM wheel with the community Python overlays applied, on
      # python312. The undockerified Qwen3.8 DFlash2 engine. Exposed the same
      # way as SGLang: a flake package (testable in isolation) and a nixpkgs
      # overlay so the NixOS module can consume pkgs.vllmDflash2.
      # The FlashInfer JIT (XQA decode kernel) needs a full CUDA toolkit
      # (nvcc + cicc/nvvm); the pip nvidia-cuda-nvcc wheel ships only the
      # nvcc driver, so the toolkit comes from nixpkgs. It is unfree (CUDA
      # EULA), so enable that narrowly for this one input rather than for the
      # whole flake pkgs.
      cudaToolkitPkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      vllmDflash2Pkg =
        pkgs.callPackage ./hosts/desktop/llm/vllm/dflash2-package.nix {
          cudaToolkit = cudaToolkitPkgs.cudaPackages_13.cudatoolkit;
        };

      # llama.cpp router server (pinned flakeless source + CUDA + sleep-exit
      # patch). Built against the unfree-enabled pkgs (the CUDA toolchain is
      # unfree, exactly as the vLLM DFlash2 runtime), exposed both as a flake
      # package (testable in isolation) and via a nixpkgs overlay so the NixOS
      # module can consume pkgs.llama-cpp. `nix flake update llama-cpp`
      # re-pins the source to the newest master commit.
      llama-cppPkg = cudaToolkitPkgs.callPackage ./hosts/desktop/llm/llamacpp/package.nix {
        src = inputs.llama-cpp;
      };

      # Bonsai fork build: the same recipe (CUDA + sleep-exit patch) pointed at
      # the PrismML-Eng fork source, with the fork's npmDepsHash and the
      # fork-specific sleep-exit patch (the fork's server-context.cpp shifted
      # the patch context, so the stock patch no longer applies). Re-pinning
      # the fork may require updating npmDepsHash here — see the "got:
      # sha256-..." note in package.nix.
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
          agents-md =
            pkgs.callPackage ./home/llm/agents-gen/agents-md.nix {
              inherit jail-nix llm-agents;
              shared = sharedForAgents;
              inherit userHome;
              # Upstream dsh source (flakeless input); the agents doc renders
              # the jail config, which now builds dsh from this tree.
              dshSrc = inputs.dsh;
            };

          # Local CA + leaf certificate for the Caddy-served *.local service
          # names (see hosts/desktop/local-ca.nix).
          local-services-ca =
            (import ./hosts/desktop/local-ca.nix {
              inherit pkgs;
              lib = nixpkgs.lib;
            }).ca;

          # Pinned WezTerm session-persistence plugin (resurrect.wezterm fork);
          # built here so the artifact is testable in isolation (nix build
          # .#packages.x86_64-linux.wezurrect, --rebuild for reproducibility).
          # Source from the flakeless `wezurrect` input; `nix flake update
          # wezurrect` re-pins it.
          wezurrect = pkgs.callPackage ./home/wezterm/resurrect.nix {
            src = inputs.wezurrect;
            version = inputs.wezurrect.shortRev;
          };

          # SGLang runtime (pinned CUDA wheel assembly on python313). Testable
          # in isolation: nix build .#packages.x86_64-linux.sglang
          sglang = sglangPkg;

          # Native vLLM v0.27.1 + DFlash2 K7 runtime. Testable in isolation:
          # nix build .#packages.x86_64-linux.vllm-dflash2
          vllm-dflash2 = vllmDflash2Pkg;

          # llama.cpp router server (pinned flakeless source + CUDA +
          # sleep-exit patch). Testable in isolation:
          # nix build .#packages.x86_64-linux.llama-cpp
          llama-cpp = llama-cppPkg;

          # llama.cpp Bonsai fork (PrismML-Eng) for the Ternary-Bonsai-2-27B
          # ternary models. Testable in isolation:
          # nix build .#packages.x86_64-linux.llama-cpp-bonsai
          llama-cpp-bonsai = llama-cpp-bonsaiPkg;

          # Archipelago Multi-Game Randomizer and Server (see let-block).
          # Testable in isolation: nix build --no-link --print-out-paths
          # .#packages.x86_64-linux.archipelago (--no-link is required: on
          # nix 2.34 --print-out-paths does NOT imply it, and without it the
          # build drops a result symlink in the repo root).
          archipelago = archipelagoPkg;

          # Archipelago Python env built from the uv.lock via uv2nix (see
          # let-block). Testable in isolation:
          # nix build --no-link --print-out-paths
          # .#packages.x86_64-linux.archipelago-uv-env
          archipelago-uv-env = archipelagoUvEnv;

          # knife: reverse engineer's binary Swiss-army knife (see
          # home/llm/tools/knife.nix). Testable in isolation:
          # nix build --no-link --print-out-paths .#packages.x86_64-linux.knife
          knife = pkgs.knife;

          # graphify: codebase -> knowledge graph + `graphify-mcp` stdio MCP
          # server (see home/llm/tools/graphify.nix). Testable in isolation:
          # nix build --no-link --print-out-paths .#packages.x86_64-linux.graphify
          graphify = pkgs.graphify;

          # graphlore: richer third-party MCP server that wraps graphify's graph
          # (see home/llm/tools/graphlore.nix). Testable in isolation:
          # nix build --no-link --print-out-paths .#packages.x86_64-linux.graphlore
          graphlore = pkgs.graphlore;

          # echarts: interactive chart library; renders an option (JSON) to a
          # self-contained HTML file (see home/llm/tools/echarts.nix). Built from
          # the flakeless `echarts` input; `nix flake update echarts` re-pins it.
          # Testable in isolation:
          # nix build --no-link --print-out-paths .#packages.x86_64-linux.echarts
          echarts = pkgs.echarts;

          # bend: dependently typed affine language that blocks AI mistakes via
          # proof (see home/llm/tools/bend.nix). Testable in isolation:
          # nix build --no-link --print-out-paths .#packages.x86_64-linux.bend
          bend = pkgs.bend;

          # difftastic: structural diff that understands syntax (see
          # home/llm/tools/difftastic.nix). Testable in isolation:
          # nix build --no-link --print-out-paths
          # .#packages.x86_64-linux.difftastic
          difftastic = pkgs.difftastic;

          # TEMPORARY (minuspod 2.97.4 re-pin verification): removed once the
          # isolated build passes. Uses allowUnfree pkgs because the CUDA
          # ctranslate2 core is unfree (the system pkgs sets allowUnfree).
          minuspod = let
            pkgsU = import inputs.nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
            m = import ./home/minuspod.nix {
              pkgs = pkgsU;
              lib = nixpkgs.lib;
              inherit inputs;
            };
          in builtins.elemAt m.home.packages 0;

          # Tether — Linux + iPhone Continuity bridge (upstream package).
          tether = inputs.tether.packages.${system}.default;

          # Tether's Firefox OTP-autofill add-on: upstream bundles it as a .zip
          # under share/tether/extensions/; home-manager's firefox module wants
          # a <id>.xpi under share/mozilla/extensions/{ec8030f7-...}/ (the NUR
          # layout), so repack it there.
          tether-firefox-extension = pkgs.runCommand "tether-firefox-extension-xpi" {
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

              # Provide the locally patched librepods package under the same
              # attribute name consumed by hosts/desktop/librepods/default.nix
              # (pkgs.librepods), plus the system-tray indicator
              # (pkgs.librepodsTray).
              (final: prev: {
                librepods = librepods;
                librepodsTray = librepodsTray;
              })

              # Provide the locally built SGLang runtime under the attribute
              # name consumed by hosts/desktop/llm/sglang/default.nix
              # (pkgs.sglang).
              (final: prev: {
                sglang = sglangPkg;
              })

              # Provide the locally built Archipelago runtime under the
              # attribute name consumed by hosts/desktop/archipelago/
              # module.nix (pkgs.archipelago) and home/packages.nix.
              (final: prev: {
                archipelago = archipelagoPkg;
              })

              # Provide the native vLLM DFlash2 runtime under the attribute
              # name consumed by hosts/desktop/llm/vllm/qwen38-dflash2.nix
              # (pkgs.vllmDflash2).
              (final: prev: {
                vllmDflash2 = vllmDflash2Pkg;
              })

              # Provide the locally built llama.cpp router under the attribute
              # name consumed by hosts/desktop/llm/llamacpp/default.nix
              # (pkgs.llama-cpp).
              (final: prev: {
                llama-cpp = llama-cppPkg;
              })

              # Provide the locally built llama.cpp Bonsai fork under the
              # attribute name consumed by the Bonsai router in
              # hosts/desktop/llm/llamacpp/default.nix (pkgs.llama-cpp-bonsai).
              (final: prev: {
                llama-cpp-bonsai = llama-cpp-bonsaiPkg;
              })

              # Tether — Linux + iPhone Continuity bridge (upstream overlay).
              tether.overlays.default

              # headroom-ai: context compression layer for the jailed LLM
              # agents. Same single definition as the base `pkgs` in the
              # let-block (home/llm/tools/overlay.nix), so the standalone
              # agents-md doc build can evaluate jails.nix.
              headroomOverlay

              # Force Discord into X11 (XWayland) mode. On this Plasma 6 Wayland
              # + NVIDIA setup, Discord's Wayland renderer SIGSEGVs at launch:
              # Chromium 148 auto-selects Wayland when WAYLAND_DISPLAY is set.
              # The nixpkgs wrapper appends commandLineArgs last, so
              # --ozone-platform=x11 overrides the auto-detected platform.
              # Applying it as an overlay (rather than in home.packages) means
              # both the home.packages entry and the autostart (home/discord.nix),
              # which both reference pkgs.discord, get the flag.
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

              # Shared model/LSP catalog + config renderer, used by both home-manager
              # modules (b's home and the llm agent user's home).
              shared = import ./home/llm/catalog.nix {
                inherit lib pkgs jail-nix;
              };

              deepseekSecret = config.age.secrets.deepseek-api-key.path;

              # NVIDIA driver package (libcuda.so.1). Passed to home/minuspod.nix
              # so the minuspod user service can dlopen the driver stub for CUDA
              # whisper (not in the ldconfig cache — see whisper-service).
              nvidiaDriver = config.boot.kernelPackages.nvidiaPackages.latest;

              # Pinned Archipelago source inputs (the archipelago meta-flake's
              # nested inputs), passed to the archipelago home-manager modules
              # so they can build the apworld/mod zips from source (see
              # zip-from-source.nix). `nix flake update archipelago` re-pins
              # these; the zips follow (no manual re-pin, no build-time network).
              archipelagoSources = {
                balatroap = inputs.archipelago.outputs.archipelagoInputs.balatroap;
                sts2 = inputs.archipelago.outputs.archipelagoInputs.sts2;
                universal-tracker = inputs.archipelago.outputs.archipelagoInputs."universal-tracker";
              };
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
