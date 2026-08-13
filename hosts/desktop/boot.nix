{ ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.kernelParams = [
    "pcie_aspm=powersave"
    "nvme_core.default_ps_max_latency_us=5500"
    "intel_pstate=active"
  ];
}
