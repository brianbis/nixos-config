#!/bin/sh
# Run this ON THE BOX (the live-ISO env, right after go-native.sh's install), not in the jail.
# Purpose: make the freshly-installed systemd-boot the entry that wins the next boot
# while the Ventoy stick is still plugged in, then reboot. Screen-free by construction —
# every step prints what NVRAM now says, so the desk can read the boot decision.

set -e

say() { echo "=== $1 ==="; }

say "0. what is on the ESP"
ESP=/mnt2/boot/efi
mountpoint /mnt2/boot/efi || { echo "ESP NOT MOUNTED: mount /dev/nvme0n1p2 there first"; exit 8; }
ls -l "$ESP/EFI/BOOT" "$ESP/EFI/systemd" 2>&1 | head -12

say "1. what the NVRAM says now"
efibootmgr -v | head -14
efibootmgr --help 2>&1 | grep -iE "fallback|filepath|order|next" | head -8

say "2. arm BootNext to the ESP's fallback path (single reboot, stick stays plugged)"
# -f gives the fallback file (EFI/BOOT/bootx64.efi), which is exactly what the
# systemd-boot builder copies when canTouchEfiVariables = false.
efibootmgr -c -d /dev/nvme0n1 -p 2 -L nixos-native -f '\EFI\BOOT\BOOTX64.EFI' | head -4
efibootmgr -v | head -14
NEW=$(efibootmgr | awk -F'[ *]' '/Boot[0-9A-F]+.*nixos-native/{print substr($1,5); exit}')
echo "NEW-ENTRY: ${NEW:-none-found}"
[ -n "$NEW" ] || { echo "NO-NEW-ENTRY: read the efibootmgr map above before ordering"; exit 7; }
efibootmgr -n "$NEW" | head -3
echo "BOOTNEXT-NOW: $(efibootmgr | grep -i '^BootNext' || echo none)"

say "3. reboot into it (the desk watches for sshd over the wire, never a screen)"
sync
systemctl reboot
