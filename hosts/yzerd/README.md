# yzerd — the physical box, native NixOS (Option A)

The box at `192.168.5.186` used to run Proxmox VE and host `hosts/nixos-vm` as
vmid 100. Option A retires PVE: the box itself becomes NixOS, booted from its own
NVMe, and the 4090 stops being a passthrough subject. This directory is the config
for that box. `hosts/nixos-vm` (the guest) stays as-is and will run on top of it.

Docs are the source of truth: every fact below was read off the live machine, and
every attempt that did not work is recorded with what it proved.

## Verified host topology (read on the PVE-era box, 2026-10-28, before the wipe)

* Boots EFI from `nvme0n1` (931.5G):
  * `nvme0n1p1` 1007K (unused by any mount)
  * `nvme0n1p2` 1G vfat → `/boot/efi` (the ESP; **reused, never reformatted**)
  * `nvme0n1p3` 930.5G LVM2 → VG `pve` (`data` 794.30g, `root` 96g, `swap` 8g,
    `vm-100-disk-0` 32g, VFree 16.00g) — **this is what gets destroyed**
* NVRAM (efibootmgr v18): `BootOrder: 0000,0004,0003,0005`, `BootCurrent: 0000`,
  `Timeout: 1`. `Boot0000` = the proxmox shim (`\EFI\PROXMOX\SHIMX64.EFI` on
  `nvme0n1p2`) — becomes DEAD once p3 is wiped. `Boot0004` =
  `\EFI\BOOT\BOOTX64.EFI` on `nvme0n1p2` — **survives**, and is the entry the new
  system relies on.
* Wired network as PVE had it: `/etc/network/interfaces` `auto vmbr0` /
  `iface vmbr0 inet static` / `address 192.168.5.186/22` / `gateway 192.168.4.1` /
  `bridge-ports enp4s0`. `enp4s0` UP, `enp5s0` DOWN, `wlp6s0` DOWN. No
  NetworkManager on the host, so a fresh NixOS live system must configure wiring
  itself.
* `/dev/sda` = SanDisk Cruzer Glide 29.8G, exfat partition `Ventoy` + `VTOYEFI`
  (that is the stick that now boots the place; Ventoy is legacy-booted via the
  MBR — there is no EFI entry for the USB, only the one we created, `Boot0001`).

## What the config declares, and why each choice is this shape

* `fileSystems."/".device = "LABEL=nixos-native"` — identity by label, created by
  the install step below. No LVM: nothing on the box needs it once PVE is gone.
* `fileSystems."/boot/efi".device = "/dev/nvme0n1p2"` — by device, not label: the
  ESP is reused as-is and its label is upstream's.
* `boot.loader.systemd-boot.enable = true` **with**
  `boot.loader.efi.canTouchEfiVariables = false`. Verified in this nixpkgs pin
  (`nixos/modules/system/boot/loader/systemd-boot/systemd-boot-builder.py`):
  `canTouchEfiVariables=false` appends `--variables=no` to `bootctl install`; the
  ESP copy still happens, including bootctl's fallback binary at `EFI/BOOT/bootx64.efi`
  on `nvme0n1p2`. vfat names are case-insensitive, so that file is exactly what
  `Boot0004` — the entry that survives the wipe — points at. **The box therefore
  boots with no NVRAM edit at all.** GRUB was not chosen for this reason, not
  because of a preference: a GRUB install needs either a BIOS boot partition or an
  EFI-mode install that rewrites NVRAM, and `nvme0n1` has no spare BIOS partition.
