#!/usr/bin/env bash
# ci-offload.sh — the desk-side offload loop for `just switch-remote`.
#
# Ship the committed tree to yzerd, build the DESKTOP toplevel there (its
# daemon, 8/8), and if that build FAILS, auto-debug: feed the error tail to
# the desktop's own llm.gate (llm.local :8100, the interactive coder model),
# apply the returned patch to the repo — ONLY if every touched path is an
# existing tracked *.nix file — commit it, re-ship, and rebuild. Up to 3
# tries. On success the closure comes back as two store imports and you run
# `just switch` yourself.
#
# This NEVER activates anything. It is the same discipline as the box-side
# ci-runner (hosts/yzerd/ci-runner.sh): gate, propose, re-gate, cap tries —
# here pointed at the DESK build because the repo truth lives on the desk.
#
# Env knobs: CI_HOST CI_KEY CI_TRIES (defaults match the justfile's).
set -uo pipefail

repo=/etc/nixos
host="${CI_HOST:-b@192.168.5.186}"
key="${CI_KEY:-$HOME/.ssh/id_ci}"
tries="${CI_TRIES:-3}"
gate="http://127.0.0.1:8100/v1/chat/completions"
log=/tmp/desk-build.log
patch_file=/tmp/ci-desk-patch.diff

say() { printf '%s\n' "$*"; }

if [ ! -f "$key" ]; then
    say "no ssh key at $key — generate one (ssh-keygen -f ~/.ssh/id_ci -N ''; ssh-copy-id ...)"
    say "or set CI_KEY. Password fallback would still work, but expect a prompt per leg."
fi

# HEAD must equal the desk tree: the box builds HEAD, the desk evaluates its
# working tree; a diff there silently wastes the whole offload (different
# flake self-hash => different drv).
dirty=$(git -C "$repo" status --porcelain)
if [ -n "$dirty" ]; then
    say "repo is dirty ($dirty ...) — run 'just save' FIRST: the box must build exactly"
    say "what the desk evaluates. Set CI_ALLOW_DIRTY=1 to override this guard."
    [ "${CI_ALLOW_DIRTY:-0}" = "1" ] || exit 1
fi

if ! ssh -i "$key" -o ConnectTimeout=10 "$host" 'true' 2>/dev/null; then
    say "cannot reach $host over $key — check the alias/key before anything else"
    exit 1
fi

ssh -i "$key" "$host" 'test -d /srv/ci-repo' >/dev/null 2>&1 || {
    say "first run: /srv/ci-repo does not exist yet — one sudo mkdir on the box"
    ssh -i "$key" "$host" 'sudo mkdir -p /srv/ci-repo && sudo chown -R b:b /srv/ci-repo'
}

ship() {
    git -C "$repo" archive --format=tar.gz HEAD |
        ssh -i "$key" "$host" 'tar -x -z -C /srv/ci-repo'
}

# git bootstrap on the box: the desktop's uv deps fetchGit at eval time and
# builtins.fetchGit shells out to git, which the box lacks until ci.nix lands.
build() {
    : > "$log"
    ssh -i "$key" "$host" '
        cd /srv/ci-repo
        rm -f /tmp/desk-gen
        G=$(NIX_CONFIG="experimental-features = nix-command flakes" \
            nix-build --no-link --expr "(import <nixpkgs> {}).git" 2>/dev/null | tail -1)
        PATH="$PATH:$G/bin" NIX_CONFIG="experimental-features = nix-command flakes" \
            nix build --impure --no-link --max-jobs 8 --cores 8 \
            --out-link /tmp/desk-gen \
            ".#nixosConfigurations.nixos.config.system.build.toplevel"
    ' >"$log" 2>&1
}

import_closure() {
    ssh -i "$key" "$host" 'P=$(readlink /tmp/desk-gen); nix-store --export $(nix-store -q --closure $P)' |
        nix-store --import
    ssh -i "$key" "$host" 'P=$(readlink /tmp/desk-gen); D=$(nix-store -q --deriver $P); nix-store --export $(nix-store -q --closure $D)' |
        nix-store --import
}

