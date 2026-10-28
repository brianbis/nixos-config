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

nixos-install --root /mnt2 --flake /mnt/stick/repo-yzerd#nixosConfigurations.yzerd --no-root-password
```

`fileSystems` names only `/` and `/boot/efi`, so nothing else needs creating. The
install needs network to fetch the pinned nixpkgs source (the stick's ISO store
does not contain `f20cd90e…`) — unless the offline seed described in
*Making the install need no network at all* is staged and restored first. During the
*live* stage the stock ISO uses NetworkManager instead of networkd — see
*Reaching the live system*.

### The one-shot driver (what actually runs)

`hosts/yzerd/go-native.sh` is the committed, linted (`bash -n`, `sh -n`, shellcheck
clean modulo `SC2012` style infos) version of the snippet above, with guards and
evidence around it: it refuses to touch `p3` unless the literal `WIPE` is passed,
refuses a second wipe of an already-ext4 `p3` unless `FORCE-EXT4` is added, restores
the offline seed when present (that `nix-store --restore` is still plan-only — it has
never run), and prints an RC marker after every step plus the three reads that close
the open questions: whether the realized generation equals the recorded pin's out
path, whether `EFI/BOOT/bootx64.efi` appeared on the ESP, and whether `authorized_keys.d/b`
and the `10-yz-enp4s0.network` unit exist in the fresh tree. It runs on the live box:

```sh
ssh -o BatchMode=yes -l root 192.168.5.186 'cat > /root/go-native.sh' < go-native.sh
ssh -o BatchMode=yes -l root 192.168.5.186 'sh /root/go-native.sh WIPE' 2>&1 |
  tee /mnt/stick/native-install.log
```

Adding that file to `hosts/yzerd/` did **not** churn the pin (`srgrfidd…` re-evaluated
identical after it was committed) — the same proof as the README's: only the files
nix actually reads feed the build.

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
| 2026-10-28 | same eval re-run after `hosts/yzerd/go-native.sh` was **added and committed** (a new file inside the `path:hosts/yzerd` input tree) | `srgrfiddhf1lb60d4vld78jy411s4v7n-nixos-system-yzerd-26.11.20261016.f20cd90.drv` — unchanged: the input tree's hash moves, the build closure does not, because nix only reads `default.nix` |
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
| `efibootmgr -n 0007` + reboot | the monitor showed a **Ventoy menu** and nothing proceeded by itself; the jail-side sweep then found no sshd anywhere and `192.168.5.186` = `No route to host` | the stick **did** boot through the firmware-discovered USB entry (`Boot0007`), so the device-path theory is confirmed and the USB transport works. What failed is Ventoy's *selection*: the staged `ventoy.json` used a `default_image` key that upstream does not document — the real pair is `VTOY_MENU_TIMEOUT` + `VTOY_DEFAULT_IMAGE` in the `control` array (plus a `VTOY_SECONDARY_TIMEOUT`, since `VTOY_SECONDARY_BOOT_MENU` defaults to `1` and waits). Nothing was wiped: `p3` still holds PVE, and the box is now reachable only at the monitor |
| third reboot — corrected `ventoy.json` staged, `efibootmgr -n 0007` (`BootNext: 0007`), `systemctl reboot` | the jail read the PVE door dead (`http://192.168.5.186:8006/` → `000` / 0 bytes) and `192.168.5.186` = `Connection timed out` instead of `No route to host` | the box left PVE, so the live ISO booted: the corrected `control` array did its job (5 s timeout + default image + secondary menu disabled). Nothing listens at the pinned address because the live image configures no static address — that is the `ip addr add`/`ip route add` block below, not a boot failure |

Between the second and the third reboot the box was power-cycled by hand (the monitor
moved from the dead DisplayPort connection to HDMI) and came back to **PVE on its own**:
`BootCurrent: 0000`, `/dev/nvme0n1p3` still `LVM2_member`, ssh at `.5.186` answering
`Remote protocol version`, `:8006` returning 301. Nothing has ever been wiped, and
`BootNext: 0007` was re-armed after that return rather than before it.

### The Ventoy config that was staged, and what upstream says about it

The file that produced the waiting menu (`/mnt/vtoy/ventoy/ventoy.json`, 358 B, md5
`de8c6d527dcf71926be40cb06e032d38`) had two independent defects, both checked against
upstream rather than guessed:

