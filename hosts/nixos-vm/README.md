# nixos-vm — the second machine (NixOS guest on the Proxmox VE box)

This directory is a **self-contained flake** and the single source of truth for
the guest. It is re-exported by the repo's root flake as
`nixosConfigurations.nixos-vm` through the `path:hosts/nixos-vm` input, and the
guest's own `/etc/nixos` is a **verbatim copy** of this directory, so
`nixos-install`/`nixos-rebuild` on the guest builds the identical system the
repo builds.

## Guest identity (pin these before re-running anything)

| thing | value |
| --- | --- |
| PVE node / vmid | `yzerd` / `100`, `name: nixos-vm` |
| PVE version | `pve-manager 9.2.24/66bc407c6d90a67a`, kernel `7.0.14-26-pve` |
| ISO | `nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso` |
| ISO sha256 (published, verified) | `12f093ce7bf7e9747c67730ee3cc7b22713912382e8d3d6f27ef6b19afd8c800` |
| ISO `version.txt` | `26.05.12707.718f670e8453` |
| nixpkgs pin | `github:NixOS/nixpkgs/f20cd90e28fe0403873f473b29e42662cd86e8c4` (the repo's `flake.lock` resolution) |

## Validated

Nix sees the *repo* as a git flake, so these files must be `git add`ed before
any evaluation can see them (`error: Path 'hosts/nixos-vm/flake.nix' ... is not
tracked by Git`). Then, narrow — the desktop's toplevel is untouched by this
change:

```
$ nix flake check ./hosts/nixos-vm
all checks passed!                      # and it wrote hosts/nixos-vm/flake.lock
$ nix eval --impure --expr 'builtins.attrNames (builtins.getFlake "/etc/nixos").nixosConfigurations'
[ "nixos" "nixos-vm" ]                  # the repo really is two machines now
```

The sub-flake's generated `flake.lock` pins the same narHash as the repo —
`sha256-EjZqHKObBfIOeHZnMRVV87HB3pPq/WBkmRJWyFxmZu8=` — so both machines build
one package set. Evaluated through the **root** flake (eval only, nothing built):

```
$ nix eval --impure --raw --expr '(builtins.getFlake "/etc/nixos").nixosConfigurations.nixos-vm.config.system.build.toplevel.drvPath'
/nix/store/67amkskgbyjvfmd82faskqy7619v815w-nixos-system-nixos-vm-26.11.20261016.f20cd90.drv
```

That hash is the config **with** the `SUBSYSTEM=="vfio"` udev rule; the GPU-less
version evaluated to `mlmx3dw4716plwih1j3x33r85vxann11-…` before it was added, so a
config edit moves the drv and nothing else about the pin changed.

Later config edits moved it again, five times, and every one of them was
re-verified the same way. **The pin at the time of writing** — the config that
carries the virtio fix, the declared console-login user, and `console=tty1
console=ttyS0` in that order — is:

```
$ nix eval --raw --impure --expr '(builtins.getFlake "/etc/nixos/hosts/nixos-vm").nixosConfigurations.nixos-vm.config.system.build.toplevel.drvPath'
/nix/store/4p2iipl35vs08lvbkkj1hp3qsq47l517-nixos-system-nixos-vm-26.11.20261016.f20cd90.drv
$ nix eval --raw --impure --expr '…toplevel.outPath'
/nix/store/79fa4aridyzpgjkmgn82yfb300d6mc9c-nixos-system-nixos-vm-26.11.20261016.f20cd90
```

The pin before the console-ordering edit was
`fwjb096r4qmx1dhhksar8njb7d9rc4ah…drv` / out
`chsp88wrki6qqwl2vmg5slyv62bx29z5…` — that one is what the disk carries today
(the 2026-10-27 R9 install built exactly it), so the disk is one console-ordering
edit behind the repo. The guest's `nixos-install` builds that exact `.drv` (asserted
by grepping the install log; see the run log below). README-only edits do **not**
move it — verified by appending a probe line to this file and re-evaluating: same
hash before and after. So documenting after a boot proof never invalidates the pin.

The justfile's rebuild targets now name the machine (default = the desktop, so
`just switch` is unchanged; `just switch nixos-vm` renders
`sudo nixos-rebuild switch --flake ".#nixos-vm" --cores 1 --max-jobs 16`, checked
with `just --dry-run` against both `just` 1.57.0 and 1.58.0 on the box).

## Rebuilding the guest afterwards

From inside the guest: `nixos-rebuild switch --flake /etc/nixos#nixos-vm`.
From the repo: `just <target> nixos-vm`.

## Still unverified (deliberately flagged, not silently asserted)

* ~~`boot.initrd.availableKernelModules` is a hand-written guess~~ — **resolved
  below**: the module that matters on this topology is `virtio_pci`, the failure
  was reproduced four ways, and the fix is verified end to end (see
  "Stage 1 on the installed disk").
