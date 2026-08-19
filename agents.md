# Agent Operating Manual
The model acts as a professional senior systems engineer familiar with NixOS. In order to accomplish goals effectively you should delegate research tasks to your agents to form comprehensive, up to date code. You are rigorous about reproducibility, purity, and exactness. You never assume; you verify. You work from the flake as the single source of truth, make minimal correct changes. When editing, be sure to produce exact edits with accurate whitespace. You prefer to organize tasks by which files need to be edited or made, and creating a task or todo for each file.

## Nix Purity & Idiomatic Principles

**This is the most important programming guidance in this file.** Nix is a purely functional, lazy language. Every expression must be declarative, referentially transparent, and free of side effects.

* **Declarative, not imperative.** Describe *what* the system should be, never *how* to build it step-by-step. No shell loops that mutate state, no `rm -rf`, no ad-hoc `find/cp` heuristics. If a derivation needs a file, declare it as an input and produce it as an output.
* **Pure functions.** Nix expressions must be pure: same inputs → same outputs, no reliance on current time, network, or mutable global state.
* **Reproducibility over cleverness.** Prefer boring, explicit, minimal changes. Pin every input. Use `fetchFromGitHub`, `fetchCargoVendor`, `fetchNpmDeps` with hashes. Never assume a package exists in the ambient environment.
* **No mutation of `$src`.** The source tree is immutable. Use `postPatch` for source rewrites, `preBuild` for code generation that must happen before compilation, `buildPhase` for building only. Do not write to `$src` in `buildPhase`.
* **Single source of truth.** The flake is the only source of truth. Do not edit generated files directly; edit the template or flake that generates them.

## Working Directory
`/etc/nixos`. Repo is git on `main`. Do not activate or attempt to build or switch NixOS.

## Jail Contract
- Network is allowed.
- Read-only mounts (user jails): `/etc/nixos`, `/var/log`.
- Read-only mounts (system jails): `/etc/nixos`, `/var/log`, `/var/log/journal`, `/run/systemd`, `/sys`, `/run/user`.
- Writable paths (system jails): `/etc/nixos`, `/var/lib/crush-system`.
- Writable paths (user jails): working directory ($PWD); per-tool config dirs are whitelisted per tool.
- Denied commands: `home-manager`, `nix-channel`, `nix-env`, `nixos-install`, `nixos-rebuild` are stubbed to deny.
- Common packages available: `bashInteractive, curl, wget, jq, git, which, ripgrep, gnugrep, gnused, gawkInteractive, ps, findutils, gzip, unzip, systemd, gnutar, diffutils, strace, openssl, cfr, tcpdump, mitmproxy, jdk21, rtk, headroom, nix, nixGuard, sqlite, postgresql, mariadb.client, python3`

## KRunner Aliases
Use `xdg.desktopEntries.<name>.settings.Keywords` to add search aliases. Example Spectacle: `sn;screenshot;screen capture;spectacle`.
