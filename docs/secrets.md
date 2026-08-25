# Secrets

How the system's secrets are created, sealed, decrypted, and recovered.

## How it works

- `secrets/*.age` — age-encrypted blobs, committed to this repo.
- `secrets.nix` — the age recipient for each blob (`adminPubKey`).
- The age **private key is not committed to this repo**. It is sealed in the
  TPM2 as a data object (`seal.pub`/`seal.priv` in `/var/lib/agenix-tpm/`)
  bound to a PCR policy over **PCRs 0,2,3** (bootloader, kernel, initrd). A
  temporary rollback copy lives at `/var/lib/agenix/key.txt` until the
  post-cutover boot is confirmed clean, then it is shredded.
- Every boot, `system.activationScripts.tpmUnseal` (`hosts/desktop/security.nix`)
  unseals the key line into tmpfs at `/run/agenix-tpm/key.txt`, ordered before
  agenix's own `agenixInstall` activation script, which decrypts the blobs
  into `/run/agenix/`.
- The unseal must run in the initrd (as an activation script, not a systemd
  unit): with `systemd.sysusers` disabled — which it must be, since `b` and
  `llm` are normal users and systemd-sysusers cannot create them — agenix
  decrypts via activation scripts in the initrd, before the main systemd
  starts.

## Host artifacts (not in this repo)

| Path | What |
| --- | --- |
| `/var/lib/agenix-tpm/seal.pub`, `seal.priv` | The sealed key object (useless without the TPM + matching PCRs) |
| `/var/lib/agenix-tpm/pcr.policy` | PCR policy used at seal time |
| `/var/lib/agenix-tpm/pcr.bin` | PCR 0,2,3 values recorded at seal time (compare if unseal fails) |
| `/var/lib/agenix/key.txt` | Rollback copy of the key — shredded once the post-cutover boot is confirmed clean |
| `/run/agenix-tpm/key.txt` | This boot's unsealed key line (tmpfs, 0400) |

## Adding a secret

1. Stage the plaintext, e.g. `/tmp/name`.
2. Encrypt to the current recipient (`adminPubKey` in `secrets.nix`):

   ```bash
   age -r "$(grep adminPubKey secrets.nix | grep -oE 'age1[a-z0-9]+')" \
     -o secrets/name.age /tmp/name
   ```

3. Add the recipient in `secrets.nix`:

   ```nix
   "secrets/name.age".publicKeys = [ adminPubKey ];
   ```

4. Add the `age.secrets` entry in `hosts/desktop/security.nix`
   (owner/group/mode; the default branch is `root:root 0400`).
5. `just switch` → the secret appears at `/run/agenix/name`. Shred the plaintext.

## Rotating the age key

1. Generate a new key:

   ```bash
   age-keygen -o /tmp/new-age-key.txt   # public key in the "# public key:" line
   ```

2. Re-encrypt every blob to the new public key, decrypting with the current
   key (`/var/lib/agenix/key.txt` if it still exists, else this boot's
   `/run/agenix-tpm/key.txt`):

   ```bash
   KEY=/var/lib/agenix/key.txt
   for f in secrets/*.age; do
     age -d -i "$KEY" -o /tmp/plain "$f"
     age -r <new-pub> -o "$f.new" /tmp/plain
     shred -u /tmp/plain
     mv "$f.new" "$f"
   done
   ```

3. Update `adminPubKey` in `secrets.nix`.
4. Re-seal the new key (host, as root; tpm2-tools 5.8):

   ```bash
   sudo nix shell nixpkgs#tpm2-tools -c bash <<'EOF'
   set -e
   export TPM2TOOLS_TCTI=device:/dev/tpmrm0
   D=/var/lib/agenix-tpm
   tpm2_createprimary -c $D/primary.ctx -Q
   tpm2_pcrread -g sha256:0,2,3 -o $D/pcr.bin
   tpm2_policypcr -l 0,2,3 -g sha256 -L $D/pcr.policy
   grep '^AGE-SECRET-KEY' /tmp/new-age-key.txt > /tmp/keyline.txt
   chmod 600 /tmp/keyline.txt
   tpm2_create -g sha256 -G keyedhash -C $D/primary.ctx \
     -i /tmp/keyline.txt \
     -L $D/pcr.policy \
     -u $D/seal.pub -r $D/seal.priv
   shred -u /tmp/keyline.txt
   # Verify the new object unseals, exactly as the boot script does:
   tpm2_load -C $D/primary.ctx -u $D/seal.pub -r $D/seal.priv -c /tmp/seal.ctx -Q
   tpm2_unseal -c /tmp/seal.ctx -p pcr:sha256:0,2,3 -o /tmp/unsealed.txt
   cmp -s /tmp/unsealed.txt <(grep '^AGE-SECRET-KEY' /tmp/new-age-key.txt) \
     && echo "UNSEAL OK" || { echo "UNSEAL MISMATCH"; exit 1; }
   shred -u /tmp/unsealed.txt
   tpm2_flushcontext -c /tmp/seal.ctx
   EOF
   ```

   Only the bare `AGE-SECRET-KEY-…` line is sealed: TPM data objects cap at
   128 bytes (the full keygen file with its comment header is 189).
5. Install the new key as the rollback copy and shred the staging file:

   ```bash
   sudo install -m 0400 -o root -g root /tmp/new-age-key.txt /var/lib/agenix/key.txt
   sudo shred -u /tmp/new-age-key.txt
   ```

6. `just switch`, reboot, and verify `/run/agenix/` is populated **without** a
   second switch. Then shred the old key.

## Failure modes

- **Unseal fails at boot** (boot log: `agenix-tpm: TPM device not available`,
  or a `tpm2_unseal` policy mismatch): PCRs 0,2,3 drifted — a kernel, initrd,
  or bootloader change — and no longer match the seal policy. Compare
  `tpm2_pcrread -g sha256:0,2,3` against `/var/lib/agenix-tpm/pcr.bin`.
  - While `/var/lib/agenix/key.txt` still exists: re-add it to
    `age.identityPaths` and `just switch` — no reseal needed.
  - Once shredded: the key is unrecoverable. Reissue the credentials
    (DeepSeek API key, HF token, Tailscale auth key, …) and re-encrypt the
    blobs with a new key.
- **PCR 7 deliberately avoided**: NixOS sets `init=/nix/store/<hash>/init` on
  the kernel command line, which changes on every switch and would break
  unseal after every `just switch`.
