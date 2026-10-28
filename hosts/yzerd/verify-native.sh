#!/bin/sh
# Verify, from the DESK, that the box booted NATIVE NixOS and that login works.
# Run this in the jail (the desk keeps the route to 192.168.5.186; pve1 is only
# a fallback oracle). This is the goal's acceptance test:
#   LISTENER-YES -> something at .5.186 answers ssh
#   LOGIN-OK     -> ssh as b with ha_key authenticates
#   NATIVE-OK    -> hostname yzerd, NixOS os-release, pinned generation in /nix/store
#                   (on this layout /boot holds only efi; the generation lives in the store)
# Never run this from the box itself; it reads the box over the wire.

IP=${1:-192.168.5.186}
KEY=${KEY:-/home/llm/.ssh/ha_key}
# ANY driver-config change invalidates this constant — bump it after each rebuild.
# (2026-10-28: 4wcrl93… was Generation 1, the bare native box; bs2k4hs… is Generation 2,
# the NVIDIA/firmware delta; 5qpm4i4… is Generation 3, that delta plus bluetooth, regdb
# and the inspection tooling — the pin currently in force.)
GEN=5qpm4i44bgak2wkijmbfv16ah5lwyp2w-nixos-system-yzerd-26.11.20261016.f20cd90
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

say() { echo "=== $1 ==="; }

say "0. is anything listening on $IP:22 (identity, not a banner)"
# -vv is what makes the Remote protocol version line exist at all: the probe asks
# for a version without authenticating, and ssh prints it only on the verbose
# channel. grep Remote protocol version, never Server version (that string is
# what a listener-less relay would not produce, but the wording differs).
if $SSH -vv -o PreferredAuthentications=none "$IP" 2>&1 | grep -q "Remote protocol version"; then
  echo "LISTENER-YES"
else
  echo "LISTENER-NO — nothing booted, or no route (check 'ip route get $IP' first)"
  exit 1
fi

say "1. login as b with the authorized key"
if $SSH -l b "$IP" true 2>/dev/null; then
  echo "LOGIN-OK"
else
  echo "LOGIN-NO — no b/key, or sshd down"
  exit 1
fi

say "2. what is it, and is it the pinned native generation"
# the generation name crosses as a positional argument, so it interpolates HERE
# and not inside the box's shell.
$SSH -l b "$IP" "sh -s '$GEN'" <<'REMOTE' | head -40
uname -a
hostname
head -2 /etc/os-release
echo BOOT:
ls -1 /boot | head -20
echo STORE:
ls -d /nix/store/*nixos-system* 2>/dev/null | head -3
if [ -e "/nix/store/$1" ]; then
  echo PIN-PRESENT
elif ls /nix/store 2>/dev/null | grep -q nixos-system-yzerd; then
  echo PIN-PRESENT-BUT-OTHER-GEN
else
  echo PIN-ABSENT
fi
echo ROOT-ON:
findmnt -n -o FSTYPE / ; findmnt -n /dev/nvme0n1p3
echo ENTRY:
cat /boot/efi/loader/loader.conf 2>/dev/null | head -4
cat /boot/efi/loader/entries/* 2>/dev/null | head -8
echo NET:
ls -l /etc/systemd/network/ 2>/dev/null | head -5
cat /etc/systemd/network/*enp4s0.network 2>/dev/null
echo SSHA:
ls -l /etc/ssh/authorized_keys.d/ 2>/dev/null | head -5
echo UNIT:
systemctl is-active sshd
bootctl --boot-dir /boot 2>/dev/null | head -3 || true
REMOTE

say "3. is PVE still on it (it must NOT be)"
# one code only: curl's own %{http_code} is 000 when the socket is dark, so the
# || echo 000 fallback would print 000000.
web=$(curl -s -o /dev/null -m 6 -w "%{http_code}" "http://$IP:8006/" || true)
[ -z "$web" ] && web=000
echo "PVE-WEB: $web  (200 = Proxmox is still booted; 000/404 = PVE retired)"
