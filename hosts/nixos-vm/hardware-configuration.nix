{ config, lib, pkgs, ... }:

/*
  Hardware of the Proxmox VE guest (vmid 100 on node yzerd).

  HAND-WRITTEN, not nixos-generate-config output: the generated file records
  whatever UUID/label the installer happened to create, so re-running an install
  silently changes the system. This file states the topology instead, and README.md
  in this directory states the partition recipe that produces exactly this device,
  so (this file set + that recipe) reproduces the disk.

  Reproducible identity of the guest, from `qm config 100`:

      bios: seabios            machine: q35           scsihw: virtio-scsi-single
      scsi0: local-lvm:vm-100-disk-0,size=32G         serial0: socket
      boot: order=ide2         ide2: local:iso/nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso

  The guest sees that virtual disk as /dev/sda (virtio-scsi front end). The single
  partition is created with `mkfs.ext4 -L nixos-vm`, so the mount below is pinned
  to a fixed label and never to a fresh random UUID.
*/

{
  fileSystems."/".device = "LABEL=nixos-vm";
  fileSystems."/".fsType = "ext4";

  # The root lives on the virtio-SCSI disk PVE exposes to the guest as /dev/sda
  # (`scsihw: virtio-scsi-single`, `scsi0: local-lvm:vm-100-disk-0`). The failure
  # is never a mount error: the block device simply does not exist in stage 1, so
  # stage 1 waits 90 s and dies with "Timed out waiting for device ..." (for
  # LABEL=nixos-vm, for /dev/sda1 and for /dev/sda alike), then the whole
  # /sysroot dependency cascade lands in emergency mode.
  #
  # The cause is one missing module, and the missing module is not the one you
  # would guess. Every stage-1 attempt was interrogated from inside the initrd
  # (boot.initrd.systemd.emergencyAccess = true, duplex over the serial chardev):
  #
  #   * virtio_blk + virtio_scsi only in availableKernelModules (the generated
  #     shape)                              -> no /dev/sd* at stage 1.
  #   * + boot.initrd.kernelModules = [ "sd_mod" ]              -> still none.
  #   * + boot.initrd.kernelModules = [ "sd_mod" "scsi_mod" "virtio_scsi" ]
  #       lsmod in the initrd then read: sd_mod, scsi_mod, virtio, virtio_ring,
  #       virtio_scsi ALL loaded, yet
  #         /sys/bus/virtio/devices/  -> empty
  #         /sys/block/               -> only sr0 (the ISO, on the ATA bus)
  #         /dev/disk/by-id           -> only ata-QEMU_DVD-ROM_QM00003
  #       and the kernel log carries `scsi host0..5: ahci` + `scsi 1:0:0:0:
  #       CD-ROM` but not one `scsi hostN: virtio-scsi` line. So the SCSI layer
  #       was fine and the whole *virtio transport* was invisible: not the disk
  #       alone — virtio-net and the 9p share were invisible too.
  #
  # Why: this kernel is modular and its PCI transport for virtio is a module that
  # nothing asks for. The initrd cpio (2116 entries, 57 .ko) carries
  # virtio.ko / virtio_ring.ko / virtio_blk.ko / virtio_scsi.ko and **no
  # virtio_pci.ko**, while the kernel's own module set
  # (`*-linux-6.18.56-modules`, 7296 modules) has virtio_pci.ko.xz, virtio_blk,
  # virtio_net, virtiofs, 9pnet_virtio, ... . Without virtio_pci the guest never
  # enumerates a virtio-pci device, so there is no SCSI host, no udev event, and
  # nothing on-demand left to load — which is why forcing the SCSI half was
  # necessary but never sufficient.
  #
  # nixpkgs states this shape for exactly this target: virtualisation/proxmox-image.nix:351-355
  # and virtualisation/vz-vm.nix:227-234 put virtio_pci in
  # boot.initrd.availableKernelModules, and virtualisation/digital-ocean-config.nix:54-58
  # pairs virtio_pci in boot.kernelModules with virtio_scsi in
  # boot.initrd.kernelModules. virtio_pci.ko pulls virtio/virtio_ring via kmod,
  # so listing the transport is enough; the SCSI half is listed explicitly
  # because /dev/sd* is what the fstab asks for.
  boot.initrd.availableKernelModules = [
    "virtio_blk"
    "virtio_pci"
    "virtio_scsi"
    "scsi_mod"
    "sd_mod"
    "sr_mod"
  ];
  boot.initrd.kernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "scsi_mod"
    "sd_mod"
  ];

  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # No swap: the guest runs with memory: 114688 (112 GiB, `free -m` on the booted
  # guest reported 112689) and 32 GiB of disk, so a swap partition would be one
  # more thing for the install recipe to get wrong.
  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
