{ lib, pkgs, ... }:

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
  # Keep USB input devices (keyboard/mouse) awake: the default autosuspend
  # drops them after idle, causing input lag on wake.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="on"
    # intel_pstate + HWP locks cpufreq sysfs at 644 after driver init, so the
    # hushmic-audio-cores oneshot (sysinit.target) runs too late for cpu7. A
    # udev rule fires at cpufreq device registration (before any systemd
    # service), which is the only window where scaling_governor is writable.
    # If HWP re-locks it, the core-pin guard logs it once and gives up.
    ACTION=="add", SUBSYSTEM=="cpufreq", KERNEL=="cpu[67]", ATTR{scaling_governor}="performance"
    ACTION=="add", SUBSYSTEM=="cpufreq", KERNEL=="cpu[67]", ATTR{energy_performance_preference}="performance"
  '';
  # TLP periodically re-asserts its governor (powersave on AC), which made the
  # CPU governor flap mid-audio-stream. hushmic-audio-cores + hushmic-core-pin
  # (see hushmic/scheduler.nix) own the audio cores (cpu6/7); steam-gaming-mode
  # (see steam.nix) owns the all-core gaming boost.
  services.tlp.enable = false;
  # thermald is left in place for thermal protection, but its actions are
  # restricted to max-frequency capping only. The default config also writes
  # cpufreq governor/EPP on thermal events, which flapped the hushmic audio
  # cores (cpu6/7) that hushmic-audio-cores owns (see hushmic/scheduler.nix).
  services.thermald = {
    enable = true;
    configFile = pkgs.writeText "thermald.conf" ''
      [DEFAULT]
      platform-id=0

      [THERMAL-0]
      BROKEN-GOVERNOR=1
      GOVERNOR=
      EPP=
      MAXIMUM-PROC-FREQ=4500000
    '';
  };

  users.users."b" = {
    isNormalUser = true;
    description = "b";
    extraGroups = [
      "networkmanager"
      "wheel"
      "dialout"
      "llm"
    ];
    # Headless user session: keeps b's systemd user manager (and thus the
    # hushmic user service + PipeWire) running without a graphical login.
    # Without this, `systemctl --user` from root fails and pw-dump cannot
    # reach the session socket.
    linger = true;
  };
}
