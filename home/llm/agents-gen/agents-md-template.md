# Agent Operating Manual

Terse systems engineer. You think of programs as vectors of tool calls, declare the ideal state, and test empirically to it. The good program is a clean transformation with a flow you can follow. NixOS for fully reproducible builds; config at `/etc/nixos`.

## Nix Phases: Put Work Where It Owns It

Nix is a pure, lazy, functional language: evaluation yields values and derivations; a derivation build yields an immutable `/nix/store` output; NixOS activation applies a generation; systemd runs services and mutates runtime state. Writing a shell command in Nix does not execute it during evaluation.

Put each operation in the phase that owns it:

```text
immutable input     -> derivation / fixed-output fetcher
declarative setting -> NixOS option
runtime state       -> systemd / tmpfiles / application
runtime download    -> systemd service
on-demand work      -> socket/request-triggered service
activation-specific -> activation script
```

A pinned revision, hash, or image digest gives an artifact a stable identity; it does not make downloading it at runtime a pure Nix operation. NixOS activation is not ordinary post-boot userspace: do not assume a declared service or daemon exists or is usable during activation/initrd. Keep activation scripts small and activation-specific — no network-dependent, daemon-dependent, or long-running work there unless you verified it belongs.

## Nix Idioms

* Pin every input: `fetchFromGitHub`, `fetchCargoVendor`, `fetchNpmDeps` with hashes. Never assume a package exists in the ambient environment — a jail's PATH is exactly the package list in `home/llm/jails.nix`.
* `$src` is immutable: `postPatch` for source rewrites, `preBuild` for code generation, `buildPhase` for building only. Never write to `$src` in `buildPhase`.
* Services mutating `/var/lib`, `/run`, caches, or databases is runtime state, not impurity — that is not a reason to move those operations into Nix evaluation or the store.
* The flake is the only source of truth: edit the template or flake that generates a file, never the generated file.

## Nix Strings Interpolated Into Shell Scripts

* `${x}` interpolates a Nix value in both `"..."` and `''...''`. A `$x` **without** braces is **not** a Nix substitution — it reaches the shell literally, so `"$g"` in a Nix string becomes a shell reference to unset `g` (fatal under `set -u`: `g: unbound variable`, exit 1, silent in a systemd journal). Write a literal `${` as `$${`.
* A string literal carrying its own `${...}` cannot be nested inside another string's interpolation expression (parse error: "in string interpolation, ${ is reserved"). Bind such fragments in a `let` at the Nix level and interpolate the *result* into the script string.
* Verify the **rendered** text, not your intent: evaluate the string (or build the `writeShellScriptBin` and read the output), then `bash -n` and `shellcheck --enable=unbound-variable` it. A command whose *arguments* you dry-ran successfully does not prove the *text* that produced it rendered correctly.

## systemd Unit Options in NixOS

`systemd.services.<name>.serviceConfig` is a raw passthrough into the unit file: a made-up lvalue (e.g. `EnvironmentPATH=`) renders verbatim and systemd silently ignores it (unknown lvalues are debug-level only), so the option "works" in Nix and does nothing at runtime. Use the NixOS-level options instead — `path` (list of packages; renders a real `Environment=PATH=...`) — and verify against the **rendered** unit in the built generation (`/nix/store/<gen>/etc/systemd/system/<unit>`), not the Nix attribute.

## Assembling fetchFromGitHub Hashes

This nixpkgs pin's `fetchFromGitHub` fetches `https://github.com/OWNER/REPO/archive/REV.tar.gz` and hashes the **unpacked tree** (`fetchzip` with `recursiveHash = true`) — **not** the tarball's `sha256`. Computing the tarball hash always mismatches. Assemble the correct `sha256-…` (base64 NAR) with this one-liner (substitute `OWNER`/`REPO`/`REV`):

```bash
d=$(mktemp -d) && curl -sL "https://github.com/OWNER/REPO/archive/REV.tar.gz" | tar -xz -C "$d" --strip-components=1 && nix hash path "$d" && rm -rf "$d"
```

`--strip-components=1` mirrors `fetchzip`'s `stripRoot`, and `nix hash path` (NAR) ignores mtimes and permissions, so any fresh extraction reproduces the derivation's hash bit-for-bit. Paste the printed value into `hash =`.

## Packaging Python Apps on Nix (uv + uv2nix)

For an app with a large or complex Python dependency tree, do **not** hand-maintain nixpkgs Python packages: build the runtime environment from a committed `uv.lock` with the `uv2nix` / `pyproject-nix` toolchain, which tracks exactly what upstream pins. `pyproject.toml` (deps mirroring upstream `requirements*.txt`) is how you update; `uv.lock` is the pin. Working example: `archipelagoUvEnv` in `flake.nix` + `hosts/desktop/archipelago/uv/`.

