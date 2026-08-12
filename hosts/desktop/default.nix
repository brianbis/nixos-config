{ ... }:

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