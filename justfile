set shell := ["bash", "-cu"]

secrets-dir := "secrets"
# The agenix identity is the TPM-unsealed key (hosts/desktop/security.nix).
# These recipes run under sudo, so root can read the 0400 tmpfs key.
identity-key := "/run/agenix-tpm/key.txt"

# Cap build parallelism. The box is 24 cores / 64 GB with NO swap, so an
# uncapped 24-way rustc build of the heavy local Rust package (librepods:
# iced/wgpu/winit + bluer + libpulse + dbus) would OOM and hard-crash the box.
# The caps below keep it within the memory budget: --cores caps rustc
# parallelism INSIDE a cargo build (NIX_BUILD_CORES) and --max-jobs caps how
# many derivations build at once. 4-way is the safe setting. These are
# client-side flags, so they apply to the very next build (no chicken-and-egg:
# no successful switch required first).
build-flags := "--cores 4 --max-jobs 4"

secret-edit name:
    @mkdir -p {{secrets-dir}}
    sudo EDITOR="nano" agenix -e {{secrets-dir}}/{{name}}.age -i {{identity-key}}

secret-show name:
    sudo age -d -i {{identity-key}} {{secrets-dir}}/{{name}}.age

secret-check name:
    @sudo age -d -i {{identity-key}} {{secrets-dir}}/{{name}}.age >/dev/null
    @echo "{{name}}: OK"