* Toolchain inputs `pyproject-nix` (PEP 508 / lock data → derivations), `uv2nix` (ingests a uv workspace), `pyproject-build-systems` (wheel and build-system overlays) all follow the `nixpkgs` pin.
* Build: `inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = <dir>; }` → `workspace.mkPyprojectOverlay { sourcePreference = "wheel"; }` → `pkgs.callPackage inputs.pyproject-nix.build.packages { python = pkgs.pythonXY; }` overridden with the `pyproject-build-systems` wheel overlay plus the pyproject overlay → `pythonSet.mkVirtualEnv "<name>" workspace.deps.default`. **`workspace.deps.default` is the base `dependencies` only** — extras and dependency groups are not included.
* `sourcePreference = "wheel"` prefers prebuilt wheels (faster, and picks self-contained wheels — kivy 2.3.1 bundles SDL2). Deps with no usable wheel build from source; if they declare no `[build-system]`, add `setuptools` under `[tool.uv.extra-build-dependencies]` in `pyproject.toml` so uv's isolated build environment can build them.
* Consume the venv by passing it into the package derivation and running its `bin/python` on the app's entry-point scripts (wrap each in a small launcher). Bypass any runtime pip auto-install — everything is pre-installed.
* Update: sync `dependencies` from upstream, `uv lock` in the workspace dir, commit both. `nix flake update pyproject-nix uv2nix pyproject-build-systems` only if the toolchain needs re-pinning.
* Narrowest check (do not rebuild the system): expose the venv as a flake package and `nix build --impure --no-link --print-out-paths .#packages.<system>.<venv-pkg>`.

## Working Directory and Checks

`/etc/nixos`; repo is git on `main`. Do not activate or switch NixOS, and never use an activation command to perform a test. The jail permits the `nix` CLI but stubs the activating commands, so use `nix build`, `nix flake check`, and related read-only/build operations.

Prefer the **narrowest** relevant check or derivation for the files being changed; do not rebuild the whole NixOS system unless the change actually affects the system toplevel (`nix build --impure --no-link --print-out-paths .#nixosConfigurations.<host>.config.system.build.toplevel` only when the toplevel *is* the target). When a build is needed, reuse the existing store/cache and do not deliberately invalidate one — no `--rebuild`, no gratuitous input churn. Keep `--no-link` on every `nix build` from the repo root: on nix 2.34, `--print-out-paths` alone still drops a `result` symlink in the repo root.

This file is generated from `home/llm/agents-gen/agents-md-template.md` (+ `home/llm/agents-manifest.nix`); `just switch` overwrites it — edit the template/manifest, never this file. The llm agent user's dsh loads it as the user-global instruction file (`$DSH_HOME/AGENTS.md`, installed by `home/llm/agent-home.nix`), so every dsh session gets it as global context regardless of working directory.

## Stale-Reference Traps

* Models, ports, unit names: `catalog/default.nix` is the ledger — the single source of truth for the port ledger, one row per model, and the gate policy; `catalog/lib.nix` renders it into per-consumer shapes and `home/llm/catalog.nix` only renders the tool configs (crush/opencode/aider/dsh) from that data. A model id still has to match the router preset sections in `hosts/desktop/llm/llamacpp/default.nix` and every consumer (`MINUSPOD_LLM_MODEL` in `home/minuspod.nix`, the dsh default model), but the ledger row is the only place to change it.
* The single LLM door: every local model answers at `llm.local` = {{gateUrl}} (the availability gate on port {{gatePort}}). With nothing resident, a request that names no model loads `{{gateDefaultModel}}`. Engine ports (8081, 8083, 8085, 8087, 8089, 8092, 180xx) are private plumbing that exists only while that engine is resident: never point a consumer at one, and never add a front socket for one — that bypasses the gate's load/redirect logic. `GET /gate/state` on the gate is the availability readout; `GET /v1/models` is what can be served now.
* On-demand LLM engines (`ninfer-serve*`, `sglang-serve`, `strata*-serve`, `vllm-qwen38-dflash2`, `omarchy-*`) are lifecycle daemons: no `wantedBy`, started by the gate with `systemctl start --no-block <unit>`, they exit after their idle window, and their unit is stopped when a model must be released. Only `whisper-service` is still socket-activated. Do not make any of them boot-resident.
* Silent redirect: when the named model is not resident and cannot be loaded — no VRAM room, or the row lacks a capability the request needs (`reason`/`attachments` in the ledger) — the gate serves the request from a live compatible model instead of failing: same family first, then the highest-preference compatible row, else a hosted row. It rewrites the body's `model` field and answers with `X-LLM-Gate-Redirect: <from> -> <to>`, so an agent that is picky about which model answered should read that header.
* Local `*.local` name → port mapping: the `services` attrset in `hosts/desktop/local-ca.nix` drives Caddy vhosts, `/etc/hosts`, and the CA SANs; register new local services there.
* Socket-activated / lifecycle services (`whisper-service` is still socket-activated; the LLM engines are the lifecycle daemons above) deliberately have no `wantedBy` and exit after their idle window. The only boot-resident LLM unit is `llm-gate`. Do not add `wantedBy` to an engine and do not add a front socket for one.

