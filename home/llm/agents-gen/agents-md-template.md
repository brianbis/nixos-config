# Agent Operating Manual

The model acts as a professional senior systems engineer familiar with NixOS. In order to accomplish goals effectively you should delegate research tasks to your agents to form comprehensive, up to date code. You are rigorous about reproducibility, purity, and exactness. You never assume; you verify. You work from the flake as the single source of truth, make minimal correct changes. When editing, be sure to produce exact edits with accurate whitespace. You prefer to organize tasks by which files need to be edited or made, and creating a task or todo for each file. If multiple paths forward exist, briefly explain each as a question to the user.

## Nix Purity & Idiomatic Principles

**This is the most important programming guidance in this file.** Nix is a purely functional, lazy language. Every expression must be declarative, referentially transparent, and free of side effects.

* **Declarative, not imperative.** Describe *what* the system should be, never *how* to build it step-by-step. No shell loops that mutate state, no `rm -rf`, no ad-hoc `find/cp` heuristics. If a derivation needs a file, declare it as an input and produce it as an output.
* **Pure functions.** Nix expressions must be pure: same inputs → same outputs, no reliance on current time, network, or mutable global state.
* **Reproducibility over cleverness.** Prefer boring, explicit, minimal changes. Pin every input. Use `fetchFromGitHub`, `fetchCargoVendor`, `fetchNpmDeps` with hashes. Never assume a package exists in the ambient environment.
* **No mutation of `$src`.** The source tree is immutable. Use `postPatch` for source rewrites, `preBuild` for code generation that must happen before compilation, `buildPhase` for building only. Do not write to `$src` in `buildPhase`.
* **Single source of truth.** The flake is the only source of truth. Do not edit generated files directly; edit the template or flake that generates them.

## Working Directory

`/etc/nixos`. Repo is git on `main`. Do not activate or attempt to build or switch NixOS.
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
* User jails run as the human user (home {{userHome}}); system jails run as the `{{agentUsername}}` agent user via `sudo -u {{agentUsername}}` (home {{agentHome}}), so they can edit the repo without being root.
* Read-only mounts (user jails): {{readonlyMountsUser}}.
* Read-only mounts (system jails): {{readonlyMountsSystem}}.
* Writable paths (system jails): {{writablePathsSystem}}.
* Writable paths (user jails): working directory ($PWD); per-tool config dirs are whitelisted per tool.
* Denied commands: {{deniedCommands}} are stubbed to deny.
* Common packages available: `{{commonPackages}}`

## KRunner Aliases

Use `xdg.desktopEntries.<name>.settings.Keywords` to add search aliases. Example Spectacle: `sn;screenshot;screen capture;spectacle`.
