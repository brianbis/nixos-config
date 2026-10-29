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
        touch /tmp/ci-build-marker 2>/dev/null || true
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

# The blind tail of the build log is "building '...'" noise: the derivation
# that actually failed prints its own error ABOVE the last few lines, so a
# tail -8 (4 building + 4 error-block lines) hid the one thing that matters.
# Centre the excerpt on the LAST "error:" line instead.
excerpt() {
    python3 - "$1" <<'PY'
import sys
raw = open(sys.argv[1], errors="ignore").read()
i = raw.rfind("error:")
if i < 0:
    sys.stdout.write(raw[-4000:])
    raise SystemExit
sys.stdout.write(raw[max(0, i - 5000):min(len(raw), i + 4000)])
PY
}

propose_fix() {
    err_block=$(excerpt "$log")

    # Name the gate's own default model rather than leaving it to the gate's
    # pick: an unnamed request can be redirected to a weaker row, and a patch
    # author wants the coder. The id comes from the gate's /gate/state readout
    # (the ledger stays the only truth for what is servable) — never hardcoded.
    default_model=$(curl -s -m 30 "${gate%/v1/*}/gate/state" |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("default",""))' 2>/dev/null)

    ERR="$err_block" MODEL="$default_model" python3 - "$repo" "$patch_file" <<'PY'
import json, os, re, subprocess, sys

repo, patch_out = sys.argv[1:3]
err, model = os.environ.get("ERR", ""), os.environ.get("MODEL", "")
body = {"messages": [{"role": "user", "content":
    "NixOS flake repo at /etc/nixos (git, main). A build of the DESKTOP "
    "toplevel (.#nixosConfigurations.nixos.config.system.build.toplevel) failed "
    "on the CI box. The failing derivation's own error block:\n" + err +
    "\n\nEmit ONE minimal unified diff (git format, applies with git apply -p1 "
    "from /etc/nixos) that fixes the root cause in the FLAKE. Only modify "
    "existing tracked *.nix files (flake.nix, hosts/**, home/**, catalog/**). "
    "No new/removed files, no shell commands, no non-.nix paths. "
    "If the failure is environmental (network fetch, missing substitute, store "
    "state) and not flake content, reply NO_FIX. "
    "Wrap the diff in a ```diff fence. If no safe fix is visible, reply NO_FIX."
}], "temperature": 0, "max_tokens": 1500}
if model:
    body["model"] = model
json.dump(body, open("/tmp/gate-req.json", "w"))
PY
    curl -s -m 900 -H 'Content-Type: application/json' \
        --data "@/tmp/gate-req.json" "$gate" -o /tmp/gate-resp.json

    python3 - "$repo" "$patch_file" <<'PY'
import json, re, subprocess, sys
repo, patch_out = sys.argv[1:3]
try:
    resp = json.load(open("/tmp/gate-resp.json"))
except Exception as exc:
    sys.exit("gate reply unreadable: %s" % exc)
if "choices" not in resp:
    # The gate answers a refused request with an error envelope (502 upstream
    # unreachable / 503 no model in the fleet can serve) and relays an engine's
    # own error verbatim; both lack "choices". Printing the envelope says which.
    sys.exit("gate refused: %s" % json.dumps(resp)[:1500])
txt = resp["choices"][0]["message"]["content"]
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
    say "build FAILED; the failing derivation's own error block:"
    excerpt "$log" | sed 's/^/  /'
    say "last lines:"
    tail -8 "$log" | sed 's/^/  /'
    try=$((try + 1))
    if [ "$try" -gt "$tries" ]; then
        say "gave up after $tries tries — full error log at $log"
        exit 1
    fi
    say "asking the gate (llm.local :8100) for a minimal flake fix..."
    if propose_fix; then
        if apply_fix; then
            ship
        else
            say "fix rejected — next try asks again"
        fi
    else
        say "no usable patch this try — retrying (raw gate reply at /tmp/gate-resp.json, build log at $log)"
    fi
done
