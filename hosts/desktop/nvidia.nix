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
    # Build 610.57.04 with mkDriver (nvidia-packages' own constructor) and the
    # argset nixpkgs shipped as `new_feature` on 2026-09-09 (rev 5052d7cc), so
    # settings/persistenced/firmware sub-derivations come out 610-hashed.
    # overrideAttrs on the built 615 drv does NOT work: generic() bakes
    # 615's settings/persistenced sha256s into those sub-derivations at call
    # time, so the 610 downloads fail hash verification (build error:
    # "hash mismatch ... specified: <615 hash> got: <610 hash>").
    # When nixpkgs new_feature carries a 616/617 Linux build, replace this
    # whole block with: package = config.boot.kernelPackages.nvidiaPackages.latest;
    package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      version = "610.57.04";
      sha256_64bit = "sha256-suk1xmuDuwDAyFe8jg7g/VLekoa0DJzB7sKafOfrEW0=";
      sha256_aarch64 = "sha256-QCefrMBCmpOwuOyXv1k5Gj0iB2CYlPgnG3JToUw/j54=";
      openSha256 = "sha256-rQHOOOY4KL92Ww3KDwh+j4eGU7oNAH8LutZC5wmFnPo=";
      settingsSha256 = "sha256-ZEMo8I8Zc2Tq6RVDNYpAH+f094dUaZiBqO+5f6lIjRI=";
      persistencedSha256 = "sha256-aXmD2VY1RLlgAnlHhOUMWzvMyhI6JTClcFLm4imF/mA=";
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