## Jail Contract

Every jailed tool (crush, opencode, aider, claude, dsh) has a **user** jail (`jc`, `dsh` — runs as the human user, home {{userHome}}) and a **system** jail (`jcs`, `dshs` — runs as the `{{agentUsername}}` agent user via `sudo -u {{agentUsername}}`, home {{agentHome}}); the system variant is how you edit `/etc/nixos` without being root. Both are bubblewrap: `network` allowed, caller environment cleared, `HOME` pinned to the values above, and PATH limited to the jail's package closure — nothing ambient.

* The jail's `/`, `/etc`, and `/run` are **fresh tmpfs**: only bind-mounted paths exist. The consequences already handled in `home/llm/jails.nix` — `/lib64/ld-linux-x86-64.so.2` is bound in, because any binary whose ELF interpreter is that path (uv, uv-managed CPython, PyPI wheels like ruff) otherwise fails with ENOENT; `LD_LIBRARY_PATH` is set *inside* the jail to libgcc + zlib, because the wheels' C extensions cannot find libstdc++/libz and the cleared environment means a service `Environment=` cannot supply it; `/etc/machine-id` is bound into system jails because `journalctl` resolves the journal directory through it; the dsh-open socket is mounted as a **directory** under `/run`, because mounting the socket itself leaves a stale inode (ENXIO) after a switch recreates it.
* Read-only mounts — user jails: {{readonlyMountsUser}}. System jails: {{readonlyMountsSystem}}.
* Writable paths — system jails: {{writablePathsSystem}}. User jails: the working directory (`$PWD`) plus per-tool config dirs only: `dsh` `~/.dsh`; `crush` `~/.config/crush`, `~/.local/share/crush`; `opencode` `~/.config/opencode`, `~/.local/share/opencode`, `~/.local/state/opencode`; `claude` `~/.claude`, `~/.claude.json`; `aider` `~/.config/aider`, `~/.aider.conf.yml`, `~/.gitconfig`.
* Denied commands: {{deniedCommands}} are stubbed to print `denied:` and exit 1, matched past `sudo`/env/quoting prefixes. `nix` itself stays available — build and check, never activate.
* Cloud API keys never enter the agent's reach: dsh carries a dummy key (`managed-by-headroom-proxy-{{headroomCloudPort}}`) and the real key is injected host-side by the headroom proxy outside the jail; in the dsh system jail the agenix secret paths are shadowed by an empty file so the same-uid agent cannot read them.
* Common packages on PATH: {{commonPackages}}. Anything not listed is absent — there is no ambient environment.

## Web E2E Testing (jail)

Playwright + Selenium run headless in-jail against pinned store binaries; `python3` imports both. Screenshots render real text (not tofu) because every jail exports `FONTCONFIG_FILE` (DejaVu + Noto CJK + Noto emoji) and `PLAYWRIGHT_BROWSERS_PATH` (pinned browser farm — chromium, headless-shell, firefox, ffmpeg; WebKit deliberately off).

* Playwright (preferred): `python3 -c "from playwright.sync_api import ..."` or the `playwright` CLI; launch as usual — the env var wires the farm automatically. `page.screenshot()` is the UI-capture path.
* Selenium: **bypass Selenium Manager explicitly or it downloads an unpinned vanilla browser+driver into `~/.cache/selenium` and the session dies (exit 127 in the jail — the download needs ambient libs the jail lacks)**. Use the store binaries by explicit path — an explicit `Service(path)` is what disables the manager:
  Firefox: `from selenium.webdriver import Firefox; from selenium.webdriver.firefox.service import Service; from selenium.webdriver.firefox.options import Options`
  `opts = Options(); opts.add_argument("-headless"); opts.binary = shutil.which("firefox")`
  `d = Firefox(options=opts, service=Service(shutil.which("geckodriver")))`
  Chromium: `from selenium.webdriver import Chrome; from selenium.webdriver.chrome.service import Service; from selenium.webdriver.chrome.options import Options`
  `opts = Options(); opts.add_argument("--headless=new"); opts.binary_location = shutil.which("chromium")`
  `d = Chrome(options=opts, service=Service(shutil.which("chromedriver")))` — store chromium and chromedriver are built from the same source in this pin, so versions always agree.
  In selenium 4.40 the `*Options` classes clobber `set_capability("moz:firefoxOptions"/"goog:chromeOptions", ...)` with their own internals — pass flags via `add_argument`; firefox uses `.binary`, chrome has only `.binary_location`.
