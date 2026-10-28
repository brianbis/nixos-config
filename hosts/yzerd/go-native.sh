#!/bin/sh
# One-shot native install driver for the PHYSICAL box (Option A: PVE retired).
# Copy it onto the box during the live stage and run it there:
#   ssh -o BatchMode=yes -l root 192.168.5.186 'cat > /root/go-native.sh' < go-native.sh
#   ssh -o BatchMode=yes -l root 192.168.5.186 'sh /root/go-native.sh WIPE'
#
# It destroys /dev/nvme0n1p3 (PVE's LVM volume group AND the installed guest) and
# refuses to do that unless the literal word WIPE is passed. Every step prints an
# RC marker, so the whole run reads as ground truth from the jail.

set -e

say() { echo "=== $1 ==="; }

if [ "$1" != "WIPE" ]; then
  echo "GUARD-REFUSED: nvme0n1p3 is still PVE. Re-run as: sh /root/go-native.sh WIPE"
  exit 9
fi

say "0. identity (who am I booted as, and is p3 really PVE?)"
uname -a
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null | head -20 || true
ls -blk /dev/nvme0n1p3 || { echo "no /dev/nvme0n1p3 — read the lsblk map above before proceeding"; exit 8; }
blkid /dev/nvme0n1p1 /dev/nvme0n1p2 /dev/nvme0n1p3 || true
p3type=$(blkid -o value -s TYPE /dev/nvme0n1p3 2>/dev/null || true)
echo "P3-TYPE: ${p3type:-none-raw}"
case "$p3type" in
  LVM2_member|LVM2/*) echo "p3 holds PVE's LVM volume group — the planned door" ;;
  ext4)
    say "p3 is already ext4 — the door was walked before"
    echo "REFUSING: pass FORCE-EXT4 as the second argument to wipe it anyway"
    [ "$2" = "FORCE-EXT4" ] || exit 8 ;;
  "")
    # Reached when a previous run already ran vgremove + wipefs but died before
    # mkfs: p3 is raw now (blkid answers no TYPE at all), PVE's DM devices are
    # gone, and the layout step is what is left to do. Not a new assumption —
    # the run that made it raw is recorded in README.md.
    say "p3 is raw — a previous run already tore down pve's DM and wiped the magic"
    echo "RAW-RESUME: continuing to mkfs"
    echo "DM-AFTER-PREVIOUS: $(dmsetup ls 2>/dev/null | tr '\n' ' ')" ;;
  *)
    echo "P3-TYPE IS NEITHER PVE-LVM NOR ext4: stop, the layout assumption is wrong"
    exit 8 ;;
esac
echo "IDENTITY-OK"

say "1. stick"
mkdir -p /mnt/stick
umount /mnt/stick 2>/dev/null || true
if mount -o remount /dev/sda1 /mnt/stick 2>/dev/null || mount /dev/sda1 /mnt/stick 2>/dev/null; then
  echo "STICK-VIA-BLK: /dev/sda1"
else
  # The live ISO cannot open /dev/sda1 as a blockdev ("fsconfig() failed:
  # Can't open blockdev") even though the node exists and blkid/dd read it;
  # a loop device over the same node mounts fine.
  L=$(losetup -f)
  losetup "$L" /dev/sda1 || exit 7
  mount "$L" /mnt/stick || exit 7
  echo "STICK-VIA-LOOP: $L"
fi
ls -l /mnt/stick/repo-yzerd
md5sum /mnt/stick/repo-yzerd/default.nix /mnt/stick/repo-yzerd/flake.nix /mnt/stick/repo-yzerd/flake.lock
echo "STICK-OK"

say "2. offline seed (the only network input of hosts/yzerd/flake.lock)"
# NOTE from the live ISO: /nix/store is an OVERLAY MOUNTED READ-ONLY
# (mounts: "overlay /nix/store overlay ro,... lowerdir=/sysroot/nix/.ro-store
# upperdir=/sysroot/nix/.rw-store/store"), so a store restore on the live side
# cannot work — "cannot create directory: Read-only file system". nixos-install
# is built for exactly this: it copies Nix into /mnt2/nix/store and builds there,
# so the fetch happens in the writable TARGET store. SEED-FAILED here is normal
# on the live ISO and means "use the pinned GitHub fetch", which the live env
# proved reachable (curl -sI https://github.com/ -> HTTP/2 200).
if [ -e /mnt/stick/offline/nixpkgs-f20cd90.nar.xz ]; then
  echo "SEED-PRESENT: $(md5sum /mnt/stick/offline/nixpkgs-f20cd90.nar.xz)"
  if xz -dc /mnt/stick/offline/nixpkgs-f20cd90.nar.xz | nix-store --restore /nix/store/glw7ngr0dwbp3al07rdlqkrbas7w3a02-source; then
    echo "SEED-RESTORED"
  else
    echo "SEED-FAILED: falling back to the pinned GitHub fetch (needs the wired LAN)"
  fi
else
  echo "SEED-ABSENT: not staged on the stick yet — fetch needs the wired LAN"
fi
echo "NET-CHECK: $(curl -sI -m 10 https://github.com/ | head -1)"

say "3. the door: tear down pve's device-mapper first, then wipe p3 and lay the declared layout"
# mkfs.ext4 refuses with "/dev/nvme0n1p3 is apparently in use by the system"
# while pve-root/pve-swap are ACTIVE device-mapper devices on that partition
# (nothing mounts it, lsof/fuser are empty — the busy check is dm_dev_in_use).
# Tear down ONLY the pve volume group: the live ISO reads its own /iso off the
# Ventoy device-mapper, so ventoy/sda1 must stay live.
vgremove -f pve || echo "VGREMOVE-NONZERO: read the dm map below"
echo "DM-AFTER: $(dmsetup ls 2>/dev/null | tr '\n' ' ')"
wipefs -a /dev/nvme0n1p3 || echo "WIPEFS-NONZERO"
# -f is NOT an mke2fs option (it belongs to the busybox mkfs wrapper), so drop it:
# the DM devices are gone by now and the busy check passes on its own.
mkfs_rc=0
mkfs.ext4 -L nixos-native -O Linux /dev/nvme0n1p3 || mkfs_rc=$?
echo "MKFS-RC: $mkfs_rc"
[ "$mkfs_rc" = 0 ] || exit 6
mkdir -p /mnt2
mount /dev/nvme0n1p3 /mnt2 || exit 5
mkdir -p /mnt2/boot/efi
mount /dev/nvme0n1p2 /mnt2/boot/efi || exit 4
df -h /mnt2 | tail -1
echo "MOUNT-OK"

say "4. install from the stick flake (the pin is the whole point)"
install_rc=0
nixos-install --root /mnt2 --flake /mnt/stick/repo-yzerd#nixosConfigurations.yzerd --no-root-password || install_rc=$?
echo "INSTALL-RC: $install_rc"
if [ "$install_rc" != 0 ]; then
  say "4b. install failed — what is on the target now (p3 is already a fresh ext4)"
  ls -l /mnt2 | head -10
  df -h /mnt2 | tail -1
  exit 3
fi

say "5. did the built generation equal the recorded pin?"
GEN=/mnt2/boot/4wcrl93il7vvqij3wihva6p83l3gk5n2-nixos-system-yzerd-26.11.20261016.f20cd90
if [ -e "$GEN" ]; then
  echo "PIN-MATCH: generation present at /boot/<basename of the pinned out path>"
  ls -l "$GEN" | head -5
else
  echo "PIN-MISMATCH: expected generation dir absent — list what the install produced"
  ls -l /mnt2/boot | head -20
fi

say "6. ESP evidence: open question 2 (does --variables=no land EFI/BOOT/bootx64.efi?)"
find /mnt2/boot/efi -maxdepth 4 -type f \( -name 'bootx64.efi' -o -name '*.efi' -o -name 'boot.csv' \) 2>/dev/null | head -20 || echo "no ESP files found"
ls -l /mnt2/boot/efi/EFI 2>/dev/null | head -10
command -v efibootmgr >/dev/null && efibootmgr | head -30 || echo "no efibootmgr on the live image"

say "7. remote-controllability of the fresh system"
ls -l /mnt2/etc/ssh/authorized_keys.d 2>/dev/null | head -5
head -3 /mnt2/etc/ssh/authorized_keys.d/b 2>/dev/null || echo "no authorized_keys.d/b (check the user name)"
grep -Ei '^(PasswordAuthentication|PermitRootLogin|AuthorizedKeysFile)' /mnt2/etc/ssh/sshd_config || echo "sshd_config: none of the three lines"
ls -l /mnt2/etc/systemd/network 2>/dev/null | head -5
cat /mnt2/etc/systemd/network/*enp4s0.network 2>/dev/null || echo "unit absent: check the name"
echo "DONE-AT-7"

say "8. what to do at the console now"
sync
echo "sync once more, then power off the box: the install is done, the ESP is written"
echo "first boot from its own hardware must land on Boot0004 (UEFI OS) -> EFI/BOOT/bootx64.efi; no NVRAM edit is expected"
echo "if it does not boot, efibootmgr -n <entry> is the only one-shot knob left"
echo "DONE-AT-8"
