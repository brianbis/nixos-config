{ config, ... }:

{
  services.xserver.videoDrivers = [
    "nvidia"
  ];

  hardware.graphics.enable = true;

  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = true;
    open = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
  };
}