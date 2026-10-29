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

  # gpu-unlock (Zagitta/gpu-unlock), pinned to the commit of main that carries
  # the AD102 port in kernel/gpu_unlock/recipes.c (ad102_v67 — the six-write
  # chain this box's 4090 needs). flake = false: a plain source tree.
  inputs.gpu-unlock.url = "github:Zagitta/gpu-unlock/7eb51bccae0a0b7e599e084d971170e9a1e82d0c";
  inputs.gpu-unlock.flake = false;

  # NOTE the two NVIDIA artifacts gpu-unlock's firmware is rebuilt from are NOT
  # URL inputs: a flake URL input is always fed through the archive importer
  # ("Failed to open archive (Unrecognized archive format)" on the makeself
  # .run, and ?recursive=0 is ignored), so they are hashed builtins.fetchurl
  # calls in the let below instead — same pinning strength, the sha256 lives in
  # this file where a reviewer can see it.

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
      strataLlamaCpp = cudaPkgs.fetchFromGitHub {
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

      # gpu-unlock rebuilds its firmware from two pinned NVIDIA artifacts
      # (upstream Makefile: NV := 610.43.03, INPUTS = the kernel-module source
      # tarball + the .run installer). Hashed builtins.fetchurl: pure at eval,
      # fetched once into the store, and the sha256 is visible here. Both match
      # the copies already on the box in /home/b (sha256sum there agrees).
      nvKernelSource610 = builtins.fetchurl {
        url = "https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz";
        sha256 = "sha256-fhGJI8eiPtw2EU1jJzpG4+BOmvmGlaQiA+esLf6fwdw=";
      };
      nvInstaller610 = builtins.fetchurl {
        url = "https://download.nvidia.com/XFree86/Linux-x86_64/610.43.03/NVIDIA-Linux-x86_64-610.43.03-no-compat32.run";
        sha256 = "sha256-4IRFHbcwpt8p09dPZVdJxNI248lF99lLUgXoQxj+L5A=";
      };

      # gpu-unlock's blobs, rebuilt from the two artifacts above with upstream's
      # own extractors (config-independent, so this is the very derivation the
      # module consumes).
      gpuUnlockFirmwarePkg = cudaPkgs.callPackage ./gpu-unlock/firmware.nix {
        src = inputs.gpu-unlock;
        nvKernelSource = nvKernelSource610;
        nvInstaller = nvInstaller610;
      };

      # Narrow compile check ONLY: the module the system actually builds comes
      # from ./gpu-unlock/default.nix against config.boot.kernelPackages.kernel
      # (randstruct seed + patches must match the booted kernel). This one uses
      # the pin's default kernel package so a compile error surfaces in seconds.
      gpuUnlockKmodCheck = cudaPkgs.callPackage ./gpu-unlock/module.nix {
        src = inputs.gpu-unlock;
        kernel = cudaPkgs.linuxPackages.kernel;
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
          ./gpu-unlock/default.nix
          # gpu-unlock's sources come from the flake inputs (a module cannot see
          # inputs), and the firmware package is config-independent so the flake
          # defines it; only the .ko, which needs config.boot.kernelPackages, is
          # built inside the module.
          ({ config, ... }: {
            nixpkgs.overlays = [ (final: prev: {
              gpu-unlock-src = inputs.gpu-unlock;
              gpu-unlock-firmware = gpuUnlockFirmwarePkg;
            }) ];
          })
          # The CI half: declares flake-eval capability, the git/jq tools the
          # runner needs, the runner itself (./ci-runner.sh), and the state
          # dir whose last-green entry is the CD pointer. Never activates.
          ./ci.nix
        ];
      };

      # Narrow checks without a system rebuild (nix build --impure --no-link
      # --print-out-paths .#packages.x86_64-linux.<name>): the engine build is
      # the slow, hardware-critical step — its CUDA arch has to match the card.
      # One dynamic-attr set: repeated `packages.${system}.x = ...;` lines are
      # separate definitions of the same dynamic attribute and conflict.
      packages.${system} = {
        "strata-engine-sm89" = strataEnginePkg;
        "strata-vision-app-sm89" = strataVisionAppPkg;
        "strata-serve-env" = strataServeEnv;
        "gpu-unlock-firmware" = gpuUnlockFirmwarePkg;
        "gpu-unlock-kmod-check" = gpuUnlockKmodCheck;
      };
    };
}