* `systemd.network.networks."10-yz-enp4s0"` restates PVE's static ifupdown block
  (peer-with-mask `Address`/`GatewayAddress` is the direct translation of
  ifupdown's `address`/`gateway`), pinned to the real interface name `enp4s0`.
  This keeps ssh reachability at `192.168.5.186` deterministic instead of leaving
  NetworkManager to guess a peer address.
* `services.openssh.enable` + both agent public keys in `authorizedKeys` + a
  declared password: the native box has no serial console and no `qm terminal`, so
  ssh is the only control path and a declared password is the fallback that needs
  no key at all.
* `swapDevices = [ ]` — `pve-swap` is destroyed with p3; declaring no swap keeps
  the image honest about what the box uses.

## Deliberately absent, and why

* **No GPU declaration.** The 4090 becomes native hardware here, but a
  half-configured card (proprietary module absent, nouveau implicit) is worse than
  an absent one. Open question, not asserted: what the card is for once the guest
  runs on this box.
* **No guest-VM unit.** The QEMU argv that replaces vmid 100 is runtime state and
  belongs in a systemd unit — added only once the box boots natively and this
  config's pin is known, so the unit is authored against a real generation.
* **No `hardware-configuration.nix`.** Nothing here is generated: a file produced
  by `nixos-generate-config` on a machine that no longer runs PVE cannot be
  compared against the layout that made it. The devices are declared above instead.

## Installing (run on the live system, not in the jail)

The jail stubs the activating commands (AGENTS.md); the install happens on the
live NixOS that the stick boots. The flake tree for this directory is copied to
the stick at `/repo-yzerd` (see `hosts/nixos-vm/README.md` → *Option A → Staged on
the stick*).

```sh
# The stick itself has to be read by the live system: sda1 is the exfat partition
# that carries /repo-yzerd and the pinned ISO.
mkdir -p /mnt/stick && mount /dev/sda1 /mnt/stick

# p3 destroyed and recreated as one labelled ext4; p2 (the ESP) untouched —
# the surviving EFI boot entry Boot0004 addresses it by geometry.
mkfs.ext4 -L nixos-native /dev/nvme0n1p3

mount /dev/nvme0n1p3 /mnt2
mkdir -p /mnt2/boot/efi
mount /dev/nvme0n1p2 /mnt2/boot/efi

nixos-install --root /mnt2 --flake /mnt/stick/repo-yzerd#yzerd --no-root-password
```

`fileSystems` names only `/` and `/boot/efi`, so nothing else needs creating. The
install needs network to fetch the pinned nixpkgs source (the stick's ISO store
does not contain `f20cd90e…`); that is what the `Address=`/`Gateway=` unit is for,
but during the *live* stage the stock ISO uses NetworkManager instead — see
*Reaching the live system*.

Re-run the `nix eval` pin on the jail machine against `hosts/yzerd` before
committing any edit here:

```sh
cd /etc/nixos
nix eval --raw ".#nixosConfigurations.yzerd.config.system.build.toplevel.drvPath"
```

## Verified by evaluation, 2026-10-28 (rendered artifacts, not Nix attributes)

`nix build .#nixosConfigurations.yzerd.config.system.build.toplevel` realises the
generation; in the jail the output lands under
`/home/llm/.local/share/nix/root/nix/store/…` (the jail's writable-store root), and
`etc` is a symlink farm whose leaves resolve into that same root. Read through it:

```
$ cat etc/systemd/network/10-yz-enp4s0.network
[Match]
Name=enp4s0

[Network]
Address=192.168.5.186/22
Gateway=192.168.4.1
```

That is the whole point of the check: the typed option is `gateway` and it renders
the systemd key `Gateway=`, **not** `GatewayAddress=` (which is not a systemd key at
all); the free-form spelling would have needed `networkConfig`.

`boot.json` in the generation records the artifact identity the installer will
write into the boot entries:

```
kernel      /nix/store/nh11qhhmdywbiqycrrzx3ag6wbq505pq-linux-6.18.56/bzImage
initrd      /nix/store/ymxh430m9j4j197m1zx3lf2pdjvbaf1z-initrd-linux-6.18.56/initrd
init        <toplevel>/init
kernelParams root=fstab loglevel=4 lsm=landlock,yama,bpf
"org.nixos.systemd-boot": { "sortKey": "nixos" }
```

Two facts that follow from it: no `console=` reaches the kernel (the native box is
driven from its own monitor + ssh, there is no serial console), and the
`org.nixos.systemd-boot` stanza confirms the systemd-boot builder — not GRUB —
will run.

`/etc/ssh/authorized_keys.d/b` renders to exactly the two agent keys
(`dsh-agent`, `llm@jail`), and the generated `sshd_config` carries
`PasswordAuthentication yes`, `PermitRootLogin prohibit-password`,
`AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`.
So remote control after the wipe is `ssh -l b 192.168.5.186` with either agent
key — the jail's `Host proxmox-186` line logs in as `root`, which the new box
will **not** accept with a key-only root; use `-l b` or add a Host entry.

## Pin ledger

| date | what | value |
|---|---|---|
| 2026-10-28 | toplevel `.drv` for `.#nixosConfigurations.yzerd`, evaluated on the jail machine **before** the install | `srgrfiddhf1lb60d4vld78jy411s4v7n-nixos-system-yzerd-26.11.20261016.f20cd90.drv` |
| 2026-10-28 | same eval re-run after this README grew (the reboot-attempt log below) — docs only, no config change | `srgrfiddhf1lb60d4vld78jy411s4v7n-nixos-system-yzerd-26.11.20261016.f20cd90.drv` — unchanged, as it must be |
| — | the same toplevel as built on the box itself | **not yet recorded** — the first successful native install records it, and the two must agree |

Evaluated with `nix eval --raw ".#nixosConfigurations.yzerd.config.system.build.toplevel.drvPath"`
from `/etc/nixos`. Note the earlier candidate `lm3hbwh459s1nkzj502vpy63cgnl449q-…`
was the config *before* the networkd/dhcpcd conflict was fixed — superseded, kept
here so the churn is visible rather than hidden.

## Attempts against this config, and what each proved

Nothing has been *installed* from this config yet, but evaluation was not quiet,
and every rejection is the point of the exercise: a made-up option name is
accepted by NixOS only inside raw passthrough, and rejected as an unknown option
otherwise. These were caught at evaluation, not at boot.

| attempt | what nix said | what it proves |
|---|---|---|
| `users.users.b.homeDirectory = "/home/b"` | `The option users.users.b.homeDirectory does not exist`, suggesting `home` | this pin's users module renamed the option; `home` is the spelling |
| `users.users.b.group` left unset (with `users.groups.b = {}`) | assertion: `users.users.b.group is unset. This used to default to nogroup, but this is unsafe.` | a group must be declared explicitly; the silent `nogroup` default was removed in this pin |
| exactly one of `isSystemUser`/`isNormalUser` unset | assertion: `Exactly one of users.users.b.isSystemUser and users.users.b.isNormalUser must be set.` | the user kind is required, not inferable |
| `systemd.network.networks.X.config.Address` / `config.GatewayAddress` | `The option …Address does not exist`, suggesting `canConfig`, `bond`, `cakeConfig` | the free-form `[Network]` attrs live under `networkConfig`, not `config`; the typed `address`/`gateway` list options (verified at networkd.nix L3826/L3835, `types.listOf types.str`) are the spelling used |
| `systemd.network.enable = true` alone | evaluation warning: networkd + `useDHCP = true` + `useNetworkd = false` "can lead to loss of networking" | the backend must be chosen; set `networking.useNetworkd = true` and `networking.useDHCP = false` (both options verified in `tasks/network-interfaces.nix` L1681/L1691) |

## The reboot itself, attempt by attempt (the NVRAM transport)

The stick has to be booted from NVRAM without ever editing `BootOrder`, because the
installed system is supposed to be reached through a firmware entry that nothing
here writes. `-n` (BootNext, one-shot) is the tool; `-l` is the loader label, not a
one-shot flag.

| attempt | what the firmware did | what it shows |
|---|---|---|
| `efibootmgr -c -d /dev/sda -p 2 -L VentoyPinned -l '\EFI\BOOT\BOOTX64.EFI'` → `Boot0001`, then `efibootmgr -n 0001` + reboot | `BootNext: 0001` consumed, `BootCurrent: 0000` — PVE booted again (uptime 2 min, `uname -a` = `7.0.14-26-pve`, `:8006` answering 301) | the entry was **written but not resolvable**: `-c` emits a bare `HD(2,MBR,0x42dfc3ef,0x3b92440,0x10000)` node, and this firmware addresses removable media through its device path — the same partition as `Boot0007* UEFI: SanDisk Cruzer Glide 1.26, Partition 2` = `PciRoot(0x0)/Pci(0x1,0x2)/Pci(0x0,0x0)/Pci(0x8,0x0)/Pci(0x0,0x3)/USB(3,0)/HD(2,MBR,0x42dfc3ef,0x3b92440,0x10000)` |
| `efibootmgr -n 0007` + reboot | pending observation | use the firmware's **own** discovery of the stick instead of an entry we hand-assemble; BootOrder untouched, one-shot only |

The wipe had not happened in either case — the first reboot fell back to `Boot0000`
(the PVE shim on `p2`), so the box stayed PVE and remained sshable while this was
diagnosed. Note the contrast that keeps the *installed* system's plan intact: a bare
`HD(2,GPT,ae4fb41e-…,0x800,0x200000)` node **does** resolve, because that is
`Boot0000` and `BootCurrent: 0000`; the unresolvable one was a bare node on the
**USB** disk. Internal-NVMe entries of that shape are fine, so `Boot0004` (the
planned post-install boot path) needs no device-path fixup.

Also visible: the reboot made the firmware add `0006`/`0007`/`0008` for the USB
(`BootOrder` became `0000,0004,0003,0005,0006,0007,0008`) — the discovery entries
exist only after a boot with the stick inserted, which is why they were not there
before the first reboot.

## Reaching the live system (what has to happen at the monitor)

The stock live ISO enables sshd (`mkDefault true`, `PermitRootLogin yes`) and uses
NetworkManager, **not** networkd, so during the live stage nothing yet pins the
box to `192.168.5.186` — the address it answers can move. The new config's static
unit only exists *after* the install. So the live stage is found, not assumed:

```sh
# from the jail: price every candidate address for an open ssh socket
timeout 120 masscan -p22 192.168.5.0/24 192.168.4.0/24
```

What the live ISO will not do is hand us a key by itself — `users.users.nixos`
there has an empty password and no authorized key, so the first step has to be
typed at the monitor. One console line, either a password or our key:

```sh
sudo sh -c 'echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIDKuUwgF6tCaTogYB+/iP5HH/G9v3/fuNfFh1lpoQqm dsh-agent" > /etc/ssh/authorized_keys.d/root'
```

(`%h/.ssh/authorized_keys.d/%u` is in the ISO's own `AuthorizedKeysFile`, same
module, so the file needs no mode play and no home directory.) Then the jail can
take over: `ssh -o BatchMode=yes root@<found-address> 'uname -a; ss -lntp'`.

Measured, not assumed: `masscan` will not run from the jail (`FAIL: permission
denied … need to sudo` — a privileged probe it needs and the jail will not give),
so the read that works is a plain `nc` banner sweep, and it found **no sshd at all**
over `192.168.5.1-254` or `192.168.4.1-60` after the `BootNext: 0007` reboot.
`192.168.4.1` itself answers `Connection refused` on `:22` (the LAN is there, no
socket) while `192.168.5.186` answers `No route to host` (that network no longer
exists) — PVE is definitively not what booted.

Unverified: whether an empty live-ISO password is accepted by sshd's PAM path —
do not plan around it, plan around the console line above.

### Making the install need no network at all

`hosts/yzerd/flake.lock` carries exactly two nodes — `root` and `nixpkgs` — so the
pinned GitHub fetch is the *only* network input the install has. Pre-seeding the live
store with that single path makes evaluation offline; the path is 209733232 B unpacked,
and the jail exported it as:

```text
/home/llm/offline-seed/nixpkgs-f20cd90.nar.xz   34703312 B   md5 5e86e8f13b8be035a1642d33c3875c00
```

Verified of that artifact: `xz -t` returns 0 and `nix-store --query` resolves
`/nix/store/glw7ngr0dwbp3al07rdlqkrbas7w3a02-source` in the jail store, so the dump is
the same content-addressed path the pin names. On the live box, once the stick is
mounted at `/mnt/stick`:

```sh
xzdc /mnt/stick/offline/nixpkgs-f20cd90.nar.xz | nix-store --restore /nix/store/glw7ngr0dwbp3al07rdlqkrbas7w3a02-source
```

That `--restore` has **not been run anywhere** — plan, not result; if it fails, the
fallback is the wired LAN, which the box needs for one fetch only. Everything else the
install builds locally — the kernel and world on this pin, the same 1-2 h of
compilation the guest already paid. Staging the artifact to `/mnt/stick/offline` is
pending: the 9p bridge is unreachable while the box is booted off PVE.

## Alternative boot paths considered (not taken)

* **PXE.** The NVRAM has a Realtek PXE entry (`Boot0005`) and the user offered it
  as possibly the better route. Not taken: the Ventoy stick was already staged
  with the pinned ISO and a per-ISO `boot_conf_replace` stanza, and `BootNext`
  made one reboot consume it deterministically. A PXE path would need a live
  `inetd`-served `config.ds` on the network plus an Ethernet that networkd owns —
  more moving parts to keep remote, for the same first boot. Recorded as the
  fallback if the Ventoy stanza proves wrong.
* **GRUB instead of systemd-boot** — rejected for a reason grounded in the pin,
  not preference: it needs a BIOS boot partition (nvme0n1 has none spare) or an
  EFI-mode install that rewrites NVRAM, whereas `bootctl install --variables=no`
  lands `EFI/BOOT/bootx64.efi` on the ESP partition whose EFI entry survives the
  wipe.

## Failed attempts and open questions

Nothing has been *installed* from this config yet. Open, in the order they
matter:

1. **Reachability of the live stage — measured, not solved.** After the `BootNext: 0007`
   reboot, `192.168.5.186` answers nothing (`No route to host` from the jail, `:8006`
   returns `000`), and an `nc`-banner sweep of **`192.168.5.1-254` and `192.168.4.1-60`
   found no sshd at all**. So either the live system booted with no network (NetworkManager
   on the stock image does not reproduce PVE's static wiring, and the wired router here
   hands out `192.168.4.x` only after it is configured), or the stick did not boot and
   the box is sitting somewhere unreachable. The monitor is the only ground truth:
   `sudo ip -brief a`, `uname -a`, then the authorized-keys line and the
   `ip addr/route` lines that re-pin `192.168.5.186/22` via gateway `192.168.4.1`
   (both are printed above in *Reaching the live system*).
2. **Whether `bootctl install --variables=no` really lands `EFI/BOOT/bootx64.efi`**
   in this systemd version — read from the pin, not yet observed on the box.
   If it does not, the fix is an explicit copy to that path, not an NVRAM edit.
3. **GPU decision** (see above).
4. **Guest VM unit** on the native host (the replacement for vmid 100).
5. **Staging is currently stale on the stick.** Both READMEs grew after the last
   copy, so `/mnt/vtoy/repo-yzerd/README.md` carries `fa4d3248ae94e7ed1cb480d482681736`
   and `/mnt/vtoy/repo/README.md` carries `d57faca0a524d7d4066811a0144ff871`, both behind
   the jail (the jail values move with every doc edit; read them with
   `md5sum hosts/yzerd/README.md hosts/nixos-vm/README.md` at copy time — the pair at the
   time of this note was `f7c292db5b54c1fb88df956e86b28e2f` / `eec42a85554cbe160af53ddff1965c14`).
   The 9p bridge is unreachable while the box is booted off PVE (`ssh proxmox-186` →
   `No route to host`), so restaging waits until the box answers again. `default.nix`,
   `flake.nix` and `flake.lock` on the stick still match the jail byte for byte, and
   re-evaluation with the edited README in place reproduced
   `srgrfiddhf1lb60d4vld78jy411s4v7n-nixos-system-yzerd-26.11.20261016.f20cd90.drv`, so
   README text sits outside the build's input closure — the docs lag, the config does not.

