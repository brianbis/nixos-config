{ config, lib, pkgs, ... }:

let
  users = import ../../home/users.nix;
in
{
  networking.hostName = "nixos";
  time.timeZone = "America/Phoenix";
  system.stateVersion = "26.11";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Secondary, PERSISTENT build cap. `nix.settings.max-jobs` is a nix-daemon
  # setting (written to /etc/nix/nix.conf, read at daemon start) that caps how
  # many *derivations* build in parallel. It does NOT cap rustc parallelism
  # inside a single cargo build — that is `NIX_BUILD_CORES` (the `--cores`
  # flag), and it is the 24-way rustc fan-out of the heavy local Rust build
  # (librepods: iced/wgpu/winit + bluer) that would OOM this 64 GB box. The
  # `--cores` cap in the justfile (build-flags) is the client-side fix that
  # applies to the very next build. This line is kept only as a persistent
  # default so builds outside the justfile stay bounded.
  nix.settings.max-jobs = 4;

  # 64 GB swap file on the NVMe root (btrfs). A whole-box safety net for
  # compiler/JIT fan-outs (the rustc builds above, the flashinfer JIT) that
  # spike host RAM far past the 64 GB of DRAM: the OOM killer now only fires
  # after 128 GB total is exhausted. The file is fallocated (hole-free —
  # swapon rejects sparse files with holes), so it consumes 64 GB of NVMe up
  # front but only pages in as swap is actually used. btrfs swap files need
  # kernel >= 6.8 (this box runs a 26.05-era kernel). Enabled by
  # swapDevices; the file itself is created by the ordered mk-swapfile
  # oneshot below.
  swapDevices = [ { device = "/swapfile"; } ];

  # Ordering guarantee for the swap file. The fstab entry above makes
  # systemd-fstab-generator create a swapfile.swap unit at boot (in
  # /run/systemd/system), but the file it swaps on does not exist yet on the
  # first activation, so swapon fails with "cannot open /swapfile". This
  # oneshot creates the file. wantedBy pulls it into swapfile.swap's
  # transaction; before is the actual ordering edge — a pull-in alone leaves
  # the units parallel, so swapon's open() can land between the script's rm
  # and fallocate. It is a no-op once a hole-free file is on disk, which
  # persists across reboots.
  systemd.services.mk-swapfile = {
    description = "Create /swapfile (64 GB, hole-free) before swap is activated";

    wantedBy = [ "multi-user.target" ];

    after = [ "local-fs.target" ];

    script = ''
      if [ ! -f /swapfile ] || \
        [ "$(${pkgs.coreutils}/bin/du -B1 /swapfile | cut -f1)" -lt \
          "$(${pkgs.coreutils}/bin/stat -c %s /swapfile)" ]; then

        rm -f /swapfile
        touch /swapfile

        ${pkgs.e2fsprogs}/bin/chattr +C /swapfile
        ${pkgs.util-linux}/bin/fallocate -l 64G /swapfile
        ${pkgs.coreutils}/bin/chmod 0600 /swapfile
        ${pkgs.util-linux}/bin/mkswap /swapfile
      fi
    '';

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

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

      [safe]
        # nix's libgit2 fetcher refuses to open a repo not owned by the
        # calling user ("repository path ... is not owned by current user",
        # NixOS/nix#10202). The crystal-forge server (user crystal-forge)
        # evaluates this repo via builtins.getFlake "git+file:///etc/nixos?rev=..."
        # while the repo is owned by llm. safe.directory is the documented
        # exception; the system config covers every user (daemon, services).
        directory = /etc/nixos
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
  # Archipelago WebHost (multiworld server + web tracker + seed generator) on
  # 127.0.0.1:8090, fronted by Caddy at https://archipelago.local. Custom
  # worlds (spire2, skeleton) load from /home/b/.local/share/Archipelago/worlds.
  services.archipelago.enable = true;
  #services.zomboid.enable = true;
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
    ACTION=="add", SUBSYSTEM=="cpu", KERNEL=="cpu[0-7]", ATTR{cpufreq/scaling_governor}="performance"
    ACTION=="add", SUBSYSTEM=="cpu", KERNEL=="cpu[0-7]", ATTR{cpufreq/energy_performance_preference}="performance"
  '';
  # TLP re-asserts its own governor (powersave on AC), conflicting with the
  # per-core policy: hushmic-audio-cores owns cpu0-7 and steam-gaming-mode owns
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
      # Owns /dev/nvidia*; needed so minuspod's CUDA whisper (WHISPER_DEVICE=cuda)
      # can open the GPU device nodes (cf. whisper-service's gpuGroups).
      "video"
    ];
    # Headless user session: keeps b's user manager (hushmic user service +
    # PipeWire) running without a graphical login; without it pw-dump cannot
    # reach the session socket.
    linger = true;
  };

  # Jailed LLM agent user: the "system" jail variants run as llm instead of
  # root, so a jail misconfig can at most write the repo and the agent home.
  # No password or SSH keys — unreachable except via `sudo -u llm`.
  #
  # b owns the agent's permissions: the home is group-`llm` 0770 and b is in
  # the `llm` group, so b can read and write the whole agent home without
  # sudo. `homeMode` is re-asserted by the users module on every activation
  # (every switch AND at boot) — a tmpfiles `z` rule would only run at boot
  # and be clobbered on the next switch, so it is not used. The primary group
  # is `llm` (not the isNormalUser default `users`) so the home and every file
  # the agent creates are group-`llm`; `users` stays an extra group so nothing
  # that expects it regresses. The agent runs umask 0002 (dsh-web `UMask=`;
  # sudoers `Defaults>llm` in security.nix) so the subdirs/files it creates
  # are group-writable, not just group-readable.
  users.users."${users.llm.username}" = {
    isNormalUser = true;
    description = "Jailed LLM agent (system jail)";
    home = users.llm.homeDirectory;
    homeMode = "0770";
    group = "llm";
    shell = pkgs.bash;
    extraGroups = [ "users" ];
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

}
