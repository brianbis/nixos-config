{ lib, pkgs, ... }:

let
  users = import ../../home/users.nix;
in
{
  networking.hostName = "nixos";
  time.timeZone = "America/Phoenix";
  system.stateVersion = "26.05";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

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
    ACTION=="add", SUBSYSTEM=="cpu", KERNEL=="cpu[67]", ATTR{cpufreq/scaling_governor}="performance"
    ACTION=="add", SUBSYSTEM=="cpu", KERNEL=="cpu[67]", ATTR{cpufreq/energy_performance_preference}="performance"
  '';
  # TLP periodically re-asserts its governor (powersave on AC), which made the
  # CPU governor flap mid-audio-stream. hushmic-audio-cores + hushmic-core-pin
  # (see hushmic/scheduler.nix) own the audio cores (cpu6/7); steam-gaming-mode
  # (see steam.nix) owns the all-core gaming boost.
  services.tlp.enable = false;

  users.users."${users.b.username}" = {
    isNormalUser = true;
    description = users.b.username;
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

  # Jailed LLM agent user. Owns the "system" jail variants' home
  # (/home/llm) and the flake repo (/etc/nixos): the system jails run as
  # this user via `sudo -u llm` instead of as root, so a jail misconfig can
  # at most write the repo and the agent's own home. The `llm` group
  # (hosts/desktop/security.nix) is an extra group (the primary group is
  # `users`) and grants read access to the agenix secret (root:llm 0440)
  # and the systemd journal (root:llm 2755). No password and no SSH keys:
  # unreachable except via `sudo -u llm`.
  users.users."${users.llm.username}" = {
    isNormalUser = true;
    description = "Jailed LLM agent (system jail)";
    home = users.llm.homeDirectory;
    shell = pkgs.bash;
    extraGroups = [ "llm" ];
  };

  # The flake repo is owned by the llm agent user so the system jails (run
  # as llm) can edit it; root keeps full write access. Re-asserted at every
  # switch so files created as root (e.g. `sudo nix flake update`) stay
  # writable by the agent. chown does not touch mtimes, so git's index
  # stays valid.
  system.activationScripts.nixosRepoOwnership.text = ''
    chown -R ${users.llm.username}:${users.llm.username} /etc/nixos
  '';

  # A real home should be 0700 (NixOS creates homes 0755): b cannot snoop
  # the agent's tool state. mkAfter so this runs after the users module's
  # home-creation rule in the same tmpfiles pass.
  systemd.tmpfiles.rules = [
    (lib.mkAfter "z ${users.llm.homeDirectory} 0700 ${users.llm.username} ${users.llm.username} -")
  ];
}
