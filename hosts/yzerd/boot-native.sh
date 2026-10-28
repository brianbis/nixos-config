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

say "2. order the ESP entry that already exists, and arm it for one reboot"
# Proven on this box: Boot0004 = `UEFI OS -> HD(2,GPT,ae4fb41e-...)/EFI\BOOT\BOOTX64.EFI`
# on the NVMe ESP, and bootctl's fallback copy made that file systemd-boot
# (md5 equal to EFI/systemd/systemd-bootx64.efi). So no new entry is needed —
# ordering plus BootNext is enough. Verify the file identity first.
md5sum "$ESP/EFI/BOOT/BOOTX64.EFI" "$ESP/EFI/systemd/systemd-bootx64.efi" 2>/dev/null
ENTRY=0004
efibootmgr -o 0004,0006,0007,0008,0005,0000,0003
efibootmgr -n "$ENTRY"
efibootmgr | grep -E "^Boot(Order|Next)"

say "3. reboot into it (the desk watches for sshd over the wire, never a screen)"
# plain `systemctl reboot` from the live ISO did not reboot the box at all
# (wtmp kept the old session and BootNext stayed set); --force does.
sync
systemctl reboot --force
