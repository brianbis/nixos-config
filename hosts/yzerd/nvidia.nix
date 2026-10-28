{ config, lib, pkgs, ... }:

# The card in this box, and the driver that owns it.
#
# What the booted box reported with no driver config of its own: the in-tree nouveau
# driver found the card and then failed to take it, because a 40-series card needs
# nouveau's GSP firmware and this system shipped no /lib/firmware at all — the journal
# of the first native boot said, verbatim:
#
#   nouveau 0000:0a:00.0: NVIDIA AD102 (192000a1)
#   nouveau 0000:0a:00.0: gsp: Failed to load required firmware for device.
#   nouveau 0000:0a:00.0: gsp ctor failed: -2
#   nouveau 0000:0a:00.0: probe with driver nouveau failed with error -2
#
# and /dev/dri held nothing but the EFI console's simple-framebuffer node
# (card0 -> .../simple-framebuffer.0/drm/card0), with no /dev/nvidia* anywhere. A
# present card, owned by nothing. lspci/lsusb were not even installed, so the box
# could not report its own hardware either.
#
# The second native boot (Generation 2, the pin THIS file produces) proved the fix
# from a cold start, with nothing loaded by hand:
#
#   nvidia-smi  -> NVIDIA GeForce RTX 4090, KMD 615.78.08, CUDA UMD 13.4, Bus 0A:00.0
#   lsmod       -> nvidia 18.7M, nvidia_modeset, nvidia_uvm, nvidia_drm all inserted
#   /dev/       -> nvidia0 nvidiactl nvidia-modeset nvidia-uvm nvidia-uvm-tools (root:video)
#   /sys/class/drm -> card1 + renderD128, with card1-DP-1..4 and card1-HDMI-A-1
#   firmware    -> 915 files, 392 of them .bin.zst, the nouveau GSP blobs (15E2-0-0x…)
#
# and the same firmware directory is why the WiFi card works now where it did not
# before: `iwlwifi loaded firmware version 77.8dbafb52.0` and
# `iwlwifi … wlp6s0: renamed from wlan0` — on the first native boot there was no
# wlp* in /sys/class/net at all, because the card's firmware was absent.
#
# The driver branch is the one hosts/desktop/nvidia.nix already runs on the repo's
# other NVIDIA box: the OPEN kernel modules, which this nixpkgs pin's own assertion
# in nixos/modules/hardware/video/nvidia.nix asks for on Turing or later (the card is
# AD102). The two package pins below are not card-shaped — they are bugs in THIS
# nixpkgs revision, same rev as desktop, so they carry over:
#
#   * patchelf 0.19.2 mangles the .run payload (one pass sets both interpreter and
#     rpath), so nvidia-smi and co segfault in the loader: NixOS/nixpkgs#576412,
#     NixOS/patchelf#674. Upstream fix NixOS/nixpkgs#576397 landed on master 2026-10-21;
#     the ref this rev points at (f20cd90, 2026-10-16) does not have it.
#   * nvidia-modeset frees the device twice when a failed resume revokes while it is
#     already revoking, oopsing in the PM notifier: NVIDIA/open-gpu-kernel-modules#1395,
#     checked absent from the 615 tree (nvRevokeDevice has no nested-revoke guard).
#
# hardware.nvidia.enabled in this pin is `elem "nvidia" config.services.xserver.videoDrivers`
# or datacenter.enable — videoDrivers is the switch, and xserver itself stays off on
# this box, so no display manager and no X configuration is implied here.

