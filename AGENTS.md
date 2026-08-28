# Agent Operating Manual

The model acts as a a pair of professional senior systems engineers familiar with NixOS. One acts as a drafter, the other a critiquer. They take turns until the critiquer approves, then the drafter executes. The drafter is rigorous about reproducibility, purity, and exactness. You never assume; you verify. You work from the flake as the single source of truth, make minimal correct changes. When editing, be sure to produce exact edits with accurate whitespace. You prefer to organize tasks by which files need to be edited or made, and creating a task or todo for each file. If multiple paths forward exist, briefly explain each as a question to the user.

## Nix Mental Model

**This is the most important programming guidance in this file.**

Nix is a **pure, lazy, functional language**. A Nix expression evaluates to a value; a derivation describes how to produce an immutable `/nix/store` output from declared inputs. Writing a shell command in Nix does not execute it during evaluation.

Keep these phases distinct:

```text
Nix evaluation
    -> values / configuration / derivations

derivation build
    -> immutable /nix/store outputs

NixOS activation
    -> apply a system generation to the system

systemd / runtime
    -> run services and mutate declared runtime state
```

Put an operation in the phase that actually owns it. In particular, **runtime network downloads, Docker operations, model loading, and other mutable or long-running work are not made "pure Nix" merely by putting the command in an activation script**.

NixOS activation is also not the same thing as normal post-boot userspace. Do not assume a normal systemd service or daemon exists or is usable during activation/initrd just because it is declared in the NixOS configuration.

A pinned revision, hash, or Docker digest gives an artifact a stable identity; it does not make downloading that artifact at runtime a pure Nix operation.

### Appropriate boundary

Prefer:

```text
immutable input      -> derivation / fixed-output fetcher
declarative setting  -> NixOS option
runtime state        -> systemd / tmpfiles / application
runtime download     -> systemd service
on-demand work       -> socket/request-triggered service
activation-specific  -> activation script
```

Activation scripts should therefore remain small and activation-specific. Do not put expensive, network-dependent, or daemon-dependent work there unless you have verified that it genuinely belongs in activation.

## Nix Purity & Idiomatic Principles

**Nix is purely functional and lazy.** Every Nix expression should be declarative, referentially transparent, and free of evaluation-time side effects.

* **Declarative, not imperative.** Describe *what* the system should be, not *how* to build it. No shell loops that mutate state, no `rm -rf`, no ad-hoc `find/cp` heuristics. If a derivation needs a file, declare it as an input and produce it as an output.

* **Pure functions.** Nix evaluation and derivation inputs should not rely on current time, network access, or mutable global state.

* **Reproducibility over cleverness.** Prefer boring, explicit, minimal changes. Pin every input. Use `fetchFromGitHub`, `fetchCargoVendor`, `fetchNpmDeps` with hashes. Never assume a package exists in the ambient environment.

* **No mutation of `$src`.** The source tree is immutable. Use `postPatch` for source rewrites, `preBuild` for code generation that must happen before compilation, `buildPhase` for building only. Do not write to `$src` in `buildPhase`.

* **Runtime state is different from Nix purity.** Services may intentionally mutate `/var/lib`, `/run`, caches, databases, etc. That is runtime state, not a reason to move those operations into Nix evaluation or the store.

* **Single source of truth.** The flake is the only source of truth. Do not edit generated files directly; edit the template or flake that generates them.

## Working Directory

`/etc/nixos`. Repo is git on `main`. Do not activate or switch NixOS. Build and check configurations to test changes before

finishing whenever practical. The jail permits the `nix` CLI; use `nix build`,

`nix flake check`, and related read-only/build operations rather than `nixos-rebuild`,

which is intentionally shimmed. For example, a flake system can be tested with

`nix build --impure --print-out-paths .#nixosConfigurations.<host>.config.system.build.toplevel`.

Do not use activation commands to perform the test.

This file is generated from `home/llm/agents-gen/agents-md-template.md` (+

`home/llm/agents-manifest.nix`); `just switch` overwrites it — edit the

template/manifest, never this file. The llm agent user's dsh also loads it as

the user-global instruction file (`$DSH_HOME/AGENTS.md`, installed by

`home/llm/agent-home.nix`), so every dsh session gets it as global context

regardless of working directory.

## Stale-Reference Traps

* Model IDs: `home/llm/catalog.nix` is the single source of truth; they must match the

  router preset sections in `hosts/desktop/llamacpp.nix` and every consumer

  (`MINUSPOD_LLM_MODEL` in `home/minuspod.nix`, the dsh default model). Renaming a

  model means updating all of them.

* Local `*.local` name → port mapping: the `services` attrset in

  `hosts/desktop/local-ca.nix` drives Caddy vhosts, `/etc/hosts`, and the CA SANs;

  register new local services there.

* Socket-activated services (`whisper-service`, `ninfer-serve`) deliberately have no

  `wantedBy` and exit after their idle window (whisper: `autoStop`, ninfer: wrapper

  exit); do not make them boot-resident.

## Jail Contract

* Network is allowed.

* User jails run as the human user (home /home/b); system jails run as the `llm` agent user via `sudo -u llm` (home /home/llm), so they can edit the repo without being root.

* Read-only mounts (user jails): `/etc/nixos`, `/var/log`.

* Read-only mounts (system jails): `/var/log`, `/var/log/journal`, `/run/systemd`, `/etc/machine-id`, `/sys`, `/run/user`.

* Writable paths (system jails): `/etc/nixos`, `/home/llm`.

* Writable paths (user jails): working directory ($PWD); per-tool config dirs are whitelisted per tool.

* Denied commands: `home-manager`, `nix-channel`, `nix-env`, `nixos-install`, `nixos-rebuild` are stubbed to deny.

* Common packages available: `bashInteractive, curl, wget, jq, git, which, ripgrep, gnugrep, gnused, gawkInteractive, ps, findutils, gzip, unzip, systemd, gnutar, diffutils, gnupatch, strace, openssl, cfr, tcpdump, mitmproxy, jdk21, rtk, headroom, nix, nixGuard, sqlite, postgresql, mariadb.client, python3`

## KRunner Aliases

Use `xdg.desktopEntries.<name>.settings.Keywords` to add search aliases. Example Spectacle: `sn;screenshot;screen capture;spectacle`.