* `control` is upstream an **array of single-key objects with string values** —
  `[ { "VTOY_MENU_TIMEOUT": "10" }, { "VTOY_DEFAULT_IMAGE": "/ISO/debian_netinstall.iso" } ]`
  ([plugin_control](https://www.ventoy.net/en/plugin_control.html)). The staged file used an
  *object* holding `default_image` and `timeout` — neither name appears in that key list, so
  the plugin read nothing at all and the menu waited. `VTOY_MENU_TIMEOUT` is the auto-select
  timer and `VTOY_DEFAULT_IMAGE` the image it selects (the path as Ventoy lists it), and with
  a timeout set and no default image the **first** image boots.
* The secondary boot menu — the special-mode menu Ventoy shows since 1.0.80
  ([doc_secondary_boot_menu](https://www.ventoy.net/en/doc_secondary_boot_menu.html)) — is
  disabled by the documented `VTOY_SECONDARY_BOOT_MENU` control key, which the staged file
  never mentioned; the docs' advice to set a `VTOY_SECONDARY_TIMEOUT` was never verified
  against that page, so the staged file uses only the disable instead.
* The replacement stanza was named `boot_conf_replace` with `dst`/`src` fields. The plugin key
  is `conf_replace` (or `conf_replace_uefi` / `conf_replace_legacy`) and the fields are `iso`,
  `org`, `new` ([plugin_bootconf_replace](https://www.ventoy.net/en/plugin_bootconf_replace.html))
  — and that page's own example replaces exactly `/EFI/BOOT/grub.cfg`, which is what the ISO
  really carries (loop-mounted and listed this round: `/EFI/BOOT/grub.cfg` 20459 B,
  `/isolinux/isolinux.cfg` 9159 B). So the staged stanza was **inert**: nothing was replaced.
  It is now not staged at all — with `control` fixed the boot was attempted with no
  `conf_replace`, because whether Ventoy hands that replaced file to the ISO's own grub in
  UEFI mode is untested, and a bad `grub.cfg` would make the ISO unbootable.
  `/mnt/vtoy/ventoy/conf/nixos-pinned.cfg` (643 B, md5 `dc34b0a9395658110a53f0202ed9a77b`)
  stays on the stick for the attempt that needs it; it leans on Ventoy's own grub variables
  (`${vtoy_iso_part}`) and on the ISO's store paths, so it is unverified by construction.

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
# from the jail: classify every candidate address (listener / no-socket / no-network).
# A banner-only probe is not enough (see the caveat below) — ssh -v reaches the
# protocol stage and stops before auth.
probe() { timeout 8 ssh -v -o BatchMode=yes -o ConnectTimeout=3 \
            -o PreferredAuthentications=none "$1" exit 2>&1 \
          | grep -oE 'Remote protocol version|Connection refused|No route to host|Connection timed out' | head -1; }
for i in $(seq 1 254); do r=$(probe "192.168.5.$i"); [ -n "$r" ] && printf '192.168.5.%s %s\n' "$i" "$r"; done
for i in $(seq 0 63);  do r=$(probe "192.168.4.$i");  [ -n "$r" ] && printf '192.168.4.%s %s\n' "$i" "$r"; done
echo "SWEEP-EXIT: $?"
```

What the sweep found, completed in the background over 268 addresses: exactly two
live listeners on the wired LAN, and **neither of them is this box** —

| address | `ssh -v` reports | who it is | the read that identifies it |
|---|---|---|---|
| `192.168.5.201` | `OpenSSH_10.0p2 Debian-7+deb13u4` | **another** Proxmox machine, `pve1` | `uname -a` = `pve1 7.0.14-12-pve`, `vmbr0 192.168.5.201/22`, `nvme0n1p3` = `zfs_member rpool`, a `zd0` USB carrying `hassos-boot`/`hassos-overlay`/`hassos-data` |
| `192.168.5.202` | `OpenSSH_10.3` | Home Assistant OS core, `core-ssh` | `/etc/os-release` = Alpine `3.24.1`, `uname -a` = `core-ssh 6.18.52-haos`, no `lsblk` on it |

Both accept `root` with the agent's `ha_key`, which is why presence-only probing was
the defect rather than the answer: identity (`os-release` + `uname -a` + the wired
address) is what separates these neighbours from `yzerd`. `192.168.5.186` itself
answered `Connection timed out` and `:8006` returned 0 bytes, so **this box had no
listener** — the live NixOS ISO had not started sshd, and PVE was not running. A
sweep hit must therefore never be treated as "the box" without that identity read.

What the live ISO will not do is hand us a key by itself — `users.users.nixos`
there has an empty password and no authorized key, so the first step has to be
typed at the monitor. One console line, either a password or our key:

```sh
sudo sh -c 'echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIDKuUwgF6tCaTogYB+/iP5HH/G9v3/fuNfFh1lpoQqm dsh-agent" > /etc/ssh/authorized_keys.d/root'
```

(`%h/.ssh/authorized_keys.d/%u` is in the ISO's own `AuthorizedKeysFile`, same
module, so the file needs no mode play and no home directory.) Then the box needs an
address before the jail can reach it — the stock live image does not reproduce PVE's
static wiring, so the wiring is typed here too (same interface name PVE used,
`enp4s0`, and the same gateway):

```sh
sudo ip -brief a; ip link show enp4s0
sudo ip addr add 192.168.5.186 dev enp4s0
sudo ip route add 192.168.5.186 via 192.168.4.1 dev enp4s0
```

A single address is enough for one ssh connection. The `/22` form in the installed
config is the documented networkd spelling — [systemd.network(5)](https://man.archlinux.org/man/systemd.network.5)
defines `Address=` as "a static IPv4 or IPv6 address and its prefix length, separated by
a `/` character", i.e. a *network*, and [NETWORK] `Gateway=` as "a short-hand for a
[Route] section only containing a `Gateway=` key" — so `address = [ "192.168.5.186/22" ]`
+ `gateway = [ "192.168.4.1" ]` is the networkd equivalent of PVE's ifcfg
`address 192.168.5.186/22` + `gateway 192.168.4.1`, not a guess.
Then the jail can take over: `ssh -o BatchMode=yes root@192.168.5.186 'uname -a; ss -lntp'`.

Measured, not assumed: `masscan` will not run from the jail (`FAIL: permission
denied … need to sudo` — a privileged probe it needs and the jail will not give), and
unprivileged `nmap` prints `PORT 22/tcp filtered ssh` for **every** address, so neither
is evidence. The `nc` banner probe is weaker than it looks: sshd emits its banner only
after the client sends a line, so a bare `nc` says nothing about a *present* listener —
measured at `192.168.4.44` (this machine's own wired address), the raw socket that
sends `SSH-2.0-Probe` gets `SSH-2.0-OpenSSH_10.6` back while the `nc` sweep stayed
silent there. So a probe must classify, not listen for a banner — that is the `probe()`
used by the sweep block above (`ssh -v` with
`-o PreferredAuthentications=none`, which reaches the protocol stage and stops before
auth).

`Remote protocol version` = a listener; `Connection refused` = LAN present, no socket;
`No route to host` = that address has no network. What is decisive **without** any sweep:
`192.168.5.186` answers `No route to host` (PVE's static address is configured by
nothing that booted) and `http://192.168.5.186:8006/` returns no bytes at all, while
`192.168.4.1` answers `Connection refused` — the LAN edge is there, PVE is not.

Unverified: whether an empty live-ISO password is accepted by sshd's PAM path —
do not plan around it, plan around the console line above.

Only two lines belong at the monitor, not four. The live image logs itself in on
tty1 as `nixos` with passwordless `sudo`, and sshd only has to be started and given our
key; the wiring then belongs to the jail, because a listener answers *somewhere* on the
shared LAN the moment sshd runs, and once the jail can reach it the static address is set
from the jail over ssh — the box's DHCP address is not the pinned one, and pinning it is
only needed before `nixos-install`, not before logging into it:

```sh
sudo systemctl start sshd
sudo sh -c '"'"'echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIDKuUwgF6tCaTogYB+/iP5HH/G9v3/fuNfFh1lpoQqm dsh-agent" > /etc/ssh/authorized_keys.d/root'"'"'
```

The `ip addr add`/`ip route add` lines above are what the jail then runs over that
connection (and what the installed system reproduces declaratively through the
`10-yz-enp4s0` networkd unit); typing them at the monitor is a shortcut, not a
requirement. Whether the live image really autologs in on tty1 is read from the image's
own `getty@tty1` override at the console, not assumed here.

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

1. **Resolved twice: the stick booted, and Ventoy now selects the ISO by itself.**
   The stick reached Ventoy's menu through the firmware-discovered USB entry (`Boot0007`),
   and the reason the menu waited is in the staged config, not in the transport — see
   *The Ventoy config that was staged* above. With the corrected `control` array staged
   (md5 `69f400444c7aff5363c6a5151a3f07a1`) and `BootNext: 0007` armed, the reboot left
   PVE (`:8006` = 0 bytes; `192.168.5.186` = `Connection timed out`, i.e. route there,
   no listener), so the live ISO booted with no hand on the menu. What is missing now is
   not a boot but the live stage's own wiring: the live image configures no static address
   and carries no authorized key, so the console lines in *Reaching the live system* (key,
   `ip addr add`, `ip route add`) are the next action at the monitor, after which
   `ssh -o BatchMode=yes root@192.168.5.186` takes over and `go-native.sh WIPE` runs.
2. **Whether `bootctl install --variables=no` really lands `EFI/BOOT/bootx64.efi`**
   in this systemd version — read from the pin, not yet observed on the box.
   If it does not, the fix is an explicit copy to that path, not an NVRAM edit.
3. **GPU decision** (see above).
4. **Guest VM unit** on the native host (the replacement for vmid 100).
5. **Staging ledger (at copy time — re-md5sum before trusting it).** Now on the
   stick: `go-native.sh` in `/mnt/vtoy/repo-yzerd/` (md5 `78eefedaa1510983cb5b37e5b6ffd129`,
   matching the repo copy) and `nixpkgs-f20cd90.nar.xz` in `/mnt/vtoy/offline/`
   (34703312 B, md5 `5e86e8f13b8be035a1642d33c3875c00`, matching `/home/llm/offline-seed/`),
   plus the corrected `/mnt/vtoy/ventoy/ventoy.json`. The three files the install actually
   reads — `default.nix`, `flake.nix`, `flake.lock` — match the repo byte for byte, which is
   what keeps the pin reproducible from the stick:
   `srgrfiddhf1lb60d4vld78jy411s4v7n-nixos-system-yzerd-26.11.20261016.f20cd90.drv`.
   Still behind on the stick: the guest doc `/mnt/vtoy/repo/README.md`
   (`d57faca0a524d7d4066811a0144ff871` there vs `178b235c754fb45b8f10761b99b2c1a5` in the
   jail) — documentation only, no effect on the build. `hosts/yzerd/README.md` itself is
   behind too — the stick carries
   `b3e26f2cd9d42246e38324ffdef3495c`, while the jail copy is whatever
   `md5sum hosts/yzerd/README.md` says at the moment of copying (this file changes on
   every doc edit, so its own value is never recorded here). The transport that made restaging possible at all is the 9p bridge
   through `ssh proxmox-186` — it exists only while the box is booted at PVE, and it is
   dead right now, because the box is on the live ISO.

## Driving the JetKVM at `192.168.4.27` from the jail, and what it says about the box

The KVM answers over HTTP **only** for the login form; control goes through the
browser's WebRTC `rpc` data channel, reached in-jail with Playwright and the
page's own `window.__kvmTestHooks.sendJsonRpc`. There is no plain-HTTP JSON-RPC
door: `POST /rpc`, `/api/rpc`, `/rpc/` all return `404 page not found`, and
`/device` plus `/diagnostics` stay `{"error":"Unauthorized"}` even after
`POST /auth/login-local` answers `{"message":"Login successful"}` — that call
sets no cookie and returns no token, so a fresh `curl` is still unauthenticated.
The WebRTC session opens only after the DOM login form is filled
(`input[name=password]` + `button`), and only then do the hooks report
`isWebRTCConnected() == true` with HID and terminal ready.

Firmware is app `0.5.9` / system `0.2.8`, and the method names are camelCase;
every legacy snake_case name is rejected. What each name answered, verbatim:

| method | answer |
|---|---|
| `get_state`, `get_version`, `get_hdmi_state`, `get_ota_status`, `type_text`, `key`, `press_keys`, `list_methods`, `mount`, `unmount`, `eject`, `set_usb_boot`, `set_firmware`, `trigger_reboot`, `boot_config`, `power_status`, `get_power_mode`, `set_power_mode`, `set_hid_enabled`, `get_hid_state`, `get_terminal_text`, `get_terminal_state`, `set_terminal_type`, `get_terminal_type`, `set_network_settings`, `get_edid` | `{"code":-32601,"message":"Method not found"}` |
| `getVideoState` | `{ready:true, streaming:0, width:1920, height:1080, fps:60}` |
| `getUsbDevices` | `{absolute_mouse:true, relative_mouse:true, keyboard:true, mass_storage:true, serial_console:false, audio:true}` |
| `getHostDisplayIdleMode` | `{enabled:false}` |
| `getVideoSleepMode` | `{supported:true, enabled:false, duration:0}` |
| `getDisplayRotation` | `{rotation:"270"}` — captured frames arrive rotated |
| `getStreamQualityFactor` | `1` |
| `getUpdateStatus` | local app `0.5.9` / system `0.2.8`; remote wants the same `0.5.9` |
| `sendCustomCommand {"command":"id"}` | accepted, `result:null` (this is the UI's terminal text input; the UI appends the terminator, labelled `LF (\n)`) |
| `wakeHost` | accepted, `result:null` |
| `setHostDisplayIdleMode {"mode":"off"}` | `missing parameter: enabled` |
| `setVideoSleepMode {"sleep":false}` | `missing parameter: duration` |
| `getSerialSettings` | `-32603 open /userdata/serialSettings.json: no such file or directory` — and `serial_console:false`, so the serial-terminal path does not exist on this KVM |

`captureVideoRegion(0,0,1920,1080)` writes a real 44075-byte PNG, and decoding
it with numpy (RGBA, per-row PNG filters) gives an entirely black frame: the
page's `<video>` element reports `videoWidth:0` and no `currentSrc`, so the
recvonly video track delivered no frame at all (`streaming:0` in
`getVideoState`). The KVM's own log names the reason:

```
stream_cif_mipi_id0: open video, entity use_count 1
m00_b_tc35874x 4-000f: Reset: IR: 1, CEC: 1, CSI TX: 0, HDMI: 0
m00_b_tc35874x 4-000f: Cable detected (+5V power): yes
m00_b_tc35874x 4-000f: -----Signal status-----
m00_b_tc35874x 4-000f: TMDS signal detected: no
m00_b_tc35874x 4-000f: Stable sync signal: no
m00_b_tc35874x 4-000f: Waiting for particular sync signal: no
```

`TMDS signal detected: no` is the KVM saying the box's HDMI output carries no
picture, which agrees with the network side — `192.168.5.186` still gives
`Connection timed out` (route present, no listener). So there is no console to
drive: the box is either powered off or not feeding the KVM, and HID text
arrives nowhere useful until it is. `getKeyboardLedState` came back all-false
and `getKeyDownState` `{modifier:0, keys:[0,0,0,0,0,0]}` after the probes, so
the HID keyboard itself is wired and idle.

Nothing was typed this round on purpose: the driver script raised
`SyntaxError: unmatched ')'` before its first send, so the only text ever sent
was the single `sendCustomCommand {"command":"id"}` probe. That is the row to
remember — a syntax failure, not a device failure — and the sequence to send
once the box has a signal is still the two monitor lines from *Reaching the
live system* (`systemctl start sshd` and the authorized-key write), with the
`ip addr add` / `ip route add` pair done from the jail over the resulting
connection.

## Screen-free box state, read on 2026-10-28 from the KVM's own HDMI state machine

There is no monitor at the box, so the screen is not an oracle. The JetKVM's
tc35874x log and the LAN are. These reads are the whole truth for this boot:

| read | answer | what it proves |
|---|---|---|
| `getVideoState` (firmware 0.5.9) | `{"ready":false,"streaming":0,"error":"no_signal","width":0,"height":0,"fps":0}` | the box is sending **no display signal at all** (it read `ready:true 1920x1080@60` in the earlier boot when PVE was up) |
| `getVideoLogStatus` | `Cable detected (+5V power): yes` / `TMDS signal detected: no` / `Stable sync signal: no` / `No video detected` / `horizontal: fp = 0, -sync = 0, bp = 0` | cable is connected and powered, **nothing on the wire** — the box is off or wedged before any output |
| `getVideoLogStatus` timestamps | `[ 702.27 ]` s | the **KVM itself restarted** ~12 min ago (earlier reads were at `[ 66499.1 ]` s), so the box went through a real power cycle |
| `nc -z -w3 192.168.5.186 22` from `pve1` | `SSH-NO` (`ip route get 192.168.5.186` resolves on `vmbr0`, so the probe is valid) | no sshd at the box |
| `ssh` from the jail to `192.168.5.186` | `Connection timed out` (`ip route get` resolves on `enp5s0`) | route exists from the desk, **no listener** — `No route to host` on other `.5.x` was the desk's own net, not the box |
| KVM login | first click never logged in (`isWebRTCConnected: false` on attempt 0), attempt 1 connected | any driver needs the retry loop, a single attempt is not enough |
| `getUsbDevices` | `keyboard: true`, `serial_console: false` | HID typing is available; there is no serial-terminal mode |

The console install path is two typed lines once the live ISO is up — the driver
mounts the stick itself (`go-native.sh:39-44`), so nothing has to be copied first:

```sh
mkdir -p /mnt/stick; mount /dev/sda1 /mnt/stick
sh /mnt/stick/repo-yzerd/go-native.sh WIPE
```

## This reboot (2026-10-28 ~06:41-06:52 America/Phoenix): the box is dark, and two oracles proved it

| read | verbatim answer | consequence |
|---|---|---|
| `VTOY_SECONDARY_BOOT_MENU` in [the Global Control plugin doc](https://www.ventoy.net/en/plugin_control.html) | `"0": Disable` / `"1": Enable (default)` | the staged `ventoy.json` value `"0"` was **already** the disabling value — the secondary menu is not the hang. (The claim in chat that `1` disables it was wrong; the doc says the opposite.) |
| `getVideoLogStatus` in **every** observed boot | `TMDS signal detected: no`, `Stable sync signal: no`, `No video detected`, `horizontal: fp = 0, -sync = 0, bp = 0` while `Cable detected (+5V power): yes` | the box's video has **never** traversed the KVM's HDMI-in, so the browser view is not an oracle in any state. `getVideoState` later made this explicit: `{"ready":false,"streaming":0,"error":"no_signal","width":0,"height":0,"fps":0}` — the earlier `ready:true 1920x1080@60` was the KVM's configured dims, never a captured frame |
| watcher `bash-67263051f6b24961` on `pve1` (route proven: `ip route get 192.168.5.186` → `dev vmbr0`) | every ~11 s from 06:47 to 06:51: `SSH-NO`, `PVEWEB=000` | no sshd and no PVE web at the box's wired address — it is either powered off or booted without its wired network up |
| the desk's own class flip-flop | `ip route get 192.168.5.186` → `dev enp5s0 src 192.168.4.44` yet ssh gave `Connection timed out` (06:41) then `No route to host` (06:52) | the desk's bridging toward `.5.186` is unstable; both messages mean **no usable listener**, and neither says anything about the box |
| KVM web login | attempt 0: `isWebRTCConnected: false` (page still `Welcome back to JetKVM … Password … Log In`); attempt 1 connected | any driver needs the login retry loop; one click is not enough |

`verify-native.sh` is the goal's acceptance test, run from the jail: `LISTENER-YES`
(ssh identity, not a banner) → `LOGIN-OK` (ssh as `b` with `ha_key`) → `NATIVE-OK`
(hostname `yzerd`, `os-release` NixOS, `/boot/4wcrl93il7vvqij3wihva6p83l3gk5n2-nixos-system-yzerd-26.11.20261016.f20cd90` present) → `PVE-WEB: 000` (PVE retired).
It passes the generation name as a positional to the remote `sh -s` so it interpolates
locally — `$GEN` inside a single-quoted remote string would have reached the box's shell
unset, the same trap as every other interpolated name.

## The box booted the stick after all, and it is reachable over the wire (2026-10-28 ~06:55)

The user's report was literal: `machine is live on 4.30 … boot environment off the USB of nixos`.
`ip route get 192.168.4.30` from the desk resolves, and the ssh **identity** read (not a banner)
answered `OpenSSH_10.5`, while `.5.186` stayed `No route to host`.

| read (from the jail, `root@192.168.4.30`) | verbatim answer | consequence |
|---|---|---|
| `uname -a; hostname; lsblk` | `Linux nixos 6.18.57 … x86_64`, hostname `nixos`, `sda1 exfat Ventoy` with `ventoy … iso9660 … /iso`, `nvme0n1p3 LVM2_member` still holding `pve-swap`/`pve-root` | the live ISO booted off the stick, and **nothing has been wiped yet** |
| `enp4s0 UP 192.168.4.30/22` | the live ISO configured the wired interface at `.4.30`, not the native config's `.5.186/22` | the native address only exists **after** the install boots; every pre-install probe of `.5.186` is expected to be dark |
| login | `pexpect` ssh with `root` + the password the user set → then `/root/.ssh/authorized_keys` + `/root/.ssh/authorized_keys.d/{root,b}` written → a later `ssh -o BatchMode=yes -l root` printed `KEY-AUTH-OK` | the whole install is now drivable from the desk; no console typing, no screen needed |
| `mount /dev/sda1 /mnt/stick` | `mount: /mnt/stick: fsconfig() failed: /dev/sda1: Can't open blockdev.` while `ls -l /dev/sda1` shows a real node (`8, 1`), `blkid /dev/sda1` → `LABEL="Ventoy" TYPE="exfat"`, and `dd if=/dev/sda1` reads the `EXFAT` magic | the node is fine, mount's blockdev open is not — the same signature as the earlier `by-label` failure |
| `losetup /dev/loop1 /dev/sda1` then `mount /dev/loop1 /mnt/stick` | `LOOP-MOUNT-OK`, `df -h /mnt/stick` → `30G 5.3G 25G 18%` | **fix**: loop-mount the stick when the direct mount refuses; `go-native.sh` now does exactly that (`STICK-VIA-LOOP: /dev/loopN`) |
| `free -m; nproc; df -h /nix; curl -sI https://github.com/` | `Mem: 128709`, `32`, `tmpfs 63G … /`, `HTTP/2 200` | the live store is a 63 G tmpfs over 128 G of RAM, so building the pinned system on the ISO is not memory-bound, and the pinned nixpkgs rev can also be re-fetched |
| stick md5s vs the repo | `default.nix e8425d0a7cd5fd6a79128632d9f2ab0d` `flake.nix 96a62ba8e69d44818cb8e9d05c9098ac` `flake.lock 03e099160ef125d9127031663b16a764` `offline/nixpkgs-f20cd90.nar.xz 5e86e8f13b8be035a1642d33c3875c00` — all four identical to the jail's repo | the stick carries the same flake the jail evaluated, so the pin can be compared honestly |

`go-native.sh` (md5 `9597f3e5643118979b53e1ad2391ccc8`, 5136 B — the version with the loop-mount
fallback) was pushed to `/root/go-native.sh` with `cat >` over the wire and the same md5 came back,
then run as `sh /root/go-native.sh WIPE` in background job `bash-f2a1d1cd1ad84456`, logged to
`/home/llm/inst7.log`. That is the one-way door: `mkfs.ext4 -L nixos-native /dev/nvme0n1p3` then
`nixos-install --root /mnt2 --flake /mnt/stick/repo-yzerd#nixosConfigurations.yzerd`.

## The door, three times over the wire (2026-10-28 ~07:00–)

`go-native.sh` is pushed with `cat >` and re-md5summed on the box, so a run is attributable to a
driver byte-for-byte. Each attempt below is one row: what it was, the exact refusal, the fix.

| driver md5 (box `/root/go-native.sh`) | job | how far it got | exact refusal | fix |
|---|---|---|---|---|
| `9597f3e5643118979b53e1ad2391ccc8` | `bash-f2a1d1cd1ad84456` | step 0 only | `P3-TYPE: LVM2_member` → `P3-TYPE IS NEITHER PVE-LVM NOR ext4: stop, the layout assumption is wrong` | the guard matched only the slashed form; `blkid -o value -s TYPE` answers `LVM2_member` here. Case became `LVM2_member|LVM2/*)` |
| `c6269a0817c9de8efd38ed09a93db12f` | `bash-5b279e338db84edb` | steps 0–3, stopped before touching p3 | `line 59: xzdc: command not found` → `error: unexpected end-of-file` → `SEED-FAILED`; then `mke2fs … /dev/nvme0n1p3 is apparently in use by the system; will not make a filesystem here!` → `MKFS-RC: 1`, `REMOTE-RC=6` | `xzdc` is a jail convenience, the ISO ships `xz`/`xzcat` only → `xz -dc`. The mkfs refusal is **not** a mount and **not** an open fd: `/proc/swaps` empty, `lsof /dev/nvme0n1p3` and `fuser -m` empty, `grep nvme0n1 /proc/mounts` empty — e2fsprogs' busy check is `dm_dev_in_use`, and `dmsetup ls` answers `pve-root (254,1) pve-swap (254,0)` ACTIVE on that partition |
| `ebe46cc451f99322c6afd5da39473dcf` | `bash-8db79609581d463f` | running now | — | `vgremove -f pve` before the wipe, then `wipefs -a`, then `mkfs.ext4 -f -L nixos-native` |

The teardown is scoped to the `pve` volume group on pain of death: the live ISO reads its own
kernel and store through the **Ventoy** device-mapper (`ventoy (254,2)`, `sda1 (254,3)` are its
`/iso` and the stick), so removing all DM devices would cut the running system out from under the
install. `mkfs.ext4 -f` is a belt after the braces: the DM devices are gone by then.

Nothing destructive happened before the third run: every earlier run refused **before** `mkfs`
wrote, and `lsblk` in the third run's step 0 still shows `pve-swap`/`pve-root`.

## The door, continued: p3 is raw now, and the live store is a read-only overlay

Two things the previous table did not predict, both hit while `vgremove -f pve` had already
succeeded. `p3` is **raw** now — the earlier run erased the LVM magic before its `mkfs` died — and
the live ISO's store is **not writable**.

| driver md5 | job | how far | exact output | what it means / the fix |
|---|---|---|---|---|
| `ebe46cc451f99322c6afd5da39473dcf` | `bash-8db79609581d463f` | tore down pve, wiped the magic, then died | `Logical volume "vm-100-disk-0" successfully removed` / `"data"` / `"swap"` / `"root"` / `Volume group "pve" successfully removed` → `DM-AFTER: sda1(254:3) ventoy(254:2)` → `wipefs: 8 bytes were erased at offset 0x218 (LVM2_member)` → `mkfs.ext4: invalid option -- 'f'` → `MKFS-RC: 1`, `REMOTE-RC=6` | `-f` is the busybox `mkfs` wrapper's force flag, not mke2fs's. With the DM devices gone the busy check passes anyway → drop `-f`. **PVE is gone from here on**: `vm-100-disk-0` was VM 100's disk on `local-lvm`, and `pve-root`/`pve-swap` were PVE's own filesystem — that is the retired-PVE decision, executed. The stick's DM (`ventoy`, `sda1`) stayed live, as required: the running ISO reads its kernel through it. |
| `e51e4b8d37b6e897d266038e26a1e36a` | `bash-dbba905cc8744fb6` | running now | — | the guard grew a `""` case: `blkid -o value -s TYPE /dev/nvme0n1p3` prints **nothing** on the raw partition (`P3-TYPE: none-raw`), and the next act is `mkfs.ext4` |

The store read as read-only because of how the live ISO builds it, not because of the media:

```
tmpfs   /nix/.ro-store  squashfs ro   (the ISO's 1.5 G store, loop0)
overlay /nix/store      overlay ro    lowerdir=/sysroot/nix/.ro-store
                                      upperdir=/sysroot/nix/.rw-store/store   <- writable dir,
                                      workdir =/sysroot/nix/.rw-store/work       ro-mounted over
```

so `nix-store --restore` on the **live** side answers
`filesystem error: cannot create directory: Read-only file system [/nix/store/glw7ngr0…-source]`
and `mount -o remount,rw /nix/store` answers `overlay: No changes allowed in reconfigure`.
That is why the offline seed is not restored live; `nixos-install`'s own man page is the answer —
*"1. It copies Nix and its dependencies to /mnt/nix/store. 2. It runs Nix in /mnt to build the
given NixOS configuration."* — the writable store during the build is the **target's** on `p3`.
The stick seed stays staged for a no-network retry; this boot's build fetches the pinned rev
(`curl -sI https://github.com/` → `HTTP/2 200` from the live env), which is the same
fixed-output path `glw7ngr0dwbp3al07rdlqkrbas7w3a02-source` either way.

### one more refusal on the same partition

| driver md5 | job | exact output | fix |
|---|---|---|---|
| `e51e4b8d37b6e897d266038e26a1e36a` | `bash-dbba905cc8744fb6` | `Volume group "pve" not found` → `VGREMOVE-NONZERO` (expected: already torn down) → `mke2fs 1.47.4` → `Invalid filesystem option set: Linux` → `MKFS-RC: 1`, `REMOTE-RC=6` | capital `-O` is mke2fs's **feature** list; the creator string is lowercase `-o`. Now `mkfs.ext4 -L nixos-native -o Linux` |
| `796cee2a8b8e16c67274036017adb0e8` | `bash-2ea9433fc7c54ca9` | running: `mkfs` on 930 G then `nixos-install` | — |

### the fresh ext4 mounts only by named type

`mkfs.ext4 -L nixos-native -o Linux` succeeded: `Filesystem UUID: aa809936-c797-471b-9bde-01c89817657f`,
`e2fsck -n` → `nixos-native: clean, 12/60989440 files, 4110581/243928241 blocks`, `lsblk` → `ext4 930.5G`,
`/dev/disk/by-label/nixos-native -> ../../nvme0n1p3` already exists. Yet `mount /dev/nvme0n1p3 /mnt2`
said `wrong fs type, bad superblock on /dev/nvme0n1p3 …`, and `mount -t ext4 /dev/nvme0n1p3 /mnt2`
on the same device returned `MOUNT-TYPE-RC=0` with `/mnt2 … 915G 36K 869G 1%` free. The kernel log
says why: the automagic probe walked the stale type for that partition and quit —

```
exFAT-fs (nvme0n1p3): invalid boot record signature
exFAT-fs (nvme0n1p3): failed to read boot sector
exFAT-fs (nvme0n1p3): failed to recognize exfat type
EXT4-fs (nvme0n1p3): mounted filesystem aa809936-… r/w
```

The door now names the type on both mounts (`-t ext4`, `-t vfat`). The run that lays the layout is
`sh /root/go-native.sh WIPE FORCE-EXT4` — p3 is ext4 already, so the guard's documented second
argument is what resumes it (one more `mkfs`, ~a minute with lazy inode tables, same LABEL).

## The wiring is one subnet, and only one socket is live

Read from the live env (`ip -a link show`, `ip route get`, `ls -l /sys/class/net` on the box;
the same probes from pve1 at `.5.201`):

| read | result |
|---|---|
| box `enp4s0` | `state UP`, carrier — this is the live cable, and it is the NIC `default.nix` pins |
| box `enp5s0` | `NO-CARRIER … state DOWN` — a second socket with no cable; the installed system must not depend on it |
| box `wlp6s0` | present, deliberately unused |
| box `ip route get 192.168.5.186` | `dev enp4s0 src 192.168.4.30` |
| box `ip route get 192.168.5.201` | `dev enp4s0 src 192.168.4.30` |
| box `/etc/systemd/network/` | **empty** — the ISO's `192.168.4.30` is the kernel's MAC-derived auto-assignment, not a rule |
| pve1 `enp3s0 … master vmbr0` | pve1 hangs off PVE's `vmbr0` bridge — that is why pve1 could reach `.5.186` while PVE named that address |
| pve1 `ip route get 192.168.5.186` / `…4.30` | both `dev vmbr0` |

`192.168.4.0/22` spans `.4.0`–`.5.255`, so `.4.30` (what the live ISO picked) and `.5.186` (what
PVE named the box) are **the same network**; the installed system pins `enp4s0` to `192.168.5.186/22`
with `gateway = 192.168.4.1`, so after the install the wired identity moves back to `.5.186` and
`.4.30` stops answering. The acceptance test should watch **both**, and `ssh proxmox-186` is the
read that matters afterwards.

### the install itself: nixos-install wants the machine name, not the attribute path

`mkfs` and the mounts now pass cleanly, so the door reached the install and the refusal there
is about the selector:

| driver md5 | job | how far | exact output | fix |
|---|---|---|---|---|
| `efab220491c83883813314c09d56cc21` | `bash-ba56641156d34c9a` | `MKFS-RC: 0`, `MOUNT-OK`, then the install died at the selector | `copying channel...` → `building the flake in path:/mnt/stick/repo-yzerd?lastModified=…` → `error: flake '"'"'path:/mnt/stick/repo-yzerd?…'"'"' does not provide attribute '"'"'packages.x86_64-linux.nixosConfigurations."nixosConfigurations.yzerd".config.system.build.toplevel'"'"', …` → `INSTALL-RC: 1`, `REMOTE-RC=3` — the target was left with `boot/`, `lost+found/`, `nix/`, `root/` and 478 M used | `nixos-install`'s own source (`/nix/store/hji0isqrwj5qasa891hqq96bapqcmw3q-nixos-install/bin/nixos-install`) L212: `flakeAttr="nixosConfigurations.\"$flakeAttr\""` and L284 `nix build "$flake#$flakeAttr.config.system.build.toplevel"`. Its man L209: *"to use the output nixosConfigurations.foo … append `#foo`"*. So `#nixosConfigurations.yzerd` asks for a key literally named `nixosConfigurations.yzerd` **inside** `nixosConfigurations`. Pass `#yzerd` |
| `5cc6e0cb9d107a128ec462db6dc21c64` | `bash-9172e436509e42a8` | running: `mkfs` again (lazy, ~a minute) then the real build — nixpkgs fetched from GitHub per the rev pin, then the full toplevel | — |

Two facts worth keeping from the successful steps: `mkfs.ext4 -L nixos-native -o Linux` reports
`243928241 4k blocks and 60989440 inodes` and writes its tables lazily, so each re-run is seconds,
and `mount -t ext4` gives `/mnt2 … 915G 44K 869G 1%` before the install starts.

### the wipe refused because the previous run left the target mounted

| driver md5 | job | exact output | fix |
|---|---|---|---|
| `87551cd942ba877b4c464e024b0760a8` | `bash-9172e436509e42a8` | `wipefs: error: /dev/nvme0n1p3: probing initialization failed: Device or resource busy` → `WIPEFS-NONZERO` → `mke2fs … /dev/nvme0n1p3 is mounted; will not make a filesystem here!` → `MKFS-RC: 1`, `REMOTE-RC=6` | attempt 5 mounted **both** `/mnt2` (p3) and `/mnt2/boot/efi` (p2) and then exited on the install error, leaving them up. A bare `umount /mnt2` is itself refused while something is mounted under it (`target is busy`), and its message was hidden by `2>/dev/null`, so the mount silently stayed. Now `umount -R /mnt2` plus a `findmnt` guard that refuses to wipe a still-mounted device (`exit 7`) and two `MOUNTS-*:` markers that make the state visible in the log |
| `8093cb3ab6d4ea2b2ada73d897f9b2ad` | `bash-7d4a107588434398` | running — reached the real build; the live oracle shows `nix-env … -p /mnt2/nix/var/nix/profiles/per-user/root/channels --set /nix/store/zkkyw00m…-nixos-26.05.12707.718f670e8453` (the ISO's channel copy) and `/mnt2/nix/store` at 246 M | — |

### the install landed, and it landed exactly on the pin

Door attempt 7 (`bash-7d4a107588434398`, log `/home/llm/inst15.log`, 1456 lines, `INSTALL-RC: 0`)
finished the install. The driver's own pin check then lied — `PIN-MISMATCH: expected generation dir
absent` — because it looked under `/mnt2/boot`, which on this layout holds only `efi`. The real read
is the target's own store and the systemd-boot entry:

```
$ ssh root@192.168.4.30 'ls -d /mnt2/nix/store/*nixos-system*'
/mnt2/nix/store/4wcrl93il7vvqij3wihva6p83l3gk5n2-nixos-system-yzerd-26.11.20261016.f20cd90
/mnt2/nix/store/srgrfiddhf1lb60d4vld78jy411s4v7n-nixos-system-yzerd-26.11.20261016.f20cd90.drv
```

Both names are the pin recorded from the jail (`srgrfiddhf…drv` → `4wcrl93i…`), so the reproduction
gate is satisfied: the box realized the same derivation the jail evaluated. The loader entry agrees
with the rendered `boot.json` proven earlier — `title NixOS`, `version Generation 1 NixOS Zokor
26.11.20261016.f20cd90 (Linux 6.18.56), built on 2026-10-28`,
`linux /EFI/nixos/nh11qhh…-linux-6.18.56-bzImage.efi`,
`initrd /EFI/nixos/ymxh430…-initrd-linux-6.18.56-initrd.efi`,
`options init=/nix/store/4wcrl93il7…-nixos-system-yzerd-26.11.20261016.f20cd90/init root=fstab loglevel=4 lsm=landlock,yama,bpf`,
`sort-key nixos`, and `loader/loader.conf` defaults it (`default nixos-419168a3….conf`, `timeout 5`).

Open question 2 is answered by these two files: `boot.loader.efi.canTouchEfiVariables = false` stops
NVRAM edits, but `bootctl` still wrote the fallback copy — `md5sum` says

```
b5b1066b00743599ed56e72a91a56901  /mnt2/boot/efi/EFI/BOOT/BOOTX64.EFI
b5b1066b00743599ed56e72a91a56901  /mnt2/boot/efi/EFI/systemd/systemd-bootx64.efi
```

so the ESP's legacy path `EFI/BOOT/BOOTX64.EFI` **is** systemd-boot, and the pre-existing NVRAM entry
`Boot0004* UEFI OS  HD(2,GPT,ae4fb41e-…,0x800,0x200000)/\EFI\BOOT\BOOTX64.EFI` points at exactly that.
No new entry is needed — only ordering, and this firmware's handling of `BootOrder`/`BootNext` is still
unproven (an earlier `efibootmgr -n 0007` never took effect).

## the box booted natively, and the door that made it happen was `--force`

The install finished at 14:15 UTC. `systemctl reboot` from the live ISO **did not reboot
anything**: `w` still showed one session (`reboot system boot 6.18.57 … 13:49 still running`),
and `efibootmgr` still printed `BootNext: 0004` — a one-shot that was never consumed is proof the
firmware never ran a POST. `systemctl reboot --force` did reboot it (the ISO's PID-1 refuses the
plain form from a non-login ssh session, silently, exit 0).

Ordering was already right, and this firmware does honour it once a real POST runs:

```
$ efibootmgr | grep -E "^Boot(Order|Next)"
BootOrder: 0004,0006,0007,0008,0005,0000,0003
BootNext: 0004
```

`Boot0004` is `UEFI OS → HD(2,GPT,ae4fb41e-…,0x800,0x200000)/\EFI\BOOT\BOOTX64.EFI` — p2 of the
NVMe, whose `EFI/BOOT/BOOTX64.EFI` bootctl had just written as a byte-identical copy of
`systemd-bootx64.efi`. So the legacy-path fallback the loader writes under
`boot.loader.efi.canTouchEfiVariables = false` is the working door, and no new NVRAM entry was
needed: ordering plus a one-shot, then `sync; systemctl reboot --force`.

What the wire then said, from the desk (the only oracle — no screen, and the stick is no longer in
`lsblk` at all, so the ESP alone boots the box):

```
$ verify-native.sh 192.168.5.186            # log /home/llm/verify-native.log
LISTENER-YES      ssh -vv -o PreferredAuthentications=none → Remote protocol version 2.0
LOGIN-OK          ssh -l b 192.168.5.186 with ha_key authenticates
PIN-PRESENT       /nix/store/4wcrl93il7…-nixos-system-yzerd-26.11.20261016.f20cd90
                  Linux yzerd 6.18.56 … ; / ext4 on /dev/nvme0n1p3; /boot/efi vfat on p2
UNIT: active      sshd
PVE-WEB: 000      nothing serves :8006 — Proxmox is retired on this box
```

The wired identity is the declared one, not the ISO's MAC-derived accident: the box's own
`ip route get 192.168.4.1` answers `dev enp4s0 src 192.168.5.186`, with `enp4s0` UP and
`/etc/systemd/network/10-yz-enp4s0.network` a symlink into the generation's `etc/static/…`
carrying `Address=192.168.5.186/22` + `Gateway=192.168.4.1`. `.5.186` is a legal local address
because `192.168.4.0/22` spans `.4.0`–`.5.255`.

### the reproducibility gate, closed on both sides

`nixos-install --flake` leaves `/etc/nixos` on the target **empty** — the flake is the source of
truth, and on the stick. The stick has been pulled since, so the pinned trio was staged into the
installed system by hand and the copy is byte-identical to the jail's:

```
$ for f in flake.nix default.nix flake.lock; do ssh … "sudo tee /etc/nixos/$f" < hosts/yzerd/$f; done
$ ssh … 'sudo md5sum /etc/nixos/{flake.nix,default.nix,flake.lock}'
96a62ba8e69d44818cb8e9d05c9098ac  flake.nix      (jail: same)
e8425d0a7cd5fd6a79128632d9f2ab0d  default.nix    (jail: same)
03e099160ef125d9127031663b16a764  flake.lock     (jail: same)

$ ssh … 'sudo -u b nix --extra-experimental-features "nix-command flakes" \
         eval --raw "/etc/nixos#nixosConfigurations.yzerd.config.system.build.toplevel.drvPath"'
/nix/store/srgrfiddhf1lb60d4vld78jy411s4v7n-nixos-system-yzerd-26.11.20261016.f20cd90.drv
```

Same flake bytes, two different machines, same derivation and the same out path
(`4wcrl93il7vvqij3wihva6p83l3gk5n2-…`): the jail's `nix eval` pin is what the box realized, what
its systemd-boot entry boots, and what the box re-evaluates today. `nix-env --list-generations` is
empty because the install ran with `--no-root-password` and the store holds exactly one
generation — `Generation 1`, per the entry's `version` line.

### three verify-native.sh defects, fixed in place

* the listener probe printed nothing without `-vv`: `Remote protocol version` lives on the
  verbose channel only, so LISTENER-YES required `-vv` (and the string is `Remote protocol
  version`, not `Server version`);
* the pin check looked in `/boot`, which on this ESP-backed layout holds only `efi` — it now reads
  `/nix/store/<gen>` and prints the loader entry next to it;
* `curl -w %{http_code} || echo 000` printed `000000`; the fallback is now a `[ -z ]` guard.

## Driver audit on the booted native box

The ask was "make sure all drivers, nvidia etc is working". Nothing on this box could enumerate its
own hardware — pciutils/usbutils are not in the minimal config's closure — so the audit ran through
/sys and the journal. Measured, before any config change:

```
$ lsmod | grep -iE 'nouveau|snd|iwl|bt|igb'      # nouveau 3842048 0; snd_hda_*; iwlwifi; bt*; igb
$ ls -l /sys/class/drm
  card0 -> ../../devices/pci0000:00/0000:00:03.1/0000:0a:00.0/simple-framebuffer.0/drm/card0
$ ls -l /dev/dri                                  # only card0 (group video) + by-path symlink
$ ls /dev/nvidia*                                 # nothing
$ ls -d /nix/store/*linux-firmware*               # nothing; no /lib/firmware nvidia/gsp files
$ command -v lspci lsusb nvidia-smi               # none installed
$ journalctl -b --no-pager | grep -iE 'nouveau|nvidia'
  nouveau 0000:0a:00.0: NVIDIA AD102 (192000a1)
  nouveau 0000:0a:00.0: gsp: Failed to load required firmware for device.
  nouveau 0000:0a:00.0: gsp ctor failed: -2
  nouveau 0000:0a:00.0: probe with driver nouveau failed with error -2
```

Read: the card is an AD102 (RTX 40-series) at PCI 0000:0a:00.0. The in-tree nouveau driver found it,
tried to bring up its GSP stack, found no firmware anywhere on the system, and gave the device to
nothing — the only DRM node left was the EFI console's simple-framebuffer. Audio is the opposite
case: snd_hda_intel loaded and /dev/snd exists (controlC0, hwC0D0, pcmC0D3p…, root:audio) but b is in
neither audio nor video, so the nodes exist and the user cannot use them. WiFi loads iwlwifi+cfg80211
yet /sys/class/net has only enp4s0/enp5s0/lo — the card is present and disabled, reported not fixed.

### what the config now declares

* `hosts/yzerd/nvidia.nix` (new, added to the flake's module list): NVIDIA open kernel modules —
  the branch this pin's own assertion in `nixos/modules/hardware/video/nvidia.nix` asks for on
  Turing or later — with the two package pins `hosts/desktop/nvidia.nix` proved this nixpkgs rev
  needs (patchelf 0.15.2 shadow, upstream modeset nested-revoke patch), `hardware.graphics` for
  GL/Vulkan, `hardware.enableRedistributableFirmware` for linux-firmware (nouveau's GSP blobs plus
  the directory the wifi card and card reader want), and pciutils/usbutils so the box can name its
  own devices. `powerManagement.enable = false` here, unlike desktop: nothing on this box owns the
  card's residency policy yet, so a driver that sleeps it would hand back VRAM nothing reclaims.
  `hardware.nvidia.enabled` in this pin is driven by `services.xserver.videoDrivers = [ "nvidia" ]`
  — xserver itself stays off.
* `default.nix`: b's `extraGroups` gained `video` (owns /dev/nvidia*) and `audio` (owns /dev/snd).

Then: jail `nix build` of the toplevel (new pin), closure copied to the box, `nixos-rebuild switch`
**on the box**, reboot into the new generation, and verify-native.sh re-pinned. The GPU modules load
at switch time, so `nvidia-smi` answers before the reboot; the reboot is what makes the new
generation the booted one.

## Generation 2 — the driver delta, and what the cold boot proved

The switch to `bs2k4hsnk2mhhz3g7a0zr159dg6f5zpw-nixos-system-yzerd-26.11.20261016.f20cd90`
(`switch1.log`, 41 derivations incl. `nvidia-open-615.78.08-6.18.56`,
`linux-6.18.56-modules`, `firmware`, `initrd-linux-6.18.56`) was NOT enough on its own:
after `switch`, `lsmod | grep nvidia` was empty and `sudo modprobe -v nvidia` said
`FATAL: Module nvidia not found in directory /run/booted-system/kernel-modules/lib/modules/6.18.56`.
That is the generation-scoped module set — modprobe resolves through the modules of the
generation that **booted**, and the NVIDIA `.ko`s and the whole `/lib/firmware` tree reach the
kernel only from the new generation's initrd. The reboot is the fix, and the door needed no
NVRAM edit: `nixos-rebuild switch` wrote the new loader entry
(`nixos-b792dd78….conf`, `version Generation 2`) and pointed `loader.conf`'s `default` at it,
so `sudo systemctl reboot --force` from the live system booted Generation 2 directly
(`efibootmgr` was not installed then — the door script in ./boot-native.sh could not have run
on the box itself, which is why efibootmgr is now in the package list).

Cold-boot readout, Generation 2 (`/run/booted-system` == `/run/current-system` == the pin):

```
nvidia-smi        NVIDIA GeForce RTX 4090   KMD 615.78.08   CUDA UMD 13.4   Bus 00000000:0A:00.0
                  11MiB / 24564MiB, Displ.A On, MIG N/A
lsmod             nvidia 18702336  2 nvidia_uvm,nvidia_modeset
                  nvidia_modeset 2019328  1 nvidia_drm     nvidia_uvm 2494464  0
                  nvidia_drm 163840  0                    (+ video, ecc helpers)
/dev/nvidia*      nvidia0 195,0  nvidiactl 195,255  nvidia-modeset 195,254  (root:video)
                  nvidia-uvm 234,0  nvidia-uvm-tools 234,1
/dev/dri          card1 226,1 root:video    renderD128 226,128 root:render
/sys/class/drm    card1 card1-DP-1..4 card1-HDMI-A-1 renderD128
/run/opengl-driver -> /nix/store/347qqlnk…-graphics-drivers, 32 vulkan/egl/glx libs
firmware dir      915 files, 392 .bin.zst — nouveau GSP blobs 1534-2-0x… 15E2-0-0x… present
groups            b wheel audio video
```

The card is an **RTX 4090** (`lspci: NVIDIA Corporation AD102 [GeForce RTX 4090] [10de:2684]`,
plus `0a:00.1 Audio device … AD102 High Definition Audio Controller` — the HDMI/DP audio
that journal registered as `input3..6` on `card0`).

Audio needed no change: `/dev/snd` nodes are `root:audio` and `b` is now in `audio`
(the gen-1 audit found the nodes with b in neither group). The webcam is genuinely absent
(`/sys/class/media` empty, no `/dev/v4l`); `v4l-utils` is in the list so a future card
reports itself instead of being assumed absent.

WiFi flipped with the firmware: the first boot had **no** `wlp*`; Generation 2 logged
`iwlwifi … loaded firmware version 77.8dbafb52.0` and `wlp6s0: renamed from wlan0`, so
`/sys/class/net` = enp4s0 enp5s0 lo wlp6s0 with `iwlmvm/iwlwifi/mac80211/cfg80211` loaded.
The AX200's other half (`8087:0029 Intel Corp. AX200 Bluetooth` in lsusb, kernel
`bluetooth` module loaded) had no daemon — `Unit bluetooth.service could not be found` —
hence `hardware.bluetooth.enable = true` and `hardware.wirelessRegulatoryDatabase = true`
in the delta below.

### the second delta (bluetooth + regdb + inspection tooling)

`nvidia.nix` gained `hardware.bluetooth.enable`, `hardware.wirelessRegulatoryDatabase`,
and `alsa-utils alsa-ucm-conf libva-utils v4l-utils efibootmgr` in `environment.systemPackages`,
each with the live readout that motivated it in the comment. New pin to be recorded below
after the jail build and the box switch.

### Generation 3 pin and the cold-boot proof

```
jail  nix build --impure --no-link --print-out-paths "/etc/nixos#nixosConfigurations.yzerd.config.system.build.toplevel"
      -> /nix/store/5qpm4i44bgak2wkijmbfv16ah5lwyp2w-nixos-system-yzerd-26.11.20261016.f20cd90   (BUILD-RC: 0)
box   nixos-rebuild switch --flake /etc/nixos#yzerd
      -> Done. The new configuration is /nix/store/5qpm4i44bgak2wkijmbfv16ah5lwyp2w-…           (SWITCH-RC=0)
```

Same drv (`acgss6zf3d0qm7cfn6mjjsl3rdvjzwdw`) computed on both machines from the staged
quartet, same outPath built on both — the reproducibility gate holds through the delta.
The ESP now carries three loader entries (`version Generation 1/2/3`) and `loader.conf`
`default nixos-219716746ae243be13f5f5e469657bd5a708b7aa2fdbde9590ab0c4c1dbf892c.conf`
names the Generation 3 one, so `sudo systemctl reboot --force` lands on it without any
NVRAM edit; `efibootmgr` (newly installed on the box) says `BootCurrent: 0004`,
`BootOrder: 0004,0005,0000,0003` — Boot0004 is the `\EFI\BOOT\BOOTX64.EFI` door on nvme0n1p2
that survived the wipe.

Cold-boot readout, Generation 3 (box polled UP at t=50s, nothing loaded by hand):

```
/run/booted-system == /run/current-system == /nix/store/5qpm4i44…    the jail pin, booted cold
/dev/nvidia*         nvidia0 nvidiactl nvidia-modeset nvidia-uvm nvidia-uvm-tools
                     nvidia-caps/{nvidia-cap1,nvidia-cap2}
/dev/dri             card1  renderD128  by-path
lsmod | grep nvidia  8 matches (nvidia, nvidia_modeset, nvidia_uvm, nvidia_drm + helpers)
nvidia-smi -L        GPU 0: NVIDIA GeForce RTX 4090 (UUID: GPU-cf5efaf1-f844-7553-bacf-18b94c5f53fb)
firmware dir         915 files; regulatory.db.zst + regulatory.db.p7s.zst present
rfkill               0 bluetooth hci0 unblocked unblocked
                     1 wlan      phy0 unblocked unblocked
/sys/class/net       enp4s0 enp5s0 lo wlp6s0        (ip a: 1 wlp link)
systemctl is-active bluetooth                       active
arecord -L           default:CARD=Generic  HD-Audio Generic, ALC1220 Analog
vainfo               VA-API version 1.24 (libva 2.24.0)
                     Driver version: VA-API NVDEC driver [direct backend]
v4l2-ctl --list-devices                              (empty — no capture device on the box)
ls /sys/class/media                                  No such file or directory (no media class)
journalctl nouveau                                   0 lines — the blacklist in nixpkgs holds
id b                 … wheel … video … audio
```

Two facts the tooling corrected in passing: the pin's v4l-utils (1.32.0) has no `v4l2_info`
binary — the readout command is `v4l2-ctl --list-devices`; and `nvidia-smi -q -d SUMMARY`
is rejected by 615.78.08's flag parser (`Failed to parse --display flags`) while plain
`nvidia-smi` and `nvidia-smi -L` work, so the summary table is read without `-d`.

What is NOT claimed working, and why: the box has no webcam (nothing in `/dev/v4l`, no
media class), and WiFi is present and unblocked but deliberately unmanaged —
`networking.useDHCP = false` and the only networkd unit is `10-yz-enp4s0` for the wired
cable, so `wlp6s0` answers `state DOWN` because no configuration asks it for a route.
That is the same choice the wired identity was declared with, not a driver failure.