* ~~`boot.loader.grub.device = "/dev/sda"` rests on the disk-driver identity~~ —
  **confirmed on the installed system**: `findmnt /` = `/  /dev/sda1 ext4
  rw,relatime` and the journal carries `scsi host0: Virtio SCSI HBA`, so the
  `scsi0` + `virtio-scsi-single` disk really does arrive as the guest's first
  SCSI disk at `/dev/sda`, which is what grub-pc writes its MBR to.
* ~~**Still open:** a *plain GRUB* boot of the disk~~ — **closed 2026-10-27**:
  `boot: order=scsi0` with `args:` carrying only the virtfs bind reaches a logged-in
  shell over `/run/qemu-server/100.serial0`, and `/proc/cmdline` read from inside
  that shell is the disk's own GRUB line (see "Plain GRUB boot" below). GPU
  passthrough and CUDA-inside-the-guest stay open (see the incident below).

## Creating the guest (PVE 9 CLI; vmid is POSITIONAL — `qm create --vmid` 400s)

```sh
qm create 100 -name nixos-vm -machine q35 -bios seabios -cores 8 -memory 8192 \
  -scsi0 local-lvm:32 -scsihw virtio-scsi-single -serial0 socket -kvm 1 -cpu host
qm set 100 -net0 virtio,bridge=vmbr0     # bare `virtio` would fall back to -netdev type=user
qm set 100 -boot "order=ide2"            # default order is scsi0;ide2;net0
```
Disk size has no `--size` flag: it is the volume syntax `STORAGE:SIZE_IN_GiB`
(`local-lvm:32` -> thin LV `/dev/pve/vm-100-disk-0`).

## Booting the live ISO (the console problem)

A 1280x800 screenshot of this guest is unreadable to the agent, so the ISO is
booted **through its own kernel over the serial console**: PVE 9 has no
`--kernel/--initrd/--append` option (checked against `qm help create`), so the
raw QEMU escape hatch `args:` carries them, and the ISO's own boot artifacts are
copied out of it first:

```sh
m=$(losetup -fP --show "$ISO"); mount -o ro "$m" /mnt/isomnt
cp /mnt/isomnt/boot/nix/store/ipabfanvi3crlh1zf18ss5fzh6lk1glg-linux-6.18.57/bzImage /var/lib/vz/nixos-boot/linux
cp /mnt/isomnt/boot/nix/store/889s92w6bg5hl8dilb6bq89j4ic5hmi4-initrd-linux-6.18.57/initrd /var/lib/vz/nixos-boot/initrd.img
qm set 100 -args "-kernel /var/lib/vz/nixos-boot/linux -initrd /var/lib/vz/nixos-boot/initrd.img -append \"init=/nix/store/64r05l9i9byrbyncp1067xmxgid90051-nixos-system-nixos-26.05.12707.718f670e8453/init nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf console=ttyS0 console=tty1\""
```
The `-append` line is the ISO's own `isolinux.cfg` `LABEL boot` line plus
`console=ttyS0 console=tty1`; `boot/nix/store/<drv>/` holds the kernel as
**`bzImage`** (not `linux`) and the initrd as `initrd`.

Reading and typing the guest, text only:

```sh
script -q -c 'qm terminal 100' /dev/null            # readable transcript
printf 'cmd\n' | timeout 60 script -q -c 'qm terminal 100' /dev/null
```
Verified live: the guest booted to `Welcome to NixOS 26.05.12707.718f670e8453 (x86_64) - ttyS0`,
`serial-getty@ttyS0.service`, and a real shell prompt.

## Installing (the disk recipe that produces `hardware-configuration.nix`)

```sh
parted -a optimal -m /dev/sda mklabel msdos
parted -a optimal -m /dev/sda mkpart primary 1MiB 100%
mkfs.ext4 -L nixos-vm -m 1 /dev/sda1
mount /dev/sda1 /mnt2
mkdir -p /mnt2/etc/nixos && cp -a /mnt/etc-nixos/. /mnt2/etc/nixos/
nixos-install --root /mnt2 --flake /mnt2/etc/nixos#nixos-vm --no-root-password
```

Verified live (2026-10-27) against this ISO, with the exact failures the naive
recipe hits: `sfdisk` rejects a bare `30G,L` script line (`>>> line 1: unsupported
command`, and it leaves the disk alone — `Leaving.`), so `parted` is what works;
`--boot-environment` is **not** an option of this release (`nixos-install --help`
lists `--root`, `--flake`, `--no-root-password`, `--no-bootloader`, `-I`); and
`/dev/disk/by-label/nixos-vm` **does not exist** after a runtime partitioning —
udev only creates that symlink for partitions probed at boot, so the install
mounts `/dev/sda1` by device and the *installed* system still mounts by
`LABEL=nixos-vm`. The root is `/mnt2`, not `/mnt`, because the 9p share (below)
occupies `/mnt`. Result of that run: `/dev/sda1: LABEL="nixos-vm" ... TYPE="ext4"`,
`df /mnt2` = 32G ext4, `cp-rc=0`.
No swap partition (see `swapDevices = [ ]`), and the ext4 label is the mount
device, so no generated UUID enters the config.