{
  # The NVIDIA userland is unfreeRedistributable in this pin
  # (pkgs/os-specific/linux/nvidia-x11/generic.nix), and this nixpkgs revision refuses it
  # at evaluation — "Refusing to evaluate package 'nvidia-x11-615.78.08' … because it has an
  # unfree license". nixpkgs.config is the knob that reaches the package set: nixos/modules/misc/nixpkgs.nix
  # rebuilds it as `import ../../.. { inherit (cfg) config overlays; … }`. hosts/desktop/…
  # does the same thing from the root flake; declaring it here keeps the allowance next to
  # the one unfree package it buys, instead of switching the whole eval.
  nixpkgs.config.allowUnfree = true;

  hardware.nvidia = {
    # This is the enable switch in this pin; see the comment above.
    modesetting.enable = false;

    # No settings GUI on a headless box: nvidiaSettings only pulls the Qt front end.
    nvidiaSettings = false;

    # Deliberately off, unlike hosts/desktop/nvidia.nix. There the card's residency
    # is managed by the llm gate, which stops engines to reclaim VRAM; nothing on
    # this box owns that policy yet, so a driver that sleeps the GPU when idle would
    # hand back memory nothing is going to reclaim, and CUDA would pay a resume per
    # workload. Recorded, not inherited silently.
    powerManagement.enable = false;

    # AD102 — the open modules are the branch this pin's assertion asks for.
    open = true;

    package =
      (config.boot.kernelPackages.nvidiaPackages.latest.overrideAttrs (old: {
        nativeBuildInputs = [
          (pkgs.patchelf.overrideAttrs (finalAttrs: _: {
            version = "0.15.2";
            src = pkgs.fetchurl {
              url = "https://github.com/NixOS/patchelf/releases/download/${finalAttrs.version}/patchelf-${finalAttrs.version}.tar.bz2";
              hash = "sha256-F3RfVkFZyOIo/EEtplogSLhGxLa0Igt3y/IkFuAvLXw=";
            };
          }))
        ] ++ old.nativeBuildInputs;
      }))
      // {
        open =
          config.boot.kernelPackages.nvidiaPackages.latest.open.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [
              (pkgs.fetchpatch {
                name = "nvidia-modeset-ignore-nested-revoke.patch";
                url = "https://github.com/NVIDIA/open-gpu-kernel-modules/commit/5db24a72350ab2679376132ac8e31a06a0950343.patch";
                hash = "sha256-aWzj+3AR7xjvWp5IL5iSNIts0SKp9kT35zgXUINBuhc=";
              })
            ];
          });
      };
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  # GL/Vulkan userspace for the card: hardware.graphics is what puts /run/opengl-driver
  # in place. Without it a GL consumer on this box would have no driver at all.
  hardware.graphics = {
    enable = true;
  };

  # linux-firmware, for two reasons. The direct one: nouveau cannot bring a 40-series
  # card up without its GSP firmware (the boot journal above is that failure), so if the
  # free driver is ever preferred the firmware has to be here. The general one: this
  # system had no /lib/firmware at all, and the WiFi card, the card reader and the SMB
  # host all want the same directory. hardware.nvidia blacklists nouveau/nova_core/nvidiafb
  # in this pin, so the NVIDIA modules own the card while both are present.
  hardware.enableRedistributableFirmware = true;

  # The AX200's Bluetooth half. lsusb named 8087:0029 Intel Corp. AX200 Bluetooth and
  # the kernel side came up by itself (bluetooth referenced by btrtl,btmtk,btintel,btbcm,
  # btusb), but `systemctl status bluetooth` on the second boot answered that the unit
  # could not be found — there is no userspace daemon without bluez.
  hardware.bluetooth.enable = true;

  # wireless-regdb is a separate package: all-firmware.nix only puts it in the firmware
  # dir when this option is set, so enableRedistributableFirmware alone would leave iw
  # without the regulatory table it consults before serving a route.
  hardware.wirelessRegulatoryDatabase = true;

  # The box gets a way to report its own hardware: nothing in the minimal config's
  # closure could enumerate PCI or USB, which is why the driver audit had to lean on
  # /sys and the journal instead of lspci. The rest of this list is the userspace that
  # inspects each surface this file declares — alsamixer/arecord for the ALSA nodes
  # under /dev/snd, vainfo for the GL driver in /run/opengl-driver, v4l2_info for
  # capture devices — plus efibootmgr, so the NVRAM door in ./boot-native.sh can run
  # on the box itself and not only from a live ISO.
  environment.systemPackages = with pkgs; [
    pciutils
    usbutils
    alsa-utils
    alsa-ucm-conf
    libva-utils
    v4l-utils
    efibootmgr
  ];
}
