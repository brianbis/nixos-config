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

# NixOS build & rebuild
switch:
    just auto-stage
    sudo nixos-rebuild switch --flake . {{build-flags}}
    @sudo nix build --no-link .#agents-md --print-out-paths | xargs -I{} sudo cp {} AGENTS.md

build:
    just auto-stage
    sudo nixos-rebuild build --flake . {{build-flags}}

check:
    nixos-rebuild dry-build --flake .

diff:
    nix store diff-closures /nix/var/nix/profiles/system ./result

update:
    # Runs as llm: the flake repo is owned by the llm agent user (see
    # hosts/desktop/host.nix), so flake.lock must be written by llm.
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

gc:
    sudo nix-collect-garbage -d

generations:
    sudo nix-env --list-generations --profile /nix/var/nix/profiles/system

rollback:
    sudo nixos-rebuild switch --rollback --flake . {{build-flags}}

# vLLM docker containers (the Gemma + K2-Horizon checkpoints). The Qwen3.8
# DFlash2 engine is now a NATIVE process (see vllm-dflash2-* below), not a
# container. Only ever run ONE at a time: they fight over VRAM.

vllm-containers := "docker-vllm-gemma4-nvfp4-turbo docker-vllm-gemma4-awq docker-vllm-k2horizon-nvfp4 docker-vllm-lensvlm"

# Start commands

vllm-gemma4-nvfp4-turbo:
    sudo systemctl start docker-vllm-gemma4-nvfp4-turbo.service

vllm-gemma4-awq:
    sudo systemctl start docker-vllm-gemma4-awq.service

vllm-k2horizon-nvfp4:
    sudo systemctl start docker-vllm-k2horizon-nvfp4.service

vllm-lensvlm:
    sudo systemctl start docker-vllm-lensvlm.service

# Qwen3.8 DFlash2 NATIVE engine (socket-activated on :18089, no docker). Like
# the SGLang engine it is on-demand: a request to http://127.0.0.1:18089 starts
# it, and it unloads after the idle window. The child listens on :18090 while
# resident. These recipes inspect / stop the socket-activated unit.
vllm-dflash2-status:
    sudo systemctl status vllm-qwen38-dflash2.service vllm-qwen38-dflash2.socket --no-pager

vllm-dflash2-stop:
    sudo systemctl stop vllm-qwen38-dflash2.service

# Keep the old name as a no-op alias so muscle memory / docs don't break: the
# DFlash2 engine is no longer a manually-started docker container.
vllm-qwen38-dflash2:
    @echo "The DFlash2 engine is now a native, socket-activated process (no docker)."
    @echo "It starts on the first request to http://127.0.0.1:18089 and unloads when idle."
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

# SGLang native engine (Qwen3.8-27B NVFP4, socket-activated on :8086, no
# docker). Like the NInfer engines it is on-demand: a request to
# http://127.0.0.1:8086 starts it, and it unloads after the idle window.
# These recipes inspect / stop the socket-activated unit.
sglang-status:
    sudo systemctl status sglang-serve.service sglang-serve.socket --no-pager

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
    if [ "$curref" = "$newref" ] && [ "$currev" = "$tagrev" ]; then
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
    # node (npm) + python3 come from nix shell (not on the default PATH);
    # update-deps.py is stdlib-only.
    nix shell nixpkgs#nodejs nixpkgs#python3 -c \
      python3 "$D/update-deps.py" "$src" "$newrev"

    # --- 3. fetchPnpmDeps store pin (the hash in tarball.nix) -----------------
    sed -i -E 's/^( *)hash = .*$/\1hash = "";/' "$D/tarball.nix"
    report.err="$(mktemp)"
    if ! nix build --impure --no-link --print-out-paths .#packages.x86_64-linux.dsh-tarball > /dev/null 2>"$report.err"; then
      got="$(grep -oE 'output:[[:space:]]*sha256-[0-9a-f]{64}' "$report.err" | head -1 | grep -oE '[0-9a-f]{64}')"
      [ -n "$got" ] || { echo "dsh-repin: dsh-tarball build failed and no hash was reported:" >&2; tail -25 "$report.err" >&2; exit 1; }
      b64="$(python3 -c "import sys,base64; sys.stdout.write(base64.b64encode(bytes.fromhex('$got')).decode())")"
      sed -i -E "s/^( *)hash = \"\".*/\1hash = \"sha256-$b64\";/" "$D/tarball.nix"
      echo "dsh-repin: fetchPnpmDeps hash -> sha256-$b64"
      # Rebuild so the release tree is actually produced (also verifies).
      nix build --impure --no-link --print-out-paths .#packages.x86_64-linux.dsh-tarball > /dev/null
    else
      echo "dsh-repin: fetchPnpmDeps hash unchanged (empty? no — build passed)"
    fi
    echo
    echo "dsh-repin: dsh now at $ver ($newref @ ${newrev:0:12}) — run \`just switch\` to activate"

# llama.cpp shortcuts

llamacpp-start:
    sudo systemctl start llamacpp-muse.service

llamacpp-stop:
    sudo systemctl stop llamacpp-muse.service

llamacpp-restart:
    sudo systemctl restart llamacpp-muse.service

llamacpp-status:
    sudo systemctl status llamacpp-muse.service --no-pager

llamacpp-logs:
    sudo journalctl -u llamacpp-muse.service -f

llamacpp-health:
    curl -s http://127.0.0.1:8000/health || echo "llama.cpp not responding"

llamacpp-load-muse:
    curl -s -X POST http://127.0.0.1:8000/load -H 'Content-Type: application/json' -d '{"model":"/var/lib/llama/models/muse-glimmer-30B/muse-glimmer-30B-kquant-dynamic.gguf"}' || echo "load failed"

llamacpp-load-qwen:
    curl -s -X POST http://127.0.0.1:8000/load -H 'Content-Type: application/json' -d '{"model":"/var/lib/llama/models/Qwen3.8-27B-Q8_0.gguf"}' || echo "load failed"

llamacpp-models:
    ls -lh /var/lib/llama/models

llamacpp-psi:
    sudo systemctl is-active --quiet llamacpp-muse.service && echo "running" || echo "stopped"

# Short aliases
alias lc-start := llamacpp-start
alias lc-stop := llamacpp-stop
alias lc-status := llamacpp-status
