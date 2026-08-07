{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./audio.nix
    ./bluetooth.nix
    ./boot.nix
    ./monitor.nix
    ./networking.nix
    ./nvidia.nix
    ./packages.nix
    ./plasma.nix
    ./security.nix
    ./steam.nix
    ./vllm.nix
  ];

  # Machine Identity & Baseline
  networking.hostName = "nixos";
  time.timeZone = "America/Phoenix";
  system.stateVersion = "26.05";

  # Nix Configuration
  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Root-readable state root for the "system" jail variants (see
  # home/llm.nix's systemStateDir). Owned by the user so the home activation
  # can seed it, and under /var/lib so the root-run jails can mount it without
  # traversing the user's 700 home dirs.
  systemd.tmpfiles.rules = [
    "d /var/lib/crush-system 0755 b users - -"
    "d /var/lib/crush-system/.config 0755 b users - -"
    "d /var/lib/crush-system/.config/crush 0755 b users - -"
    "d /var/lib/crush-system/.config/crush/hooks 0755 b users - -"
    "d /var/lib/crush-system/.local 0755 b users - -"
    "d /var/lib/crush-system/.local/share 0755 b users - -"
    "d /var/lib/crush-system/.local/share/crush 0755 b users - -"
  ];

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