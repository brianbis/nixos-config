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
