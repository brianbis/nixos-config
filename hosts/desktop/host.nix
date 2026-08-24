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
  boot.kernelModules = [ "tpm_tis" "tpm_crb" ];
  # Load the TPM modules in the initrd too: the agenix age-key unseal runs as
  # an initrd activation script (hosts/desktop/security.nix) before the main
  # systemd starts, so the TPM device must exist by then.
  boot.initrd.kernelModules = [ "tpm_tis" "tpm_crb" ];
  security.tpm2.enable = true;
  security.tpm2.abrmd.enable = true;
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

  # Real homes should be 0700 (NixOS creates them 0755). llm's: b cannot snoop
  # the agent's tool state. b's: it holds unencrypted resurrect session state
  # (terminal scrollback, dotfiles/wezterm.lua) — keep it out of reach of the
  # llm agent and other users. The llm group is declared in security.nix; b
  # has no user-private group, so its home is grouped to the always-present
  # `users` group (irrelevant for a 0700 dir — only owner + mode matter).
  # mkAfter so these run after the users module's home-creation rule in the
  # same tmpfiles pass.
  systemd.tmpfiles.rules = [
    (lib.mkAfter "z ${users.b.homeDirectory} 0700 ${users.b.username} users -")
    (lib.mkAfter "z ${users.llm.homeDirectory} 0700 ${users.llm.username} ${users.llm.username} -")
  ];
}