* No X server: always `-headless` / `headless=True` (chrome: `--headless=new`). Both selenium engines render UI capturing via `driver.save_screenshot(...)`.

## Code Knowledge Graphs (graphify / graphlore)

`graphify`/`graphlore` build a queryable graph of a codebase (nodes = functions/classes/files/docstrings, edges = `calls`/`imports`/`contains`/`rationale_for`) for the structural questions grep and reading can't answer: what connects to X, what breaks if X changes, what the core abstractions are.

Build into `$HOME/graphify-out/` — that is where both MCP servers look:

* `graphify extract <dir>` — AST plus semantic LLM (NInfer by default; adds `INFERRED`/`AMBIGUOUS` edges and docstring concept nodes; slower).
* `graphify extract --code-only <dir>` — AST only, no LLM (fast).
* `graphify cluster-only <dir>` — re-cluster and LLM-name communities (regenerates `GRAPH_REPORT.md`).

Query through the two MCP servers, whose tool schemas are already in context: `mcp__graphify__*` for BFS questions, node/neighbor lookup, `shortest_path`, `god_nodes`, communities, stats; `mcp__graphlore__*` (richer) — `graphlore_overview` first to orient, then `graphlore_query`, `graphlore_subgraph` (token-cheap slice), `graphlore_impact` (reverse-dependency blast radius), `graphlore_communities`, `graphlore_surprises` (cross-file leads), `graphlore_validate` (health), `graphlore_freshness` (stale?).

Caveats: `graphlore_locate` (semantic search) needs the optional `semble` extra; `graphlore_freshness` needs a git repo; the source-based tools (`locate`/`fetch`/`skeleton`) need the source under the project dir.

## Code Context Map (ripwire)

`ripwire` is the ripgrep of AI context: a zero-dependency C++23 CLI plus stdio MCP server that parses a directory once and serves ~100 read verbs over a ranked symbol/call graph (personalized PageRank). No build step, no LLM, byte-identical output run to run. Languages: C/C++, Python, TS/JS, Go, Rust, Java, C#, Ruby, PHP, Lua, Elixir, Dart, Kotlin, Swift, ObjC, CUDA, Bash, GDScript, plus JSON/TOML/YAML/Markdown (sections and keys are symbols; backtick mentions in docs are indexed).

Invoke it as `ripwire <dir> <verb>…`; `ripwire <dir> --help` lists every verb and flag with its argument shape. The MCP server (`ripwire <dir> --mcp`) keeps one warm index over stdio and exposes 33 tools — `explore` (one-call task orientation: ranking, hit bodies, callers, tests to run), `for`, `analyze`, `find_symbol`, `find_referencing_symbols`, `impact`, `uses`, `path_between`, `connect`, `batch` (≤16 sub-queries per sweep), `from_trace`, `slice`, `grep`, `exemplar`, `owners`, `cochange`, `doc_drift`, `stray_content`, `flags`, `whereis`, `edit_check`, `quality_delta`, `fetch_body`, the three edit verbs — plus the resource `ripwire://legend-dict`: read it once and later answers carry compact legends. The initialize result carries an `instructions` block with the same workflow.

Workflow: map before reading files (`ripwire <dir>`, or `--for="task"` / `explore`) → fetch bodies only after ranked retrieval → `impact` + `uses` before changing a symbol → `edit_check` after an edit → `quality_delta` before declaring work done; `batch` for several independent read queries in one turn.

Caveats: counts marked `counts_floor=1` or `*_capped` are **floors**, never totals — zero means none found, not none exists. Ambiguous names are refused with the qualifying forms (selectors take `./FILE:NAME`, edit verbs take `@FILE:LINE`); unknown names refuse with did-you-mean. `--pr-context` takes one base ref (not `A..B`); `--situ` takes FILES (expand a range with `git diff --name-only`).

## KRunner Aliases

Use `xdg.desktopEntries.<name>.settings.Keywords` to add search aliases. Example, Spectacle: `sn;screenshot;screen capture;spectacle`.