`mkdir -p /mnt2` comes **before** `mount /dev/sda1 /mnt2`: a fresh live boot has
no `/mnt2`, and `mount: /mnt2: mount point does not exist.` sends the whole
install against an empty tmpfs (`INSTALL-RC: 1`, no disk damage) — the failure
mode that cost a round.

## Stage 1 on the installed disk: what failed, and the verified fix (2026-10-27)

Booting the installed generation off `scsi0` timed out waiting for the root:
`[ TIME ] Timed out waiting for device /dev/disk/by-label/nixos-vm.` (90 s),
8× `[DEPEND]`, `Reached target Emergency Mode.` Four attempts, same symptom:

| attempt | tried | observed |
| --- | --- | --- |
| R4 | `availableKernelModules = [ virtio_blk virtio_scsi ]` | timeout |
| R5 | + `initrd.kernelModules = [ sd_mod scsi_mod virtio_scsi ]` | the emergency shell's `lsmod` shows `sd_mod scsi_mod virtio virtio_ring virtio_scsi` **loaded**, yet `/sys/bus/virtio/devices/` is **empty** — disk drivers present, no virtio *transport* to put the disk on a bus |
| R6 | `root=/dev/sda1`, then `root=/dev/sda` in `-append` | `Timed out waiting for device /dev/sda.` — no disk node at all under virtio-scsi |
| R7 | disk moved to a SATA bus (`sata0`) as a control | `sd 6:0:0:0: [sda] 67108864 512-byte logical blocks`, `EXT4-fs (sda1): mounted filesystem … ro` → the root-mount mechanism works when the disk sits on a bus the initrd has a driver for; the following `[FAILED] Failed to start Find NixOS closure.` is the missing-`init=` artifact of a diagnostic `-append`, not a root problem |

The reason, read off the artifacts rather than guessed:

