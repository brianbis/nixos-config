{ config, pkgs, ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];

  boot.kernelParams = [
    "nvidia.NVreg_PreserveVideoMemoryAllocations=1"
  ];


  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [ nvidia-vaapi-driver ];
  };
  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = true;
    open = true;
    powerManagement.enable = true;
    package =
      (config.boot.kernelPackages.nvidiaPackages.latest.overrideAttrs (old: {
        # patchelf 0.19.2 mangles the .run binaries it patches (one pass
        # sets interpreter + rpath), so nvidia-smi & co segfault in the
        # loader (NixOS/nixpkgs#576412, NixOS/patchelf#674). Shadow the
        # pre-regression patchelf for this derivation only. Drop this pin
        # once the pinned nixpkgs contains NixOS/nixpkgs#576397 — merged to
        # master 2026-10-21, but nixos-unstable (this pin's ref) still sat
        # at 02c087f3 / 2026-10-20 without it as of 2026-10-23.
        nativeBuildInputs = [
          (pkgs.patchelf.overrideAttrs (finalAttrs: _: {
            version = "0.15.2";
            src = pkgs.fetchurl {
              url = "https://github.com/NixOS/patchelf/releases/download/${finalAttrs.version}/patchelf-${finalAttrs.version}.tar.bz2";
              hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
            };
          }))
        ] ++ old.nativeBuildInputs;
      }))
      // {
        open =
          config.boot.kernelPackages.nvidiaPackages.latest.open.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              # nvidia-modeset frees the device twice when a failed resume
              # revokes it while already revoking, oopsing in the PM
              # notifier. Upstream PR NVIDIA/open-gpu-kernel-modules#1395
              # — absent from the 615.78.08 tag (checked R615 tree
              # nvRevokeDevice, no nested-revoke guard).
              (pkgs.fetchpatch {
                name = "nvidia-modeset-ignore-nested-revoke.patch";
                url = "https://github.com/NVIDIA/open-gpu-kernel-modules/commit/5db24a72350ab2679376132ac8e31a06a0950343.patch";
                hash = "sha256-aWzj+3AR7xjvWp5IL5iSNIts0SKp9kT35zgXUINBuhc=";
              })
            ];
          });
      };
  };
  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "nvidia";
    NVD_BACKEND = "direct";
  };
  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia
    libva-utils
  ];
}
