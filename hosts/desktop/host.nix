{ config, lib, pkgs, ... }:

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

  # pre-commit's git (cloning hook repos) and the `nix` client run in an
  # environment whose /nix/store view may not include the system store, so
  # the default /etc/ssl/certs CA *symlinks* (into the system store) dangle
  # and TLS verification fails. Install the system's final CA bundle
  # (security.pki.caBundle — same file the system symlinks into
  # /etc/ssl/certs) as a REAL file at a stable path: `mode = "0644"` makes
  # the /etc installer copy it instead of symlinking it, so it resolves
  # regardless of which store view the environment sees. Point git at it
  # via the system gitconfig.
  environment.etc."ca-bundle/git-ca.crt" = {
    source = config.security.pki.caBundle;
    mode = "0644";
  };
  environment.etc."gitconfig" = {
    text = ''
      [http]
        sslCAInfo = /etc/ca-bundle/git-ca.crt
    '';
    mode = "0644";
  };

  # The pre-commit hooks (.pre-commit-config.yaml) run the language formatters
  # pinned to $NIXPKGS — the system's nixpkgs source — so their versions track
  # the flake's lock instead of a floating registry default. The jails set it
  # per session (home/llm/jails.nix); declare it system-wide as well so
  # `just fmt` also works in host shells, where no jail environment exists.
  environment.sessionVariables.NIXPKGS = pkgs.path;

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
    # intel_pstate + HWP locks cpufreq sysfs (644) after driver init, so
    # scaling_governor is writable only at udev device registration — before
    # any systemd service (e.g. hushmic-audio-cores) runs.
    ACTION=="add", SUBSYSTEM=="cpu", KERNEL=="cpu[67]", ATTR{cpufreq/scaling_governor}="performance"
    ACTION=="add", SUBSYSTEM=="cpu", KERNEL=="cpu[67]", ATTR{cpufreq/energy_performance_preference}="performance"
  '';
  # TLP re-asserts its own governor (powersave on AC), conflicting with the
  # per-core policy: hushmic-audio-cores owns cpu6/7 and steam-gaming-mode owns
  # the all-core gaming boost.
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
    # Headless user session: keeps b's user manager (hushmic user service +
    # PipeWire) running without a graphical login; without it pw-dump cannot
    # reach the session socket.
    linger = true;
  };

  # Jailed LLM agent user: the "system" jail variants run as llm instead of
  # root, so a jail misconfig can at most write the repo and the agent home.
  # No password or SSH keys — unreachable except via `sudo -u llm`.
  users.users."${users.llm.username}" = {
    isNormalUser = true;
    description = "Jailed LLM agent (system jail)";
    home = users.llm.homeDirectory;
    shell = pkgs.bash;
    extraGroups = [ "llm" ];
  };

  # The flake repo is owned by llm so the system jails can edit it; re-asserted
  # at every switch so root-created files stay agent-writable. chown does not
  # touch mtimes, so git's index stays valid.
  system.activationScripts.nixosRepoOwnership.text = ''
    chown -R ${users.llm.username}:${users.llm.username} /etc/nixos
    # b is in the llm group; group-writable so b can open and edit
    # agent-linked files directly.
    chmod -R g+rwX /etc/nixos
  '';

  # NixOS creates homes 0755; force 0700 so b cannot snoop the agent's tool
  # state and the llm agent cannot read b's unencrypted session state. mkAfter
  # so these run after the users module's home-creation rule.
  systemd.tmpfiles.rules = [
    (lib.mkAfter "z ${users.b.homeDirectory} 0700 ${users.b.username} users -")
    (lib.mkAfter "z ${users.llm.homeDirectory} 0700 ${users.llm.username} ${users.llm.username} -")
  ];
}
