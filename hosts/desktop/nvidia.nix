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
    # Pin 610.57.04: nixpkgs `latest` (615.71.09) deadlocks the DP link when a
    # monitor wakes from DPMS standby under KWin Wayland (NVIDIA/open-gpu-
    # kernel-modules#1371) — monitors never return, CUDA clients hang. NVIDIA
    # shipped the R615 DP-wake fix in 617.14 (Windows GRD, 2026-09-22); the
    # Linux build of that cycle is not public yet. 610.57.04 was the known-good
    # driver here until the 2026-09-25 flake regen. Revert to `latest` once the
    # 616/617 Linux GTD lands in nixpkgs new_feature.
    # Note: `src` must be overridden too — generic.nix computes it from its
    # frozen `version` arg; overriding only `version` relabels the 615.71.09
    # tarball (nixpkgs warns: "overridden with `version` but not `src`").
    # 610.57.04 hashes are nixpkgs' own (5052d7cc, nixos-unstable 2026-09-09).
    package = config.boot.kernelPackages.nvidiaPackages.new_feature.overrideAttrs (final: prev: rec {
      version = "610.57.04";
      sha256_64bit = "sha256-suk1xmuDuwDAyFe8jg7g/VLekoa0DJzB7sKafOfrEW0=";
      sha256_aarch64 = "sha256-QCefrMBCmpOwuOyXv1k5Gj0iB2CYlPgnG3JToUw/j54=";
      openSha256 = "sha256-rQHOOOY4KL92Ww3KDwh+j4eGU7oNAH8LutZC5wmFnPo=";
      settingsSha256 = "sha256-ZEMo8I8Zc2Tq6RVDNYpAH+f094dUaZiBqO+5f6lIjRI=";
      persistencedSha256 = "sha256-aXmD2VY1RLlgAnlHhOUMWzvMyhI6JTClcFLm4imF/mA=";
      src = pkgs.fetchurl {
        urls = [
          "https://us.download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
          "https://download.nvidia.com/XFree86/Linux-x86_64/${version}/NVIDIA-Linux-x86_64-${version}.run"
        ];
        sha256 = sha256_64bit;
      };
    });
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
