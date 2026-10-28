{
  description = ''
    NixOS host 'yzerd' — the physical box (Option A: PVE retired, NixOS native).

    Self-contained sub-flake in the same shape as hosts/nixos-vm: the repo re-exports
    it through the path: input 'yz-native', and this directory alone evaluates
    standalone, which is what the live ISO needs — after nvme0n1p3 is wiped the ONLY
    copy of this tree is on the Ventoy stick (/mnt/vtoy/repo-yzerd), mounted by the
    installation system. Keep it dependency-light on that account: the root flake's
    inputs (sourcehut:, NUR, nix-craftapps) cannot be fetched from a fresh live
    environment, so this sub-flake pins nixpkgs by exact revision only.

    The strata inputs added below stay inside that rule: they are pinned (a tag,
    three toolchain repos, one hashed fetchFromGitHub) and this directory carries
    its own copy of the uv workspace (llm/strata/uv) rather than pointing into
    hosts/desktop — so the stick copy still evaluates on its own, it just needs
    network for the engine/venv fetches like any other nixpkgs use.
  '';

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/f20cd90e28fe0403873f473b29e42662cd86e8c4";

  # Tag-pinned on the last 0.1.x release, same reasoning as the root flake: the
  # 0.2.x line broke the running stack, and a ref-less url lets any bare `nix
  # flake update` jump this back to refs/heads/main. A *tag* ref stays put.
  inputs.strata.url = "github:Niko1221/Strata/v0.1.45";
  inputs.strata.flake = false;

  # The uv2nix toolchain for strata-serve-env (the server's interpreter), each
  # following the nixpkgs pin above so the venv is reproducible against it.
  inputs.pyproject-nix.url = "github:pyproject-nix/pyproject.nix";
  inputs.pyproject-nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.uv2nix.url = "github:pyproject-nix/uv2nix";
  inputs.uv2nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.pyproject-build-systems.url = "github:pyproject-nix/build-system-pkgs";
  inputs.pyproject-build-systems.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, ... }@inputs:
    let
      system = "x86_64-linux";

      # Work around a nixpkgs CUDA cccl patch that is already present in the
      # CCCL 13.3.3.4.1 tarball (applying it again fails as a "Reversed patch");
      # disable the cudaOlder gate. Same overlay the root flake carries.
      ccclPatchWorkaround = final: prev: {
        cudaPackages_13_2 = prev.cudaPackages_13_2.overrideScope (f: p: {
          cccl = p.cccl.override { cudaOlder = _: false; };
        });
        cudaPackages_13_3 = prev.cudaPackages_13_3.overrideScope (f: p: {
          cccl = p.cccl.override { cudaOlder = _: false; };
        });
      };

      # allowUnfree: the CUDA toolkit (and nvidia.nix's driver) are
      # unfreeRedistributable and nixpkgs refuses to evaluate them otherwise —
      # the same gate hosts/yzerd/nvidia.nix opens for the driver.
      cudaPkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ ccclPatchWorkaround ];
      };

      # llama.cpp at the commit Strata's setup.py pins (its LLAMA_CPP_COMMIT):
      # the ggml CPU backend the engine links (i-quant expert kernels). Hash is
      # of the unpacked tree (fetchzip recursiveHash), per this repo's
      # fetchFromGitHub convention.
      strataLlamaCpp = nixpkgs.lib.fetchFromGitHub {
        owner = "ggml-org";
        repo = "llama.cpp";
        rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
        hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
      };

      # sm_89 (this box's RTX 4090), not the desktop's sm_120.
      strataEnginePkg = cudaPkgs.callPackage ./llm/strata/package.nix {
        src = inputs.strata;
        llamaCpp = strataLlamaCpp;
        cudaToolkit = cudaPkgs.cudaPackages_13.cudatoolkit;
      };

      # The server's interpreter, built from the committed uv workspace copy in
      # this directory (llm/strata/uv): keep the deps in sync with upstream the
      # same way hosts/desktop/llm/strata/uv does — `uv lock` in that dir, commit
      # both files. sourcePreference = "wheel" for prebuilt wheels.
      strataWorkspace = inputs.uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = ./llm/strata/uv;
      };
      strataOverlay = strataWorkspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };
      strataPythonSet = (cudaPkgs.callPackage inputs.pyproject-nix.build.packages {
        python = cudaPkgs.python313;
      }).overrideScope (cudaPkgs.lib.composeManyExtensions [
        inputs.pyproject-build-systems.overlays.wheel
        strataOverlay
      ]);
      # The .strata-pip.json stamp: setup.py's runtime pip step reads
      # requirements.txt and its guard is a bare importability test, so without
      # this stamp it pip-installs into the read-only store (colorama is
      # win32-gated upstream but has to be importable here).
      strataServeEnv = (strataPythonSet.mkVirtualEnv "strata-serve-env"
        strataWorkspace.deps.default).overrideAttrs (_: {
        postInstall = ''
          echo '["colorama", "cmake", "jinja2", "numpy", "ninja", "pillow", "psutil", "pyyaml", "regex", "requests", "tqdm"]' > $out/.strata-pip.json
        '';
      });

      strataVisionAppPkg = cudaPkgs.callPackage ./llm/strata/vision.nix {
        src = inputs.strata;
        llamaCpp = strataLlamaCpp;
        engine = strataEnginePkg;
        cudaToolkit = cudaPkgs.cudaPackages_13.cudatoolkit;
      };
    in
    {
      nixosConfigurations.yzerd = nixpkgs.lib.nixosSystem {
        # Bound literally (not config.system) so the flake evaluates standalone
        # via `nixos-rebuild --flake /mnt2/repo-yzerd#yzerd` on the live system.
        inherit system;
        modules = [
          ./default.nix
          ./nvidia.nix
          ./llm/strata/default.nix
          # The module reads its packages off pkgs (same contract the desktop's
          # module uses), so they are injected here rather than duplicated there.
          ({ config, ... }: {
            nixpkgs.overlays = [ (final: prev: {
              strata-vision-app = strataVisionAppPkg;
              strata-serve-env = strataServeEnv;
            }) ];
          })
        ];
      };

      # Narrow checks without a system rebuild (nix build --impure --no-link
      # --print-out-paths .#packages.x86_64-linux.<name>): the engine build is
      # the slow, hardware-critical step — its CUDA arch has to match the card.
      packages.${system}."strata-engine-sm89" = strataEnginePkg;
      packages.${system}."strata-vision-app-sm89" = strataVisionAppPkg;
      packages.${system}."strata-serve-env" = strataServeEnv;
    };
}