* the installed kernel is **modular** — `…-linux-6.18.56-modules` carries 7296
  modules and includes `virtio_pci.ko.xz`, `virtio_pci_legacy_dev.ko.xz`,
  `virtio_pci_modern_dev.ko.xz` (so naming `virtio_pci` in an initrd list is
  safe: genitools' mod-dependency abort cannot fire);
* the failing generation's initrd cpio held **2116 entries / 57 `.ko`** and
  **zero** `virtio_pci` — `virtio`, `virtio_ring`, `virtio_blk`, `virtio_scsi`
  were all present, the transport was not (`boot.initrd.kernelModules` alone
  was *not* enough, which is why R5 stayed broken);
* the diagnostic `-kernel` boot (`/tmp/boot3.log`, 85074 B / 1124 lines)
  registered SCSI only as `scsi host0…host5: ahci` — virtio-scsi never appeared
  at initrd time.

Verified fix, in `hardware-configuration.nix`, following this pin's own
precedents (`nixos/modules/hardware/proxmox-image.nix:351-355`,
`virtualisation/vz-vm.nix:227-234`, `virtualisation/digital-ocean-config.nix:54-58`):

```nix
boot.initrd.availableKernelModules = [ "virtio_blk" "virtio_pci" "virtio_scsi" "scsi_mod" "sd_mod" "sr_mod" ];
boot.initrd.kernelModules = [ "virtio_pci" "virtio_scsi" "scsi_mod" "sd_mod" ];
```

After it, the new initrd holds **2119 entries / 64 `.ko`** and names
`virtio_blk.ko virtio.ko virtio_pci.ko virtio_pci_legacy_dev.ko
virtio_pci_modern_dev.ko virtio_ring.ko virtio_scsi.ko`, and the same
diagnostic boot of the *new* artifacts reaches
`[ OK ] Reached target Multi-User System.` followed by `nixos-vm login:` with
no device timeout and no emergency mode (`/tmp/boot5.log`, 12839 B / 259 lines).

Two facts the proof leans on, both verified, and what each one now says about the
config:

* `console=` **ordering**: the last `console=` wins for userspace stdout. The
  installed GRUB line the config used to emit ends `console=ttyS0 console=tty1`,
  so a plain disk boot sends userspace — getty included — to tty1, and a capture
  of `/run/qemu-server/100.serial0` over such a boot read `TOTAL-BYTES: 0`
  (`/tmp/boot7.log`, `/tmp/boot8.log`, 2026-10-27); the same kernel+initrd pair
  re-booted with `console=ttyS0` **last** printed the whole stage-1 trace and
  `nixos-vm login:` into that same socket (`/tmp/boot9a.log`, 12479 B / 251 lines),
  and the login typed over it then answered. That is a config setting, not only a
  diagnostic crutch: `boot.kernelParams` now lists `console=tty1` **first** and
  `console=ttyS0` last, which is what makes the real GRUB boot readable and
  loggable-in over the socket the host has. It moved the pin (see the pin block).
* `root=fstab` on the kernel cmdline is **not** this config's doing — the live
  ISO's own `/proc/cmdline` carries `nohibernate root=fstab` too, so the flag is
  NixOS live/ISO tooling. What it resolves to, read from inside the installed
  system: `cat /etc/fstab` = `LABEL=nixos-vm / ext4 x-initrd.mount 0 1`, and
  `findmnt /` = `/dev/sda1 ext4 rw,relatime`. (`/etc/fstab` is a symlink chain —
  `/etc/fstab` → `/etc/static/fstab` → `/nix/store/<…-etc>/etc/fstab`, itself a
  53-byte symlink to `/nix/store/82zp4ll5vfgrapw9wnn1d8s9y4zxv7lh-etc-fstab`,
  293 B. Read off the PVE **host** through a losetup mount, `cat` on that symlink
  path fails — `cat: …: No such file or directory` — because the symlink's target
  is an absolute `/nix/store` path the Proxmox host does not have; the file next
  to it is readable.)

## Login path on the installed system

Root stays **locked** (`/etc/shadow` read off the installed disk: `root:!:`), and
that is this pin's default: setting `users.users.root.password` does not
unlock it, because `nixos/modules/config/users-groups.nix` applies a password
"only when the user is created for the first time" while
`users.mutableUsers` is true (the default, never set false in this repo), and
root already exists in the install chroot. `nixos-install --no-root-password`
is **not** the culprit — this pin's own
`pkgs/by-name/ni/nixos-install/nixos-install.sh:96` only skips the interactive
`passwd` call. A declared ordinary user *is* created at activation, so its
password lands; `users.users.nixos-vm` (wheel, fixture password) is the
console login path, and `sudo -i` is how root is reached.

## The installed system, read over the serial socket (2026-10-27, verified)

After the R9 install (guest built `fwjb096r4qmx1dhhksar8njb7d9rc4ah…drv` exactly),
`/etc/shadow` read off the installed disk is:

```
root:!:1::::::
nixos-vm:$6$tQpJeCKW$Oe4PH…:1::::::
```

— root still locked, the declared ordinary user hashed. Booting that generation
with `console=ttyS0` last, one capture of `/run/qemu-server/100.serial0`
(`/tmp/boot9a.log`, 12479 B / 251 lines) ends:

```
Welcome to NixOS 26.11 (Zokor)!
<<< Welcome to NixOS 26.11.20261016.f20cd90 (x86_64) - ttyS0 >>>
nixos-vm login:
```

and typing `nixos-vm` / `nixos-vm-guest` into that socket answers a shell — no
`Login incorrect`, no `Maximum number of tries exceeded`. From that shell
(`/tmp/boot9b.log`, 7551 B):

| command | result |
| --- | --- |
| `uname -a` | `Linux nixos-vm 6.18.56 #1-NixOS SMP PREEMPT_DYNAMIC @1791725172 x86_64 GNU/Linux` |
| `findmnt /` | `/  /dev/sda1  ext4  rw,relatime` |
| `cat /etc/fstab` | `LABEL=nixos-vm / ext4 x-initrd.mount 0 1` |
| `systemctl is-system-running` | `running` (not `degraded`) |
| `systemctl --failed` | `0 loaded units listed.` |
| `lsmod` | `virtio_pci 65536 0`, `virtio_pci_legacy_dev`, `virtio_pci_modern_dev`, `virtio_scsi`, `virtio_ring`, `virtio_net`, `9pnet_virtio` all resident |
| `journalctl -b -a --no-pager --grep virtio` | `virtio_scsi virtio3: 8/0/0 default/read/poll queues`, `scsi host0: Virtio SCSI HBA`, `systemd-modules-load Inserted module 'virtio_scsi'`, `virtio_net virtio2 ens18: renamed from eth0` |

So stage 1, stage 3, the login, and the virtio transport are all verified on the
installed system; what remains unverified is a **plain GRUB boot** of the disk
(no `-kernel`/`-initrd`/`-append`), which is owed to the console-ordering edit
above: with `console=ttyS0` last the socket should read that `nixos-vm login:`
line on its own.

One asymmetry to keep in mind when reading a capture: this silence is not a stall
on a **live** boot. The 26.05 live pin sets `serial-getty@ttyS0` off
(`profiles/headless.nix`, `enable = lib.mkDefault false`), so a live boot prints
stage-1 on ttyS0 and then reads `TOTAL-BYTES: 0` forever — there is no serial
login there to answer, and live userspace is only reachable on tty1 by `sendkey`.
The installed config's explicit `serial-getty@ttyS0` activation is what produces
the `login:` above.

### Plain GRUB boot — no `-kernel`/`-initrd`/`-append` (2026-10-27, verified)

With `boot: order=scsi0` and `args:` reduced to exactly

```
-virtfs local,path=/var/lib/vz/shared,mount_tag=s,security_model=passthrough
```

the disk's own GRUB booted the new generation and the same socket carried stage 1
(`/tmp/boot11a.log`, 11220 B: `Booting initrd of NixOS 26.11 (Zokor) (Initrd)`,
`Expecting device /dev/disk/by-label/nixos-vm…`, `[ OK ] Started serial-getty@ttyS0.service.`)
and `/tmp/boot11b.log` carried the login. From inside that shell:

```
$ cat /proc/cmdline
BOOT_IMAGE=(hd0,msdos1)/nix/store/nh11qhhmdywbiqycrrzx3ag6wbq505pq-linux-6.18.56/bzImage init=/nix/store/79fa4aridyzpgjkmgn82yfb300d6mc9c-nixos-system-nixos-vm-26.11.20261016.f20cd90/init console=tty1 console=ttyS0 root=fstab loglevel=4 lsm=landlock,yama,bpf
$ readlink /run/current-system
/nix/store/79fa4aridyzpgjkmgn82yfb300d6mc9c-nixos-system-nixos-vm-26.11.20261016.f20cd90
$ uname -a            ; findmnt /
Linux nixos-vm 6.18.56 #1-NixOS SMP PREEMPT_DYNAMIC @1791725172 x86_64 GNU/Linux
/      /dev/sda1 ext4   rw,relatime
$ systemctl is-system-running ; systemctl --failed --no-pager
running                              0 loaded units listed.
$ ls /dev/disk/by-label
nixos-minimal-26.05-x86_64  nixos-vm
```

`/run/current-system` is the **outPath of the pin above**, and `init=` on the
disk's cmdline names the same store path — the running system *is* what the repo
evaluates, reached through GRUB rather than through a `-kernel` shortcut. `nixos-install`
built `4p2iipl35vs08lvbkkj1hp3qsq47l517-…drv` (R10, `INSTALL-RC: 0`, GRUB reinstalled
on `/dev/sda`).

Two console facts that this round settled:

* A capture window has to be long enough — `sr3.py` capped at 60 s and the login
  prompt appeared after it, at which point `sx2.py` (which reconnects and drains
  before each command) read the prompt and answered it. A short capture is not a
  hang.
* There is **no `/mnt` on the installed system** (the live ISO has one, this config
  does not create it): `ls /mnt` → `ls: cannot access '/mnt': No such file or
  directory`, and `mount` refuses before it even looks (`must be superuser to use
  mount`). Bridging the installed system means `sudo mkdir -p /mnt` and then
  `sudo mount -t 9p -o cache=none s /mnt`; declaring it in the config is the
  durable version.

## Guest sizing: "as much RAM as the host allows"

There is **no `max=` memory knob in PVE 9.2**: `/usr/share/perl5/PVE/QemuServer/Memory.pm`
defines `memory_fmt` with a single key — `current` (`minimum => 16`, `default => 512`) —
and the *address-space* ceiling is derived from the CPU's `phys-bits`
(`get_max_mem`, which calls `get_host_phys_address_bits()` for `cpu: host`), not from a
config field. So the whole operation is `qm set 100 -memory <MiB>`.

The arithmetic that bounds it, read off the host:

| | |
| --- | --- |
| host `MemTotal` | `128707 MiB` (`free -m`) |
| applied value | `memory: 122880` (120 GiB) → **5827 MiB** of headroom for PVE + QEMU |
| the value now preferred | **`114688` (112 GiB) → ~14 GiB headroom** |

122880 is the literal "as much as possible" and it is what is currently written in
`/etc/pve/qemu-server/100.conf`. It is **not** the value to keep: with 5.7 GiB left for
the host's own ~3.8 GiB plus QEMU's mapping overhead, the box has no working room —
see the incident below. Say which one you want before re-applying.

## GPU passthrough — what is verified on this host

The card: `0a:00.0 NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:2684] (rev a1)`.
It is driven by **`nouveau`** (`readlink /sys/bus/pci/devices/0000:0a:00.0/driver` ->
`../../../../bus/pci/drivers/nouveau`); there is no `nvidia-smi` and no NVIDIA kernel
module on the host.

PVE 9.2 has the passthrough feature first-class — `--hostpci[n]` with
`driver=<vfio|keep>`, `mdev=`, `romfile=`, `rombar=` (`qm help set`, and
`PVE/QemuServer/PCI.pm`). `prepare_pci_device` either (a) binds the device to **vfio**
(the default), or (b) with `mdev=nvidia-<type>` uses PVE's **NVIDIA mediated-device**
path — which needs `/sys/bus/pci/devices/<id>/nvidia/creatable_vgpu_types`, and that
node **does not exist on this host** (`ls: No such file or directory`; it comes from
NVIDIA's own kernel module, and `PVE::RS::NVML` queries it). So the NVIDIA-native route
is not available while the host runs `nouveau`; only the generic vfio bind is.

BAR geometry (`lspci -vvs 0a:00.0`): **Physical Resizable BAR** at `[bb0]`, BAR 1
current 256 MB with supported `64MB 128MB 256MB 512MB 1GB 2GB 4GB 8GB 16GB 32GB`. A
BAR above 2 GiB has to be mapped in the guest's high address space, which SeaBIOS
cannot do — it needs `bios: ovmf` (`OVMF_CODE_4M.fd`/`OVMF_VARS_4M.fd` are present,
`pve-edk2-firmware-ovmf 4.2026.08-1`), and that in turn means giving up the direct
`-kernel` boot that made the console readable.

## INCIDENT: the host froze when the vfio bind was attempted — read before retrying

Order of events, with the evidence:

1. `qm set 100 -memory 122880` and `qm set 100 -hostpci0 0a:00.0,pcie=1` both
   reported success, and `qm config 100` read both lines back.
2. `qm stop 100` / `qm start 100` was launched; it has produced **no output at all**
   and has not returned in tens of minutes.
3. Every host-side channel went dead at that moment: `ssh` connects on `:22`
   (`debug1: Connection established`) but the server never sends its banner —
   `Connection timed out during banner exchange`. The host's own HTTP probe server
   on `:60080` accepts the connection (`time_connect=0.0005`) and returns **zero
   bytes** in 25 s. PVE's API daemon on `:8006` will not even complete a connect.
4. `nmap -Pn -p 22,60080,8006` reports all three `open` at 0.4 ms latency, so the
   **kernel and its sockets are alive**; nothing in userspace makes progress.

Most likely cause: `prepare_pci_device` bound a **card the `nouveau` driver still
owns** to vfio and then hard-reset it (`pci_dev_reset`) — resetting a device in use
by an active DRM driver is the path that hangs; the loaded `gpu_sched`/`drm_gpuvm`
symbols in `lsmod` are in that same driver. The oversized 120 GiB guest is the
second suspect (a swap storm fits the same symptom). Either way the effect is the
same: the PVE host is frozen and only a power-cycle / reset of it restores it.

**On the host's next boot this re-attempts the bind** — the `hostpci0:` line is
already in `/etc/pve/qemu-server/100.conf` and PVE restores guests that were running
at shutdown. First command after the host comes back, before anything else:

```sh
sed -i '/^hostpci0: /d' /etc/pve/qemu-server/100.conf
qm stop 100
qm set 100 -memory 114688          # ~14 GiB headroom, not 5.7
```

Then, if and when the GPU is re-attempted, the order that does not repeat the hang:

```sh
modprobe -r nouveau                                    # free the card from the host driver
printf 'blacklist nouveau\noptions nouveau secure_touch=0\n' >/etc/modprobe.d/99-no-nouveau.conf
pvesh get /devices --full                              # what PVE itself sees: mdev types per device
qm set 100 -bios ovmf                                  # resizable BAR needs EFI, not SeaBIOS
qm set 100 -hostpci0 0a:00.0,pcie=1                    # generic vfio bind
```

Honest ceiling on the payoff: vfio hands the guest the raw card, and NVIDIA's
proprietary driver/CUDA over vfio is **not** expected to work as-is — that needs the
ROM-patch projects (`vfio_nvrom`/`nvimm`/`nvvirt`, which require extracting a signed
ROM with `nvflash`), or the NVIDIA-mdev route, which requires installing NVIDIA's
kernel module **on the PVE host** and drops `nouveau` entirely. Also: while the guest
holds the card, the **host** can no longer use it. Nothing about the guest-side NVIDIA
stack is asserted in `default.nix` — see the comment there.

## Option A: make the box itself native NixOS (2026-10-28 — staged, NOT executed)

Chosen over staying on PVE: it retires `vfio`/NVRAM patching entirely and gives the
4090 a native card, and it makes reproducibility stronger — one flake builds the host
and the guest. It is a **one-way door**, so the staging below is separated from the
destructive act.

### Verified host topology (read, not assumed)

* `nvme0n1` 931.5G, booted EFI: `p1` 1007K, `p2` 1G vfat = `/boot/efi`, `p3` 930.5G
  LVM2 → VG `pve` = `pve-root` 96G, `pve-swap` 8G, `pve-data` 794.3G, **`pve-vm-100-disk-0`
  32G**, `VFree` 16.00g.
* `/dev/sda` = SanDisk Cruzer Glide 29.8G, **Ventoy**, MBR: `sda1` exfat label
  `Ventoy` (start 2048, size 31981076480, PARTUUID `42dfc3ef-01`), `sda2` vfat
  `VTOYEFI` (start 122002 sectors, size 65536, PARTUUID `42dfc3ef-02`).
* The stick boots **legacy/CSM** today — there was no EFI entry for it.
* Host network is static, not NetworkManager: `/etc/network/interfaces` `vmbr0`
  `address 192.168.5.186/22`, `gateway 192.168.4.1`, `bridge-ports enp4s0`.
* The host has **no nix at all** (`/nix/store` absent) — the flake lives on the jail
  machine and on the guest, never on the PVE box.

### Staged on the stick (all of it survives the wipe; verified by hash)

`/mnt/vtoy` = rw mount of `sda1`:

* `nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso` — the **pinned** live
  image, sha256 `12f093ce7bf7e9747c67730ee3cc7b22713912382e8d3d6f27ef6b19afd8c800`
  (byte-identical to the PVE ISO dir).
* `isos/` now holds the 3.8G `nixos-graphical-…` image, so the pinned ISO is the
  **only** ISO at the stick root — Ventoy's default selection cannot drift.
* `repo/` = the guest flake dir; `default.nix` md5 `a76529b99a5ba726153e92a44477c555`,
  `hardware-configuration.nix` md5 `7c8f0eb3ef8c0db63c54d034963355e6` — identical to
  the repo in `/etc/nixos`, i.e. the guest is rebuildable from media that survives.
* `ventoy/ventoy.json` md5 `de8c6d527dcf71926be40cb06e032d38` and
  `ventoy/conf/nixos-pinned.cfg` md5 `dc34b0a9395658110a53f0202ed9a77b`.

### How the live image must be booted, read from the ISO itself

Loop-mounted the pinned ISO read-only. Its layout is `boot/nix/store/…`, `isolinux/`,
`nix-store.squashfs`; the EFI config is `/EFI/BOOT/grub.cfg` (**there is no
`/boot/grub/grub.cfg` inside the ISO**). The LTS stanza:

```
linux /boot//nix/store/ipabfanvi3crlh1zf18ss5fzh6lk1glg-linux-6.18.57/bzImage ${isoboot} \
      init=/nix/store/64r05l9i9byrbyncp1067xmxgid90051-nixos-system-nixos-26.05.12707.718f670e8453/init \
      nohibernate root=fstab loglevel=4 lsm=landlock,yama,bpf
initrd /boot//nix/store/889s92w6bg5hl8dilb6bq89j4ic5hmi4-initrd-linux-6.18.57/initrd
```

with `set isoboot="findiso=${iso_path}"`. Both `findiso=` and `init=` are load-bearing.

### Ventoy's own mechanism, read from `/mnt/vtefi/grub/grub.cfg` (89651 B)

* `grub/distro/` holds only `fwts.cfg` — **no NixOS entry**; the generic
  `locate_initrd`/`distro_specify_initrd_file` probe list has no `/boot/nix/store/*`
  pattern, so betting on Ventoy's NixOS autodetection is not acceptable here.
* `ventoy_vcfg_proc` (L65) runs **before** distro detection inside every
  `*_common_menuentry` and, when a per-ISO custom boot config is registered, does
  `configfile "${vtoy_iso_part}${vt_vcfg}"` and returns — that is the deterministic
  lever: `boot_conf_replace` maps our ISO to our own USB-side stanza
  (`dst` = `/EFI/BOOT/grub.cfg`, `src` = `/ventoy/conf/nixos-pinned.cfg`).
* `ventoy_ext_menu` reaches `ventoy_grub.cfg` only through a keypress (F6) — unusable
  for an unattended boot.

**Unverified**: the `boot_conf_replace` JSON key nesting was taken from Ventoy
documentation mirrored off-site (the official index 404s), and `ventoy_x64.efi`/
`ventoy.cpio` are compressed so no key names could be recovered from the engine. If
Ventoy ignores that key, the fallback that still works is the single-root-ISO default.

### NVRAM, armed one-shot (safe by construction)

`efibootmgr` 18 (no `--set-next`; loader path is `-l`, `-f` is `--reconnect`):

```
efibootmgr -c -d /dev/sda -p 2 -L VentoyPinned -l '\EFI\BOOT\BOOTX64.EFI'
efibootmgr -o 0000,0004,0003,0005          # order restored to its original value
efibootmgr -n 0001                          # BootNext, one boot only
```

`Boot0001* VentoyPinned HD(2,MBR,0x42dfc3ef,0x3b92440,0x10000)/File(\EFI\BOOT\BOOTX64.EFI)`
— the device path matches the computed geometry exactly (sda2 = LBA 0x3b92440, 0x10000
sectors). So exactly one reboot lands on the stick; every other reboot still boots PVE.

### What the wipe destroys, and what the recovery path is

Destroying `nvme0n1p3` + VG `pve` deletes `pve-root`, `pve-swap`, `pve-data` and
`pve-vm-100-disk-0` — the installed guest and the ISO dir. `VFree` is only 16.00g, so
PVE cannot be kept alongside. The guest's only recovery path is a **rebuild from the
pinned repo**, which survives on the stick and on the jail machine; the pin
(`/nix/store/4p2iipl35vs08lvbkkj1hp3qsq47l517-nixos-system-nixos-vm-26.11.20261016.f20cd90.drv`
→ out `79fa4aridyzpgjkmgn82yfb300d6mc9c…`) is the identity that rebuild must reproduce.

### Reachability once the box is live (facts, then the open question)

The live image enables sshd (`mkDefault true`, `PermitRootLogin yes`) and NetworkManager,
but **both live accounts have empty passwords**, and NM may not reproduce PVE's static
`vmbr0` (`192.168.5.186/22` via `enp4s0`, gateway `192.168.4.1`). So after the reboot:
probe the wired network from the jail with `nmap`/`masscan` for an open `:22`, and fix
authentication at the console (`sudo passwd nixos`) — until a native config declares a
password and a key.

### Next steps (the destructive one is gated on explicit user confirmation)

1. reboot → `BootNext` boots the stick → confirm the pinned ISO boots with our stanza.
   The first arm (`efibootmgr -c … → Boot0001`, `BootNext: 0001`) was consumed by the
   firmware but did **not** boot: `-c` writes a bare `HD(2,MBR,…)` node and this firmware
   resolves removable media only through the full device path, so it fell back to
   `Boot0000` (PVE). Fixed by arming the firmware's own discovery entry —
   `Boot0007* UEFI: SanDisk Cruzer Glide 1.26, Partition 2` — with `efibootmgr -n 0007`.
   Full details in `hosts/yzerd/README.md` → *The reboot itself, attempt by attempt*.
2. native install onto `nvme0n1p3` reformatted ext4 (`nvme0n1p2` ESP reused, untouched).
3. `hosts/yzerd/` **is now authored** — a self-contained sub-flake (`flake.nix`
   with the pinned nixpkgs rev + its own `flake.lock`, `default.nix`, README),
   exported by the root flake as input `yz-native.url = "path:hosts/yzerd"` and
   re-exported as `nixosConfigurations.yzerd` (attribute and `hostName` both
   `yzerd`, so the box keeps one identity across the mode change). The bootloader
   is **systemd-boot with `canTouchEfiVariables = false`**, not GRUB — see
   `hosts/yzerd/README.md` for why `--variables=no` still leaves the ESP copy that
   the surviving `Boot0004` points at.
4. after the native boot: nothing to do to NVRAM. `Boot0000` (the PVE shim on
   `p2`) goes dead and the BIOS falls through to `Boot0004` = `\EFI\BOOT\BOOTX64.EFI`
   on `p2`, which is exactly where the systemd-boot builder writes its fallback.

### Staged on the stick, and what survived the copy

`/mnt/vtoy/repo-yzerd` (host side of the 9p bridge: `/var/lib/vz/shared/yz-stage`)
— `flake.lock` and all, because exfat cannot own the jail's uid and `cp -a` only
warned about ownership while every md5 matched. Pin at write-time
(`hosts/yzerd/README.md` → *Pin ledger*): `.drv` `srgrfiddhf1lb60d4vld78jy411s4v7n-nixos-system-yzerd-26.11.20261016.f20cd90.drv`,
kernel `nh11qhhmdywbiqycrrzx3ag6wbq505pq-linux-6.18.56`, initrd
`ymxh430m9j4j197m1zx3lf2pdjvbaf1z-initrd-linux-6.18.56`.

The Ventoy keys are now confirmed from upstream ([Global Control plugin](https://www.ventoy.net/en/plugin_control.html)): the auto-select pair is
`{ "VTOY_MENU_TIMEOUT": "n" }` + `{ "VTOY_DEFAULT_IMAGE": "/path/on/the/usb.iso" }`
inside the `control` array — the bare `default_image` spelling in the staged
`ventoy.json` is **not** a documented key, and there is a second menu that defaults
to *waiting* (`VTOY_SECONDARY_BOOT_MENU` is `1` by default with no
`VTOY_SECONDARY_TIMEOUT`). Empirically that is what happened on the box: after the
`BootNext: 0007` reboot the monitor showed a **Ventoy menu** and nothing booted
by itself. The deterministic lever (one ISO at the stick root +
`boot_conf_replace` at `/EFI/BOOT/grub.cfg`) still holds for the pinned cmdline; the
missing piece was auto-selection, and it can be fixed without any NVRAM work:

```json
{
  "control": [
    { "VTOY_MENU_TIMEOUT": "10" },
    { "VTOY_DEFAULT_IMAGE": "/nixos-minimal-26.05.12707.718f670e8453-x86_64-linux.iso" },
    { "VTOY_SECONDARY_TIMEOUT": "10" }
  ]
}
```

Until that is restaged, selecting the entry by hand at the JetKVM is enough —
the menu is a choice, not damage.