secrets-check:
    @for f in {{secrets-dir}}/*.age; do \
        echo "Checking $f"; \
        sudo age -d -i {{identity-key}} "$f" >/dev/null || exit 1; \
    done
    @echo "All secrets OK"

secrets-list:
    @ls -1 {{secrets-dir}}/*.age 2>/dev/null || echo "No secrets found in {{secrets-dir}}"

stage:
    sudo git add .

auto-stage:
    sudo rm -f result result-*
    @if ! sudo git diff --quiet || [ -n "$(sudo git status --porcelain)" ]; then \
        echo "Staging changes..."; \
        sudo git add .; \
    fi

# NixOS build & rebuild. This repo now describes TWO machines
# (nixosConfigurations = [ "nixos" "nixos-vm" ]), so a bare `--flake .` is no
# longer unambiguous and would resolve to the desktop only by luck of
# attribute order. Every rebuild target therefore names the machine, defaulted
# to the desktop's attribute (`nixos`) so `just switch` keeps meaning the
# desktop; the Proxmox guest is `just switch nixos-vm`.
switch host="nixos":
    just auto-stage
    sudo nixos-rebuild switch --flake ".#{{host}}" {{build-flags}}
    @sudo nix build --no-link .#agents-md --print-out-paths | xargs -I{} sudo cp {} AGENTS.md

build host="nixos":
    just auto-stage
    sudo nixos-rebuild build --flake ".#{{host}}" {{build-flags}}

check host="nixos":
    nixos-rebuild dry-build --flake ".#{{host}}"

diff:
    nix store diff-closures /nix/var/nix/profiles/system ./result

update:
    # Runs as llm: the flake repo is owned by the llm agent user (see
    # hosts/desktop/host.nix), so flake.lock must be written by llm.
    #
    # This only moves the ROOT lock. The guest's own hosts/nixos-vm/flake.lock
    # pins nixpkgs by exact revision, so it cannot drift; what does change here
    # is the path: input's contentHash as the guest's config tree is edited.
    # To re-resolve the guest's own inputs: nix flake update --flake hosts/nixos-vm
    sudo -u llm nix flake update

save message="NixOS configuration update":
    sudo git add -A .
    if sudo git diff --cached --quiet; then \
        sudo git -c user.name="b" -c user.email="brianbis@gmail.com" commit --amend -m "{{message}}"; \
    else \
        sudo git -c user.name="b" -c user.email="brianbis@gmail.com" commit -m "{{message}}"; \
    fi

push message="NixOS configuration update":
    just save "{{message}}"
    sudo GIT_SSH_COMMAND="ssh -i /home/b/.ssh/id_ed25519" git fetch origin
    sudo GIT_SSH_COMMAND="ssh -i /home/b/.ssh/id_ed25519" git push --force-with-lease

# LAN CI door: the yzerd physical box keeps its own copy of the whole tree at
# /etc/nixos and runs its own `ci` runner there (see hosts/yzerd/README.md,
# "CI box"). The git wire is desk-side only — the DESK holds the private keys
# both pubkeys are authorized on the box (hosts/yzerd/default.nix:108-111) — so
# push/pull run here and the box never needs a key toward the desk. `ci-push`
# also checks the tree out on the box: a push to a non-bare repo moves the ref,
# not the files, and the box's gates read the FILES. Do NOT hardcode `-i
# /home/llm/...`: the desktop user is `b` too and cannot read the agent user's
# key (Permission denied -> password fallback). Password auth to the box works
# from a b shell today (hosts/yzerd/default.nix:104 declares it); for a key
# instead, put the box address in your ~/.ssh/config Host block and set ci-host
# to that alias — the two authorized keys on the box are exactly the ones the
# desk can present.
ci-host := "b@192.168.5.186"
yz-door := "ssh://{{ci-host}}//etc/nixos"
# Your key: generate it ONCE (ssh-keygen -f ~/.ssh/id_ci -N ''; ssh-copy-id -i
# ~/.ssh/id_ci b@192.168.5.186) and every leg below answers key-only — ssh with
# a missing -i still falls back to password, so this line is safe before the
# keygen. Paste the new pubkey into the box's authorizedKeys list in
# hosts/yzerd/default.nix:112 so the switch keeps authorizing it forever.
ci-key := "-i ~/.ssh/id_ci"

ci-push:
    GIT_SSH_COMMAND="ssh {{ci-key}}" git push {{yz-door}} HEAD:main
    ssh {{ci-key}} {{ci-host}} 'git -C /etc/nixos checkout -f main'

ci-pull:
    GIT_SSH_COMMAND="ssh {{ci-key}}" git pull {{yz-door}} main

# Bootstrap (box without git): stream the COMMITTED tree to the box. Extract
# into a CLEAN dir, never onto the box's /etc/nixos — that is its own older
# copy, and leftover files there would make the box's flake-self differ from
# the desk's and silently break the offload (identical trees => identical
# drv hashes; that equality is the whole point). Box-side switch door after
# this ships: sudo nixos-rebuild switch --flake /srv/ci-repo#yzerd.
ship:
    ssh {{ci-key}} {{ci-host}} 'sudo mkdir -p /srv/ci-repo && sudo chown -R b:b /srv/ci-repo'
    git archive --format=tar.gz HEAD | ssh {{ci-key}} {{ci-host}} 'tar -x -z -C /srv/ci-repo'

# Progress readout for whatever yzerd is doing right now: which builds are
# alive (etime), store paths written in the last 5 min, newest paths — the
# build's live edge. Ctrl-C on switch-remote kills the LOCAL tail only; the
# remote build keeps running as an orphan, so duplicates here are normal —
# they all converge on the same valid paths.
ci-watch:
    ssh {{ci-key}} {{ci-host}} 'ps -eo etime,cputime,args | grep -E "nix build|nix-build" | grep -v grep; echo NEW-5MIN=$(find /nix/store -maxdepth 1 -type d -newermt "-5 minutes" 2>/dev/null | wc -l); ls -t /nix/store | head -8'

# Percent-done for the toplevel build ON THE BOX: BFS the toplevel drv's input
# graph, count valid outputs. Needs the script on the box — `ship` carries it;
# after that this door is one ssh call, run it every few minutes.
# Percent-done for the desktop toplevel building ON THE BOX: ssh the progress
# script straight out of the repo (no ship needed) and run it there. BFS of
# the toplevel drv's inputDrvs graph — valid drvs are not expanded, so
# "pending" is exactly the work still left. depth= is graph distance, not time.
ci-progress:
    ssh {{ci-key}} {{ci-host}} 'bash -s' < /etc/nixos/hosts/yzerd/ci-progress.sh

ci-gate:
    ssh {{ci-key}} {{ci-host}} '/run/current-system/sw/bin/ci gate'

ci-fix:
    ssh {{ci-key}} {{ci-host}} '/run/current-system/sw/bin/ci fix'

ci-status:
    ssh {{ci-key}} {{ci-host}} '/run/current-system/sw/bin/ci status'

# The offload door: run `just switch` (same activation, same desktop) but pay
# the heavy toplevel build on yzerd instead of the desk — the desk spends its
# minutes activating, not its hours computing. Mechanics, all LAN-ssh:
#   1. `ship` (NOT ci-push — the box has no git yet, its generation predates
#      ci.nix; run `just save` FIRST, the box builds what HEAD says and the
#      desk must evaluate the same tree, nothing staged-but-uncommitted);
#   2. `nix build` of the DESKTOP toplevel on the box: b's nix client talks to
#      the box's own daemon, so the build is privileged there (uid b alone
#      could not realize input-addressed drvs, the daemon can);
#   3. the result comes back as two store imports over the wire — the output
#      closure (the system itself) and the drv+source closure, so the desk's
#      later `nixos-rebuild switch` finds that drv already valid: its build
#      is a no-op and only activation runs locally. Unsigned nar imports are
#      trusted-locally by design; that is what sidesteps the sig gate here.
# 8/8 caps mirror the CI runner's, not the desk's 4/4 (that throttle exists
# because the 4-core desk OOM'd; yzerd is 32c/125G and is allowed more).
# The mechanics now live in hosts/desktop/ci-offload.sh: same steps PLUS an
# auto-debug loop for stuck builds — a failed box build feeds its error tail
# to the desk's own gate (llm.local :8100, the interactive coder model), and
# the returned patch is applied ONLY if every touched path is an existing
# tracked *.nix (flake.nix, hosts/**, home/**, catalog/**), committed as
# "ci-fix (desk-build)", re-shipped, re-built — max 3 tries (CI_TRIES). It
# never activates anything, on either side: activation stays `just switch`,
# yours. Env knobs: CI_HOST CI_KEY CI_TRIES. Run `just save` first — the
# script itself refuses while the repo is dirty, because HEAD is exactly what
# the box builds and what the desk must evaluate.
switch-remote:
    bash /etc/nixos/hosts/desktop/ci-offload.sh
    just switch

gc:
    sudo nix-collect-garbage -d

generations:
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

rollback host="nixos":
    sudo nixos-rebuild switch --rollback --flake ".#{{host}}" {{build-flags}}

# vLLM docker containers (the K2-Horizon + LensVL checkpoints). The Qwen3.8
# DFlash2 engine is now a NATIVE process (see vllm-dflash2-* below), not a
# container. Only ever run ONE at a time: they fight over VRAM.

vllm-containers := "docker-vllm-k2horizon-nvfp4 docker-vllm-lensvlm"

# Start commands

vllm-k2horizon-nvfp4:
    sudo systemctl start docker-vllm-k2horizon-nvfp4.service

vllm-lensvlm:
    sudo systemctl start docker-vllm-lensvlm.service

# Qwen3.8 DFlash2 NATIVE engine (no docker). On-demand like every gated engine:
# the gate on :8100 starts it when a request names it, and it unloads after its
# idle window. :18090 is its private engine port — it exists only while resident,
# so nothing fronts it. These recipes inspect / stop the lifecycle unit.
vllm-dflash2-status:
    sudo systemctl status vllm-qwen38-dflash2.service --no-pager

vllm-dflash2-stop:
    sudo systemctl stop vllm-qwen38-dflash2.service

# Keep the old name as a no-op alias so muscle memory / docs don't break: the
# DFlash2 engine is no longer a manually-started docker container.
vllm-qwen38-dflash2:
    @echo "The DFlash2 engine is now a native, gate-loaded process (no docker, no socket)."
    @echo "Name it in a request to the gate on http://127.0.0.1:8100 and it loads; it unloads when idle."
    @echo "Use: just vllm-dflash2-status / just vllm-dflash2-stop"

# Infer running container and stop it

vllm-stop:
    #!/usr/bin/env bash
    for c in {{vllm-containers}}; do
        if sudo systemctl is-active --quiet "$c.service"; then
            echo "Stopping $c"
            sudo systemctl stop "$c.service"
            exit 0
        fi
    done
    echo "No vLLM container running"

# Infer running container and show status
vllm-status:
    #!/usr/bin/env bash
    for c in {{vllm-containers}}; do
        echo "checking $c"
        if sudo systemctl is-active --quiet "$c.service"; then
            echo "vLLM running: $c"
            sudo systemctl status "$c.service" --no-pager
            exit 0
        fi
    done
    echo "No vLLM container running"

# SGLang native engine (Qwen3.8-27B NVFP4, no docker). On-demand like every
# gated engine: the gate on :8100 starts it when a request names it, and it
# unloads after its idle window. :8087 is its private engine port — it exists
# only while resident, so nothing fronts it. These recipes inspect / stop the
# lifecycle unit.
sglang-status:
    sudo systemctl status sglang-serve.service --no-pager

sglang-stop:
    sudo systemctl stop sglang-serve.service

# Shortcuts
alias s := switch
alias sw := switch
alias apply := switch
alias rebuild := switch
alias rs := switch

alias b := build
alias c := check
alias u := update

alias se := secret-edit
alias ss := secret-show
alias sc := secret-check

agents-md:
    nix build --no-link .#agents-md --print-out-paths

# Format the whole repo with pre-commit (see .pre-commit-config.yaml).
# Idempotent; run before `just save`. The nix package is on the shell so the
# system hooks' `nix run` entries resolve in the daemon's mount namespace.
fmt:
    @nix shell nixpkgs#pre-commit nixpkgs#nix -c pre-commit run --all-files

alias f := fmt

# dsh web GUI
#
# dsh mints a per-process launch token at startup (printed to the journal)
# that a browser exchanges for a 30-day signed cookie
# (hosts/desktop/dsh-web.nix). Once the cookie is set you don't need the token
# again until it expires (~30 days) or you clear cookies. Run `just dsh-url` to
# (re-)authenticate a browser: first access via a host, after ~30 days, or
# after clearing cookies. The two doors are dsh.local (Caddy, loopback;
# caddy.nix) and dsh.tail835824.ts.net (tailscale serve; networking.nix).
dsh-url:
    #!/usr/bin/env bash
    set -uo pipefail
    # Read the journal without sudo first (works when the user has journal
    # access); fall back to sudo otherwise.
    log="$(journalctl -u dsh-web -o cat --no-pager 2>/dev/null || sudo journalctl -u dsh-web -o cat --no-pager 2>/dev/null || true)"
    token="$(printf '%s\n' "$log" | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1 | cut -d= -f2 || true)"
    if [ -z "$token" ]; then
      echo "dsh-url: no token in the dsh-web journal; is dsh-web running?" >&2
      exit 1
    fi
    echo "dsh web token: $token"
    echo
    echo "  https://dsh.local/?token=$token"
    echo "  https://dsh.tail835824.ts.net/?token=$token"

# Bump dsh to the newest npm-published release. Plain `nix flake update` never
# moves dsh: the dsh input is pinned to a release tag in flake.nix (its
# tarball's production deps are all published, so the npm-closure pin is
# resolvable), so `just switch` always works against committed pin data.
# This recipe is the explicit "new release" door: it points the dsh input at
# the newest npm dist-tag (dsh-v<latest>), then atomically refreshes all three
# pins — flake.lock (tag rev), the npm-closure data files
# (package-lock.json + deps-sha256.json via update-deps.py, stamped
# _meta.srcRev), and the fetchPnpmDeps hash in tarball.nix (the pnpm-side
# store pin; the refresh is "set hash='', build, paste the hash nix reports").
# Any failure rolls the snapshot back, leaving the repo exactly as found.
dsh-repin:
    #!/usr/bin/env bash
    set -Eeuo pipefail
    cd "$(git -C /etc/nixos rev-parse --show-toplevel)"
    D=home/llm/dsh

    # --- resolve target release ---------------------------------------------
    # Latest published version (registry dist-tags.latest).
    ver="$(curl -fsSL "https://registry.npmjs.org/@deepseek-ai%2fdsh" \
      | sed -n 's/.*"dist-tags"[^}]*"latest":"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$ver" ] || { echo "dsh-repin: cannot read npm dist-tags" >&2; exit 1; }
    newref="dsh-v$ver"
    # The repo's release tag is lightweight; ls-remote returns the commit.
    tagrev="$(git ls-remote https://github.com/deepseek-ai/deepseek-harness \
      "refs/tags/$newref" | awk '{print $1}' | head -1)"
    [ -n "$tagrev" ] || { echo "dsh-repin: upstream has no tag $newref" >&2; exit 1; }

    curref="$(sed -n 's@^ *url = "github:deepseek-ai/deepseek-harness/\([^"]*\)".*$@\1@p' flake.nix | head -1)"
    currev="$(jq -r '.nodes.dsh.locked.rev' flake.lock)"
    # The pins are part of the "already there" test: the input can sit at the
    # target rev while package-lock.json still names an older srcRev, which is
    # exactly the state package.nix refuses at evaluation.
    pinsrev="$(jq -r '._meta.srcRev // ""' "$D/package-lock.json")"
    if [ "$curref" = "$newref" ] && [ "$currev" = "$tagrev" ] && [ "$pinsrev" = "$currev" ]; then
      echo "dsh-repin: already at latest ($ver @ ${tagrev:0:12}) — nothing to do"
      exit 0
    fi
    echo "dsh-repin: $curref@${currev:0:12} -> $newref@${tagrev:0:12}"

    # --- snapshot for atomic rollback ----------------------------------------
    snap="$(mktemp -d)"
    cleanup() { rm -rf "$snap"; }
    rollback() {
      echo >&2
      echo "dsh-repin: FAILED — rolling back flake.nix, flake.lock, pin data" >&2
      cp "$snap/flake.nix" "$snap/flake.lock" flake.nix flake.lock 2>/dev/null \
        || cp "$snap/flake.nix" flake.nix; cp "$snap/flake.lock" flake.lock
      cp "$snap"/package-lock.json "$snap"/deps-sha256.json "$snap"/tarball.nix "$D"/
      cleanup
    }
    trap cleanup EXIT
    trap 'rollback; exit 1' ERR
    cp flake.nix flake.lock "$D/package-lock.json" "$D/deps-sha256.json" "$D/tarball.nix" "$snap"/

    # --- 1. move the dsh input -----------------------------------------------
    sed -i "s@github:deepseek-ai/deepseek-harness/[^\"]*@github:deepseek-ai/deepseek-harness/$newref@" flake.nix
    nix flake update dsh
    newrev="$(jq -r '.nodes.dsh.locked.rev' flake.lock)"
    [ "$newrev" = "$tagrev" ] || { echo "dsh-repin: locked rev $newrev != tag rev $tagrev" >&2; exit 1; }
    src="$(nix build --impure --no-link --print-out-paths .#packages.x86_64-linux.dsh-src)"

    # --- 2. npm-closure pin (package-lock.json + deps-sha256.json) -----------
    # npm comes from the *pinned* nixpkgs nodejs, placed on PATH instead of being
    # pulled in with `nix shell`: nix shell runs the command in a sandbox whose
    # /etc/ssl/certs symlink dangles (the nss-cacert store path is not bound in),
    # so node has no CA bundle and every registry https fails with
    # UNABLE_TO_GET_ISSUER_CERT_LOCALLY — npm retries 3x with a ~50s backoff, so
    # ~560 packages would take hours. update-deps.py is stdlib-only; python3 is
    # already on the default PATH (line 285 uses it).
    node="$(nix eval --impure --raw --expr '(import (builtins.getFlake "/etc/nixos").inputs.nixpkgs { system = "x86_64-linux"; }).nodejs.outPath')"
    PATH="$node/bin:$PATH" python3 "$D/update-deps.py" "$src" "$newrev"

    # --- 3. fetchPnpmDeps store pin (the hash in tarball.nix) -----------------
    sed -i -E 's/^( *)hash = .*$/\1hash = "";/' "$D/tarball.nix"
    report_err="$(mktemp)"
    if ! nix build --impure --no-link --print-out-paths .#packages.x86_64-linux.dsh-tarball > /dev/null 2>"$report_err"; then
      # nix 2.34 prints the wanted hash as `got:    sha256-<base64>`; older nix
      # printed `output: sha256-<hex64>`. Accept either — the base64 form is already
      # the value fetchPnpmDeps wants, so no hex->base64 step for it.
      got="$(grep -E '^[[:space:]]*got:' "$report_err" | head -1 | grep -oE 'sha256-[A-Za-z0-9+/]{43}=')"
      [ -n "$got" ] || got="$(hex="$(grep -oE 'output:[[:space:]]*sha256-[0-9a-f]{64}' "$report_err" | head -1 | grep -oE '[0-9a-f]{64}')"; [ -n "$hex" ] && printf 'sha256-%s' "$(python3 -c "import sys,base64; sys.stdout.write(base64.b64encode(bytes.fromhex('$hex')).decode())")")"
      [ -n "$got" ] || { echo "dsh-repin: dsh-tarball build failed and no hash was reported:" >&2; tail -25 "$report_err" >&2; exit 1; }
      sed -i -E "s|^( *)hash = .*$|\1hash = \"$got\";|" "$D/tarball.nix"
      echo "dsh-repin: fetchPnpmDeps hash -> $got"
      # Rebuild so the release tree is actually produced (also verifies).
      nix build --impure --no-link --print-out-paths .#packages.x86_64-linux.dsh-tarball > /dev/null
    else
      echo "dsh-repin: fetchPnpmDeps hash unchanged (empty? no — build passed)"
    fi
    echo
    echo "dsh-repin: dsh now at $ver ($newref @ ${newrev:0:12}) — run \`just switch\` to activate"

# The one LLM door: the availability gate on :8100 (llm.local). It answers what
# can be served, loads the model a request names, and silently redirects a call
# to a different model when one is already resident. Engine ports are private
# plumbing — go through here.
llm-gate-status:
    sudo systemctl status llm-gate.service --no-pager

llm-gate-logs:
    sudo journalctl -u llm-gate.service -f

# The whole fleet against current free VRAM: what is resident, what would fit.
llm-gate-state:
    curl -s http://127.0.0.1:8100/gate/state | jq .

# What can be served right now, and which of it is resident.
llm-models:
    curl -s http://127.0.0.1:8100/v1/models | jq -r '.data[] | [(.id|tostring), (.resident|tostring)] | @tsv'

# Release a model's VRAM now (the gate never stops an engine behind your back).
llm-unload model:
    curl -s -X POST http://127.0.0.1:8100/unload -H 'Content-Type: application/json' -d '{"model":"{{model}}"}' | jq .
