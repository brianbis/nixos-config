{ lib, ... }:

{
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
  # TLP periodically re-asserts its governor (powersave on AC), which made the
  # CPU governor flap mid-audio-stream. hushmic-cpu-boost (audio-cpu-watcher,
  # see hushmic-scheduler.nix) is the single owner of governor + EPP.
  services.tlp.enable = false;
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
