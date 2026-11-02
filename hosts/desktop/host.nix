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
  # applies to the very next build; this line is kept only as a persistent
  # default so builds outside the justfile stay bounded.
  nix.settings.max-jobs = 4;

  # 64 GB swap file on the NVMe root (btrfs). A whole-box safety net for
  # compiler/JIT fan-outs (the rustc builds above, the flashinfer JIT) that
  # spike host RAM far past the 64 GB of DRAM: the OOM killer now only fires
  # after 128 GB total is exhausted. The file is fallocated (hole-free —
  # swapon rejects sparse files with holes), so it consumes 64 GB of NVMe up
  # front but only pages in as swap is actually used. btrfs swap files need
  # kernel >= 6.8 (this box runs a 26.05-era kernel). Enabled by swapDevices;
  # the file itself is created by the ordered mk-swapfile oneshot below.
  swapDevices = [{ device = "/swapfile"; }];

  # Ordering guarantee for the swap file. The fstab entry above makes
  # systemd-fstab-generator create a swapfile.swap unit at boot (in
  # /run/systemd/system), but the file it swaps on does not exist yet on the
  # first activation, so swapon fails with "cannot open /swapfile". This
  # oneshot creates the file. wantedBy pulls it into swapfile.swap's
  # transaction; before is the actual ordering edge — a pull-in alone leaves
  # the units parallel, so swapon's open() can land between the script's rm
  # and fallocate. It is a no-op once a hole-free file is on disk (persists
  # across reboots).
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

  # GC of the AGENT's store, not just the system one. The jail binds /nix/store
  # read-only and the agent runs as uid `llm`, which is not in
  # `trusted-users = root`, so the agent cannot write the system store at all.
  # Pinned nix (2.34.9) defaults to `store = auto`, whose documented fallback is
  # a *private store under $HOME*: the literal string ".local/share/nix/root" is
  # compiled into the pinned `nix` binary, and the tree exists here as
  # ~/.local/share/nix/root/nix/{store,var} with its own db, gcroots, temproots,
  # profiles and gc.lock. It was born 2026-08-21 and now holds 69,056 paths =
  # 453 GiB ON THE SAME BTRFS VOLUME as /nix — 88% of /home/llm's 512 GiB.
  # `nix.gc` above never sees it: it runs against /nix/store. So every `nix
  # build`/`nix eval` an agent ran since August materialized a second copy of
  # the closure (124 of 200 sampled names exist in /nix/store too) and nothing
  # ever reclaimed it. `nix store gc --dry-run` as uid llm reports
  # 65,823 of 69,056 paths unreachable, i.e. ~430 GiB reclaimable.
  #
  # GCing is the right shape, not deleting: the private store is load-bearing —
  # it is how a jailed agent can build at all, and keeping it warm is what makes
  # agent builds fast. Only its garbage must be bounded. Note `--store` is NOT
  # usable to name it: `--store .../nix/store` opens an empty store with a fresh
  # db (0 paths deleted) because the db lives at <root>/nix/var/nix/db relative
  # to that root, and pinning `store = <root>` in nix.conf is wrong too — the
  # `local:` grammar takes the value as the STORE DIR (measured: it reported
  # 28 paths, not 65k, i.e. it scanned the wrong tree against the system db),
  # so `store = auto` + HOME remains the only resolution that finds it and this
  # unit mirrors the jail's nix environment (uid llm, HOME=/home/llm, the same
  # NIX_CONFIG as home/llm/jails.nix sets) instead of hardcoding a path.
  #
  # There is no sharing shortcut here: the jail cannot write /nix/store (mode
  # 1775, owner-only, so no group/ACL route exists) and pinned nix 2.34.9 has
  # no `daemon:` store scheme at all — every form (`--store daemon:/…`,
  # `store = daemon:…`, with or without `//`) errors
  # "don't know how to open Nix store with scheme 'daemon'", so the only
  # RemoteStore left is `ssh:`, i.e. a second shell on the host. Hence a second
  # store is forced, and the answer to its size is reclaimed in two steps below.
  #
  # Step 1 `nix store optimise` collapses identical files *inside* the private
  # store to hard links (its `.links` index exists but is empty, so it has never
  # run): measured on a 200k-file sample, same-size duplicates are 0.97 GiB of
  # 10.97 GiB = an 8.8% ceiling. Small, but it keeps every path live, so it
  # costs no rebuild. Step 2 `nix store gc` then removes the unreachable paths,
  # the dominant lever (65,827 of 69,056 paths). `nix store gc --max n` is a cap
  # on bytes FREED PER RUN, not a cap on the store's size, so it is not a
  # ceiling either; a hard ceiling needs btrfs qgroups on a dedicated subvolume,
  # which is a host-side `btrfs quota enable` + `btrfs qgroup set` and cannot
  # even be probed from the jail (`btrfs qgroup show /` says "not a btrfs
  # filesystem: /" because the jail's / is fresh tmpfs).
  systemd.services.llm-store-gc = {
    description = "Garbage-collect the llm agent's private Nix store (~/.local/share/nix/root)";

    # Boot ordering only needs /home/llm mounted so the fallback root exists;
    # the timer below is what actually runs it.
    unitConfig.RequiresMountsFor = "/home/llm";

    # The uid whose HOME pins the fallback root. There is NO
    # `systemd.services.<name>.user` option at this nixpkgs pin (evaluating it
    # errors: "The option `systemd.services.llm-store-gc.user' does not exist"),
    # so this is the raw systemd lvalue `User=` instead — a genuine lvalue, which
    # renders and is honoured, unlike a made-up key that systemd would ignore.
    # It relies on the pre-existing `llm` user (the jails run `sudo -u llm`), so
    # nothing here creates or renumbers a user.
    serviceConfig = {
      Type = "oneshot";

      User = "llm";

      # 65k+ paths to unlink: well past a default start timeout.
      TimeoutStartSec = 0;

      # Deleting is metadata-heavy on an ssd-backed volume shared with /nix.
      Nice = 19;
      IOSchedulingClass = "idle";

      # HOME and NIX_CONFIG must match the jail: `store = auto` resolves the
      # private root from HOME, and `nix store gc` is an experimental
      # nix-command subcommand. systemd allows several quoted assignments on
      # one Environment= line.
      Environment = ''HOME="/home/llm" NIX_CONFIG="experimental-features = nix-command flakes"'';

      # optimise first, gc second: dedup keeps every path live (so nothing an
      # agent is about to reuse gets thrown away), and gc then works on a
      # smaller tree. Type=oneshot runs ExecStart lines in order and stops on the
      # first failure, so a failed optimise cannot silently skip the gc.
      ExecStart = [
        "${lib.getExe' pkgs.nix "nix"} store optimise"
        "${lib.getExe' pkgs.nix "nix"} store gc --delete-older-than 30d"
      ];
    };
  };

  systemd.timers.llm-store-gc = {
    description = "Weekly GC of the llm agent's private Nix store";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      # Same cadence as the system-store GC above; `nix.gc` uses a list here
      # because its option is a list, while OnCalendar in timerConfig is a
      # plain string.
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  # The store is only one of the two tenants of this one btrfs volume: `/`,
  # `/home` (subvol=home) and `/nix` (subvol=nix) are three mounts of the SAME
  # fs (uuid e3974dc1-...), so `df` 100% is not "the store grew" — it is the
  # volume, shared by /nix/store and /home. GC bounds the store; it does nothing
  # for the other half, and it does nothing for btrfs' own overhead.
  #
  # btrfs reserves space in *chunks* (block groups), so `df` used is the
  # allocated chunk bytes, not the referenced payload: at this writing the fs
  # reported Data total=1.70TiB for used=1.48TiB, i.e. ~220 GiB of allocation
  # stranded inside partially used chunks. `df` calls that space used (it is
  # allocated), so a full volume refuses writes long before the data is full.
  # `btrfs balance` relocates the sparse chunks and returns it — the manual run
  # `btrfs balance start -dusage=50 /` took allocation 1.70TiB -> 1.58TiB and
  # free space 189G -> 321G (91% -> 83%) while `used` stayed 1.48TiB: balance
  # moves extents, it never deletes data.
  #
  # nixpkgs' btrfs module (tasks/filesystems/btrfs.nix at this pin) only offers
  # `services.btrfs.autoScrub`, which runs `btrfs scrub` — a checksum re-read
  # that frees ZERO bytes — and its own comment says balance is deliberately
  # out of scope: "One could also do regular btrfs balances, but that
  # shouldn't be necessary during normal usage and as long as the filesystems
  # aren't filled near capacity". This volume IS near capacity, so the
  # balance timer below is the missing piece: there is no nixpkgs option for it
  # (and no `services.btrfs.trim` at this pin either — generic TRIM is
  # `services.fstrim`, which already defaults to enabled weekly).
  services.btrfs.autoScrub = {
    enable = true;
    # Scrub is integrity/SSD-health, not space recovery; the module defaults to
    # monthly, weekly keeps the re-read off the hot path of a single day.
    interval = "weekly";
    # fileSystems stays unset: the module's mkDefault derives it from
    # `config.fileSystems` deduplicated by device, which collapses this volume's
    # three mounts (/, /home, /nix) to one unit on `/` — scrubbing each mount
    # separately would walk the same 1.5 TiB three times.
  };

  systemd.services.btrfs-balance = {
    description = "Reclaim btrfs fragmentation slack on / (balance -dusage=50)";
    documentation = [ "man:btrfs-balance(8)" ];

    # Pulled in by the timer below, never at boot: a balance is not a boot-time
    # action and the units' RequiresMountsFor edge makes ordering explicit.
    unitConfig.RequiresMountsFor = "/";

    serviceConfig = {
      Type = "oneshot";

      # A whole-volume balance on 1.5 TiB runs far past a default start timeout;
      # 0 disables it (oneshot would otherwise be killed mid-relocation, leaving
      # a half-balanced volume).
      TimeoutStartSec = 0;

      # Same idle scheduling the scrub unit uses, so the I/O storm cannot starve
      # the desktop or the LLM engines while it relocates chunks.
      Nice = 19;
      IOSchedulingClass = "idle";

      # -dusage=50: only relocate data block groups that are <=50% used, which
      # is what bounds the work — a healthy volume finds few candidates, so the
      # weekly pass is cheap instead of a full re-pack. Metadata chunks
      # (total=38GiB, used=24GiB) are left alone; add `-musage=50` if that
      # 14 GiB of slack ever matters.
      ExecStart = "${lib.getExe' pkgs.btrfs-progs "btrfs"} balance start -dusage=50 /";
    };
  };

  systemd.timers.btrfs-balance = {
    description = "Weekly btrfs balance on /";

    # Explicit: nixpkgs' own timer modules (services.fstrim, btrfs-scrub@) set
    # this rather than relying on an implicit default.
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
    };
  };

  # pre-commit's git (cloning hook repos) and the `nix` client run in an
  # environment whose /nix/store view may not include the system store, so the
  # default /etc/ssl/certs CA *symlinks* (into the system store) dangle and TLS
  # verification fails. Install the system's final CA bundle
  # (security.pki.caBundle — same file the system symlinks into
  # /etc/ssl/certs) as a REAL file at a stable path: `mode = "0644"` makes the
  # /etc installer copy it instead of symlinking it, so it resolves regardless
  # of which store view the environment sees. Point git at it via the system
  # gitconfig.
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
  # `just fmt` also works in host shells, where no jail environment exists.  environment.sessionVariables.NIXPKGS = pkgs.path;

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
  # Windows NTFS partitions (nvme1n1p1/p4/p5, nvme0n1p2). Declaring the fs
  # type is what makes nixpkgs' tasks/filesystems/ntfs.nix put pkgs.ntfs3g in
  # system.fsPackages — i.e. install /sbin/mount.ntfs + mount.ntfs-3g, the
  # helper udisks2 needs for KDE's rw auto-mount. Without it there is no
  # helper and mount(8) answers "wrong fs type ... missing codepage or
  # helper program". Kernel is 6.18 (< 7.1), so the module takes the ntfs3g
  # branch, not the ntfsprogs-plus one.
  boot.supportedFilesystems.ntfs = true;
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
  # the `llm` group, so b can read and write the whole agent home without sudo.
  # `homeMode` is re-asserted by the users module on every activation (every
  # switch AND at boot) — a tmpfiles `z` rule would only run at boot and be
  # clobbered on the next switch, so it is not used. The primary group is
  # `llm` (not the isNormalUser default `users`) so the home and every file the
  # agent creates are group-`llm`; `users` stays an extra group so nothing that
  # expects it regresses. The agent runs umask 0002 (dsh-web `UMask=`; sudoers
  # `Defaults>llm` in security.nix) so the subdirs/files it creates are
  # group-writable, not just group-readable.
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
