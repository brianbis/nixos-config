{ lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./audio.nix
    ./bluetooth.nix
    ./boot.nix
    ./crush-system.nix
    ./monitor
    ./networking.nix
    ./nvidia.nix
    ./packages.nix
    ./plasma.nix
    ./security.nix
    ./steam.nix
    ./vllm.nix
    ./llamacpp.nix
  ];

  # Machine Identity & Baseline
  networking.hostName = "nixos";
  time.timeZone = "America/Phoenix";
  system.stateVersion = "26.05";

  # Nix Configuration
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # Locale & User Settings
  i18n.defaultLocale = "en_US.UTF-8";
  services.lact.enable = true;
  services.power-profiles-daemon.enable = false;
  services.tlp = {
    enable = true;
    settings = {
      CPU_SCALING_GOVERNOR_ON_AC = "powersave";
      CPU_ENERGY_PERF_POLICY_ON_AC = "balance_power";
      PLATFORM_PROFILE_ON_AC = "balanced";
    };
  };
  services.thermald.enable = true;
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="auto"
  '';

  users.users."b" = {
    isNormalUser = true;
    description = "b";
    extraGroups = [
      "networkmanager"
      "wheel"
      "dialout"
      "llm"
    ];
  };
}