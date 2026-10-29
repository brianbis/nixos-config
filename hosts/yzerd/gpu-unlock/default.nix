# gpu-unlock (github:Zagitta/gpu-unlock v2.0.0) — clears NVIDIA's half-rate
# tensor-core cap on GeForce cards by patching the GSP boot images before the
# `nvidia` kdriver binds the card. That ordering is the whole reason this lives
# in the initrd: gpu_unlock must run BEFORE nvidia, and nvidia is not in the
# initrd at all (hardware.nix declares it for stage 2), so gpu_unlock alone is
# the initrd module and the card stays locked until stage 2 loads nvidia.
#
# gpu_unlock_init() returns 0 without effect unless gpu_unlock.targets= appears
# on the kernel command line, so boot.kernelParams is the opt-in switch.
# The module opens its blobs as "gpu-unlock/610.43.03/<name>.bin" (kernel/gpu_unlock/
# recipes.h GU_FW_* macros) relative to the kernel firmware search dirs, i.e.
# /lib/firmware/gpu-unlock/610.43.03/ — inside the initrd, not on the disk root.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption types;

  # gpu-unlock patches the GSP boot images that the open NVIDIA kdriver binds, so
  # enabling it next to no NVIDIA userland is a config mistake. This is a bool so
  # mkIf can consume it: the throw is the abort, and it only gets forced when the
  # feature is on (mkIf's guard short-circuits on `en`). lib.assertMsg would not do
  # it — that returns its *message* when the condition holds, not a bool. Nix's
  # unary `!` binds looser than `or`, so bare `! a or b` parses as `!(a or b)` and
  # turned a healthy config into an abort; the negation is parenthesised and the
  # disjunction spelled `||`.
  nvidiaSanity = ( ! config.gpuUnlock.enable ) || config.hardware.nvidia.enabled;
  nvidiaGuard = if nvidiaSanity then true else throw "gpuUnlock.enable without hardware.nvidia.enabled: gpu-unlock patches the GSP boot images that the open NVIDIA kdriver then binds — there is nothing to unlock without it.";

  en = config.gpuUnlock.enable;

  modulePkg = pkgs.callPackage ./module.nix {
    # The booted kernel derivation, not pkgs.linuxPackages.kernel: its randstruct
    # seed and any config.boot.kernelPatches have to match or the .ko cannot load.
    kernel = config.boot.kernelPackages.kernel;
    src = pkgs.gpu-unlock-src;
  };
in
{
  # This nixpkgs pin demands explicit module syntax: declarations under `options`
  # and config values under `config`. A bare `gpuUnlock.enable = mkOption ...`
  # evaluates as a *definition* of the non-existent option `gpuUnlock`, and the
  # eval dies with "The option `gpuUnlock' does not exist".
  options.gpuUnlock.enable = mkOption {
    type = types.bool;
    default = true;
    description = ''
      Unlock full-rate tensor cores on this card with gpu-unlock. Ada
      (RTX 4090 / AD102) is labelled Experimental upstream; Ampere is the
      stable tier. Reboot-gated: it changes kernelParams, the initrd, and
      the module set, so a plain switch does not take it.
      Guarded at eval: enabling it without hardware.nvidia.enabled aborts.
    '';
  };

  options.gpuUnlock.targets = mkOption {
    type = types.enum [ "all" ];
    default = "all";
    description = ''
      gpu_unlock.targets= kernel parameter: "all" or a comma-separated list
      of PCI addresses. One card on this box, so "all" is the whole surface.
    '';
  };

  config.boot.extraModulePackages = mkIf (en && nvidiaGuard) [ modulePkg ];

  # stage-1 loads gpu_unlock before anything touches the card; the loaded
  # instance survives the pivot, which is also what keeps its
  # gpu_unlock_pm_notify (PM_POST_SUSPEND, priority 1) available after resume.
  config.boot.initrd.kernelModules = mkIf en [ "gpu_unlock" ];

  # The blobs go in through hardware.firmware, NOT through an initrd contents
  # entry: boot.initrd.systemd.contents cannot create /lib/firmware/... because
  # the initrd's /lib is a symlink into the read-only modules-closure store dir
  # (stage-1.nix:380 object = "${modulesClosure}/lib"), and make-initrd-ng dies
  # with "failed to create directories to ./root//lib/firmware/gpu-unlock".
  # What does work is nixpkgs' own firmware plumbing: this .ko declares its 16
  # blobs in modinfo (-F firmware), and modules-closure.sh copies every
  # modinfo-declared blob out of the merged $hardware.firmware/lib/firmware tree
  # into $out/lib/firmware/... of the shrunk module tree — which is exactly the
  # dir the initrd symlinks at /lib. That is the same route nvidia.nix:784 uses
  # for the driver's own GSP blobs. hardware.firmware's `apply` buildEnv-merges
  # our package with linux-firmware (pathsToLink = [ "/lib/firmware" ],
  # ignoreCollisions = true) and compressFirmwareZstd pre-compresses the
  # 109 MB of blobs to .zst, which the devm loader reads transparently.
  config.hardware.firmware = mkIf en [ pkgs.gpu-unlock-firmware ];

  # cmdline is the opt-in switch: gpu_unlock_init() is a no-op without it.
  config.boot.kernelParams = mkIf en [ "gpu_unlock.targets=${config.gpuUnlock.targets}" ];
}
