{ config, lib, pkgs, ... }:

/*
  System config for the second machine: the NixOS guest on the Proxmox VE box
  (node yzerd, vmid 100). Deliberately a text-console machine — it has no GPU,
  no display, and one declared ordinary user for the console login (root stays
  locked, as this nixpkgs pin's default wants); see the login-path note below.
*/

{
  imports = [ ./hardware-configuration.nix ];

  # Boot loader for this guest's topology. PVE creates it with `bios: seabios`
  # (PVE's own default) on `machine: q35`, so the guest has a BIOS, not EFI:
  # there are no EFI variables to touch and no /boot/efi filesystem, and the disk
  # arrives as the guest's first SCSI disk -> /dev/sda with an MBR. GRUB (grub-pc)
  # writes to the MBR here. This is the opposite of hosts/desktop/boot.nix, which
  # uses systemd-boot because that machine is EFI.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  # The console this VM can be talked to is the SERIAL one: PVE gives it
  # `serial0: socket`, `qm terminal 100` is the only text console the host has,
  # and there is no display. A later console= WINS for userspace stdout, so the
  # ORDER of this list is the setting that decides what the host can read, and
  # the order that works is ttyS0 LAST:
  #   - the pair this list used to carry (`console=ttyS0 console=tty1`, which is
  #     what GRUB wrote onto the installed disk) sends userspace to tty1; a
  #     capture of /run/qemu-server/100.serial0 over such a boot read
  #     `TOTAL-BYTES: 0` — boot5/7 and boot8 on 2026-10-27, and the login prompt
  #     was unreachable from the host even though serial-getty@ttyS0 was running;
  #   - the same kernel+initrd pair re-booted with console=ttyS0 LAST printed the
  #     whole stage-1 trace and `nixos-vm login:` into the same socket capture
  #     (/tmp/boot9a.log, 12479 B), and the login over it then answered.
  # tty1 is still declared first, so the machine keeps a tty1 getty; the visible,
  # drivable one is the serial console.
  boot.kernelParams = [
    "console=tty1"
    "console=ttyS0"
  ];

  # Real option in this nixpkgs pin: profiles/headless.nix sets
  # systemd.services."serial-getty@ttyS0".enable = lib.mkDefault false, so
  # enabling the instance is how a serial getty is asked for.
  systemd.services."serial-getty@ttyS0".enable = true;

  # Debug affordance for this VM's stage 1, deliberately on: the install runs
  # `--no-root-password`, so a stage-1 failure would otherwise land in a
  # LOCKED sulogin ("Cannot open access to console, the root account is locked.")
  # that cannot be typed into from PVE at all — every boot diagnostic then becomes
  # unreadable. nixpkgs' own live images set this (see
  # nixos/modules/installer/cd-dvd/iso-image.nix, boot.initrd.systemd.emergencyAccess)
  # and it is the only way to get a usable emergency shell on a console-driven VM.
  boot.initrd.systemd.emergencyAccess = true;

  # The booted system has to be loggable in, or the boot cannot be verified at
  # all: the install runs `--no-root-password` (which per this pin's own
  # pkgs/by-name/ni/nixos-install/nixos-install.sh only skips the interactive
  # `passwd` call — it does not override the config) and with no declared
  # account stage 3 leaves a locked root and nothing behind the getties, so the
  # console answers "Login incorrect". A declared ordinary user is what gives
  # the getty a login; root stays locked, which is this pin's default and is
  # what `sudo -i` from the ordinary user is built for.
  #
  # Setting the password ON root does not work here, and the reason is in the
  # module, not in the installer: nixos/modules/config/users-groups.nix
  # (passwordDescription) says a password option "will only be set when the
  # user is created for the first time" while users.mutableUsers is true (the
  # default, and this repo never sets it false), and root already exists in the
  # install chroot — so activation never touches it. Read off the installed disk
  # after the 2026-10-27 R8 install: /etc/shadow carried `root:!:` and the
  # serial login failed 3x. An ordinary declared user IS created at activation,
  # so its hash does land. (Alternative, not taken: `users.mutableUsers = false`
  # makes every password immutable-per-config; it changes the whole machine's
  # policy for one login path, so the narrower declared user wins.)
  #
  # Deterministic fixture value, not secret management — a real machine would
  # carry the hash in an agenix secret.
  users.users.nixos-vm = {
    isNormalUser = true;
    description = "nixos-vm console login (deterministic fixture password)";
    extraGroups = [ "wheel" ];
    password = "nixos-vm-guest";
  };

  networking.hostName = "nixos-vm";
  time.timeZone = "America/Phoenix";

  # Matches the pinned nixpkgs era (same value as hosts/desktop/host.nix), not
  # the live-ISO release the disk was installed from.
  system.stateVersion = "26.11";

  # Flake workflow on the machine itself: /etc/nixos is this sub-flake, so
  # `nixos-rebuild --flake /etc/nixos#nixos-vm` is the way it is rebuilt.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # The guest is an 8-core VM on a shared host; a hard cap keeps a build here
  # from eating the box the desktop shares (same reasoning as host.nix).
  nix.settings.max-jobs = 4;

  # net0: virtio,bridge=vmbr0 — the guest's wired network is the host's static
  # bridge (vmbr0 -> enp4s0 on yzerd). NetworkManager, matching the desktop
  # (hosts/desktop/networking.nix), so nmtui works over the serial console.
  networking.networkmanager.enable = true;

  # No microcode/firmware tuning here: the guest's CPU is QEMU's `-cpu host`
  # on a kernel PVE supplies, and amd64-microcode is the HOST's concern (PVE 9
  # installed it during the 8->9 upgrade), not this disk's.

  # ---- GPU passthrough: the host's RTX 4090 (PCI 0a:00.0) over QEMU's vfio channel
  # The host side is `qm set 100 -hostpci0 0a:00.0,pcie=1`; verified in this PVE
  # 9.2 tree (/usr/share/perl5/PVE/QemuServer/PCI.pm: prepare_pci_device binds the
  # device to vfio, `driver` defaults to "vfio", and it hard-requires IOMMU, which
  # this card has: /sys/bus/pci/devices/0000:0a:00.0/iommu -> .../iommu_groups/25).
  # The guest sees the device as a vfio-subsystem node, so this is the ownership
  # rule nixpkgs itself uses for that subsystem
  # (nixos/modules/virtualisation/kvmgt.nix:62 SUBSYSTEM=="vfio").
  services.udev.extraRules = ''
    SUBSYSTEM=="vfio", OWNER="root", GROUP="kvm"
  '';

  # What is NOT enabled here, and why, so this file stays honest: this nixpkgs
  # pin has no `hardware.nvidia.enable` at all — nixos/modules/hardware/video/nvidia.nix
  # gates NVIDIA on `services.xserver.videoDrivers = [ "nvidia" ]`, which drags an X
  # stack into a machine this config declares text-console, and the only X-free
  # NVIDIA option in the pin is `hardware.nvidia.datacenter.enable` (fabric manager
  # for an NVLink multi-GPU box, not one 4090). So "CUDA inside this guest" is an
  # open question tracked in README.md, not a setting asserted here.
}