propose_fix() {
    python3 - "$log" "$repo" "$patch_file" <<'PY'
import json, re, subprocess, sys
log, repo, patch_out = sys.argv[1:4]
tail = open(log, errors="ignore").read()[-8000:]
body = {"messages": [{"role": "user", "content":
    "NixOS flake repo at /etc/nixos (git, main). A build of the DESKTOP "
    "toplevel (.#nixosConfigurations.nixos.config.system.build.toplevel) failed "
    "on the CI box. Log tail:\n" + tail +
    "\n\nEmit ONE minimal unified diff (git format, applies with git apply -p1 "
    "from /etc/nixos) that fixes the root cause in the FLAKE. Only modify "
    "existing tracked *.nix files (flake.nix, hosts/**, home/**, catalog/**). "
    "No new/removed files, no shell commands, no non-.nix paths. "
    "Wrap the diff in a ```diff fence. If no safe fix is visible, reply NO_FIX."
}]}
json.dump(body, open("/tmp/gate-req.json", "w"))
PY
    curl -s -m 900 -H 'Content-Type: application/json' \
        --data "@/tmp/gate-req.json" "$gate" -o /tmp/gate-resp.json

    python3 - "$repo" "$patch_file" <<'PY'
import json, re, subprocess, sys
repo, patch_out = sys.argv[1:3]
try:
    txt = json.load(open("/tmp/gate-resp.json"))["choices"][0]["message"]["content"]
except Exception as exc:
    sys.exit("GATE_FAIL: %s" % exc)
m = re.search(r"```diff\n(.*?)```", txt, re.S) or \
    re.search(r"(diff -u .*?)(?:\n```|$)", txt, re.S)
if not m:
    sys.exit("no diff in the model reply (likely NO_FIX)")
patch = m.group(1).rstrip() + "\n"
paths = set()
for ln in patch.splitlines():
    if ln.startswith(("+++ ", "--- ")):
        p = ln[4:].split("\t")[0]
        p = re.sub(r"^[ab]/", "", p)
        if p and p != "/dev/null":
            paths.add(p)
bad = [p for p in paths
       if not p.endswith(".nix") or p.startswith("/") or
       not (p == "flake.nix" or p.startswith(("hosts/", "home/", "catalog/")))]
if bad:
    sys.exit("refused paths: %s" % " ".join(sorted(bad)))
for p in paths:
    if subprocess.run(["git", "-C", repo, "ls-files", "--error-unmatch",
                       p], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL).returncode:
        sys.exit("%s is not a tracked file — refusing an LLM-authored new file" % p)
if not paths:
    sys.exit("empty patch")
open(patch_out, "w").write(patch)
PY
}

apply_fix() {
    if ! git -C "$repo" apply --check -p1 "$patch_file"; then
        say "patch does not apply cleanly — skipping; manual look at $patch_file"
        return 1
    fi
    git -C "$repo" apply -p1 "$patch_file"
    git -C "$repo" add -- '*.nix'
    git -C "$repo" commit -m "ci-fix (desk-build): auto-debug offload gate $try" >/dev/null
    say "patched+committed (try $try) — re-gating"
}

try=0
ship
while : ; do
    if build; then
        say "BOX BUILD OK — importing closures back to the desk (several GB over LAN)"
        import_closure
        say "done: run 'just switch' — the toplevel is already valid, activation is yours"
        exit 0
    fi
    say "build FAILED; last lines:"
    tail -8 "$log" | sed 's/^/  /'
    try=$((try + 1))
    if [ "$try" -gt "$tries" ]; then
        say "gave up after $tries tries — full error log at $log"
        exit 1
    fi
    say "asking the gate (llm.local :8100) for a minimal flake fix..."
    if propose_fix; then
        apply_fix || say "fix rejected — next try asks again"
    else
        say "no usable patch — stopping; inspect $log"
        exit 1
    fi
    ship
done
