#!/usr/bin/env bash
# ci — the yzerd CI/CD runner (the door and the loop are documented in
# README.md "CI box"; installed by ci.nix via pkgs.writeScriptBin, so
# the interpreter is store bash regardless of this first line).
#
# Run AS b (uid 1000) on the box: git ownership matches the checkout, and
# sudo (wheel, NOPASSWD) is used only to start the on-demand strata coder
# during fix. This script never runs an activation command — no
# nixos-rebuild, no switch, no launch. Deploying last-green is a human
# door (README): sudo $(readlink /var/lib/nixos-ci/last-green)/launch-sudo.
set -u

REPO="${CI_REPO:-/etc/nixos}"
STATE="${CI_STATE:-/var/lib/nixos-ci}"
SYSTEM="${CI_SYSTEM:-x86_64-linux}"
MAXJOBS="${CI_MAX_JOBS:-8}"
CORES="${CI_CORES:-8}"
GATE_PKGS="${CI_GATE_PKGS:-gpu-unlock-kmod-check}"
FIX_TRIES="${CI_FIX_TRIES:-3}"
PORT="${CI_STRATA_PORT:-18088}"
MODEL="${CI_MODEL:-qwen3.8-flash-next-coder-iq1_m}"
LOG="$STATE/gate.log"

say() { printf '%s %s\n' "$(date -u '+%F %T')" "$*" >&2; }
logline() { printf '%s %s %s\n' "$(date -u '+%F %T')" "$1" "$2" >> "$LOG"; }

# gate_run NAME CMD... — run one gate in the checkout, capture its output,
# log the verdict. Nonzero rc on failure; output tail echoed to stderr.
LAST_FAIL_OUT=""
gate_run() {
  local name="$1" out
  shift
  out="$STATE/out-$name.txt"
  if (cd "$REPO" && "$@") > "$out" 2>&1; then
    logline "gate/$name" PASS
    say "gate/$name PASS (out: $out)"
    return 0
  fi
  logline "gate/$name" FAIL
  say "gate/$name FAIL — output tail:"
  tail -n 20 "$out" >&2
  LAST_FAIL_OUT="$out"
  return 1
}

# Gate order is cheap -> expensive; first failure is what fix repairs.
# The eval gate prints the toplevel drv WITHOUT building it (eval only).
GATES="yz-eval desk-eval pkgs toplevel"

gate_yz_eval() {
  gate_run yz-eval nix eval --raw \
    ".#nixosConfigurations.yzerd.config.system.build.toplevel.drvPath"
}
# desktop eval is opt-in on the box: the root nixpkgs rev is a download the
# store may not have yet (first run pays it; see README).
gate_desk_eval() {
  if [ "${CI_DESK_EVAL:-0}" = 1 ]; then
    gate_run desk-eval nix eval --raw \
      ".#nixosConfigurations.nixos.config.system.build.toplevel.drvPath"
  else
    logline "gate/desk-eval" SKIPPED
    return 0
  fi
}
gate_pkgs() {
  local p rc=0
  for p in $GATE_PKGS; do
    gate_run "pkg-$p" nix build --no-link --max-jobs "$MAXJOBS" --cores "$CORES" \
      ".#packages.$SYSTEM.$p" || rc=1
  done
  return $rc
}
# The build gate doubles as the CD pointer: a SUCCESSFUL build writes
# last-green; a failed build leaves the profile untouched, so last-green is
# always a green toplevel.
gate_toplevel() {
  gate_run toplevel nix build --no-link --max-jobs "$MAXJOBS" --cores "$CORES" \
    --profile "$STATE/last-green" \
    ".#nixosConfigurations.yzerd.config.system.build.toplevel"
}

# run_gates: stop at first failure, remember it (FAIL_NAME / FAIL_OUT).
FAIL_NAME=""
FAIL_OUT=""
run_gates() {
  local g rc=0
  FAIL_NAME=""; FAIL_OUT=""
  for g in $GATES; do
    LAST_FAIL_OUT=""
    case $g in
      yz-eval)  gate_yz_eval ;;
      desk-eval) gate_desk_eval ;;
      pkgs)     gate_pkgs ;;
      toplevel) gate_toplevel ;;
    esac
    rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$FAIL_NAME" ]; then
      FAIL_NAME=$g
      FAIL_OUT="$LAST_FAIL_OUT"
    fi
  done
  if [ -n "$FAIL_NAME" ]; then return 1; fi
  return 0
}

# git helpers — always the checkout, never the ambient cwd.
gitc() { git -C "$REPO" "$@"; }
commit_tree() { # commit_tree MSG FILE... — the box identity, explicit paths
  local msg="$1" f
  shift
  for f in "$@"; do gitc add -- "$f" || return 1; done
  gitc commit -q -c user.name=ci-box -c user.email=ci@yzerd.local -m "$msg" -- "$@"
}

usage() {
  cat >&2 <<EOF
ci — yzerd CI/CD runner (see hosts/yzerd/README.md, section CI box)
  ci gate            run the gate set (eval -> narrow pkgs -> toplevel build,
                     which updates the last-green pointer on success)
  ci update [IN...] nix flake update on the checkout; re-gate; commit the lock
                     on green, restore flake.lock on red (input names optional)
  ci fix [gate-set]  on red: feed the failing gate output to the box's strata
                     coder (:18088), apply candidate *.nix file patches to the
                     checkout, re-gate, at most CI_FIX_TRIES times; commit on
                     green; on give-up roll every patch back and write
                     \$STATE/last-fail.md
  ci status          last-green target, recent gate log, checkout state
EOF
}

# strata coder: lifecycle daemon (no wantedBy, operator-started) — start it
# on demand for the loop; it idles itself afterwards.
ensure_strata() {
  local st
  st=$(systemctl is-active strata-coder-serve 2>/dev/null || true)
  if [ "$st" != active ]; then
    say "starting strata-coder-serve (sudo, on demand)"
    sudo systemctl start strata-coder-serve
    sleep 2
  fi
}

# ask_llm PROMPTFILE OUTFILE — one OpenAI-compatible call; response text
# (whatever the coder emitted) lands in OUTFILE.
ask_llm() {
  local p="$1" o="$2" req="$STATE/req.json" resp="$STATE/resp.json"
  jq -n --arg model "$MODEL" --rawfile p "$p" \
    '{model: $model, messages: [{role: "user", content: $p}],
     temperature: 0.1, max_tokens: 3048}' > "$req"
  curl -sS --max-time 1800 -H 'Content-Type: application/json' \
    --data-binary "@$req" "http://127.0.0.1:$PORT/v1/chat/completions" > "$resp"
  jq -r '.choices[0].message.content // empty' "$resp" > "$o" 2>/dev/null || true
}

# apply_patches RESPONSEFILE APPLIEDLISTFILE — the model answers with ONE
# JSON line {"patches":[{"file":"hosts/yzerd/foo.nix","content":"..."}]}.
# Every patch is validated before writing: a tracked-style relative *.nix
# path inside the checkout (never flake.lock), <= 4 files, each content
# <= 200000 bytes. Returns count applied.
apply_patches() {
  local resp="$1" list="$2" cand i n file ok
  cand="$STATE/patches.json"
  grep -m1 '^{' < "$resp" | head -1 > "$cand" || { say "no JSON line from model"; return 1; }
  if ! jq -e '.patches | (type=="array") and (length>0) and (length<=4)
             and all(.[]; (.file|type=="string") and (.content|type=="string"))' \
       < "$cand" >/dev/null 2>&1; then
    say "model reply is not a valid patch object"; return 1
  fi
  n=$(jq '.patches | length' < "$cand")
  i=0
  while [ "$i" -lt "$n" ]; do
    file=$(jq -r ".patches[$i].file" < "$cand")
    ok=1
    case $file in
      hosts/*|flake.nix) ;;   # repo-authored files only
      *) ok=0 ;;
    esac
    case $file in
      *.nix) ;; *) ok=0 ;;
    esac
    case $file in
      *..*) ok=0 ;;           # no traversal: no ".." anywhere in the path
      *flake.lock*) ok=0 ;;
    esac
    if [ $ok -eq 0 ]; then say "rejecting patch path $file"; return 1; fi
    if ! jq -r ".patches[$i].content" < "$cand" > "$STATE/patch-$i.nix" 2>/dev/null; then
      say "content decode failed: $file"; return 1
    fi
    if [ "$(wc -c < "$STATE/patch-$i.nix")" -gt 200000 ]; then
      say "patch content too large: $file"; return 1
    fi
    cp "$STATE/patch-$i.nix" "$REPO/$file" || { say "write failed: $file"; return 1; }
    printf '%s\n' "$file" >> "$list"
    i=$((i+1))
  done
  return 0
}

cmd_gate() {
  if run_gates; then say "GATE GREEN"; return 0; fi
  say "GATE RED at $FAIL_NAME"
  return 1
}

cmd_update() {
  say "ci update: nix flake update $( [ $# -gt 0 ] && printf '%s\n' "$*" || echo '(all)')"
  (cd "$REPO" && nix flake update "$@") 2>&1 | tail -5 >&2
  if run_gates; then
    if gitc diff --quiet -- flake.lock; then say "lock unchanged, nothing to commit"; return 0; fi
    if commit_tree "ci: flake update green $(date -u '+%F %T')" flake.lock; then say "ci update: lock committed green"; return 0; fi
    say "ci update: commit failed"; return 1
  fi
  say "ci update: RED — rolling back flake.lock"
  gitc checkout HEAD -- flake.lock 2>/dev/null || gitc restore -- flake.lock 2>/dev/null || true
  return 1
}

cmd_fix() {
  local i=1 applied="$STATE/applied.list" f
  : > "$applied"
  while :; do
    if run_gates; then
      if [ -s "$applied" ]; then
        # shellcheck disable=SC2046 # split on newpaths; allowlisted names, no spaces
        set -- $(sort -u "$applied")
        commit_tree "ci: gate green after $((i-1)) fix-try(s)" "$@" || { say "commit failed"; return 1; }
        say "ci fix: GREEN after $((i-1)) fixes ($MODEL)"
      else
        say "ci fix: already GREEN"
      fi
      return 0
    fi
    if [ $i -gt "$FIX_TRIES" ]; then break; fi
    say "try $i/$FIX_TRIES: failing gate $FAIL_NAME -> strata coder at :$PORT"
    ensure_strata
    {
      printf 'The NixOS flake at %s failed its CI gate on box yzerd.\n' "$REPO"
      printf 'Failing gate: %s\n' "$FAIL_NAME"
      printf 'Tail of its output:\n'
      tail -n 200 "$FAIL_OUT" 2>/dev/null
      printf 'Reply with EXACTLY ONE line of JSON, no markdown, no other text:\n'
      printf '{"patches":[{"file":"hosts/yzerd/foo.nix","content":"<complete new file content, newlines as \\n>"}]}\n'
      printf 'Only these paths may be patched (repo *.nix, never flake.lock):\n'
      (cd "$REPO" && find . -name "*.nix" -not -path "./.git/*" | head -80 | sed "s|^\./||")
    } > "$STATE/prompt-$i.txt"
    ask_llm "$STATE/prompt-$i.txt" "$STATE/response-$i.txt"
    if apply_patches "$STATE/response-$i.txt" "$applied"; then
      say "try $i: patches applied, re-gating"
    else
      say "try $i: no usable patch"
    fi
    i=$((i+1))
  done
  # give-up: roll everything back, write a human report
  while read -r f; do
    if [ -n "$f" ]; then gitc checkout HEAD -- "$f" 2>/dev/null; rm -f "$REPO/$f" 2>/dev/null; fi
  done < "$applied"
  {
    printf '# ci give-up report\n\n'
    printf '- gate: %s\n- model: %s (tries %s)\n- rolled back: %s\n' "$FAIL_NAME" "$MODEL" "$((FIX_TRIES))" "$(tr '\n' ' ' < "$applied")"
    printf '\n```\n'; tail -n 120 "$FAIL_OUT" 2>/dev/null; printf '\n```\n'
  } > "$STATE/last-fail.md"
  say "ci fix: GIVE-UP — see $STATE/last-fail.md; checkout rolled back"
  return 1
}

cmd_status() {
  say "last-green: $(readlink "$STATE/last-green" 2>/dev/null || echo none)"
  gitc log --oneline -5 2>/dev/null || say "checkout: no git history"
  gitc status --porcelain 2>/dev/null | head -10
  tail -n 20 "$LOG" 2>/dev/null || true
}

main() {
  if [ ! -w "$STATE" ]; then mkdir -p "$STATE" 2>/dev/null || true; fi
  case "${1:-help}" in
    gate)   shift; cmd_gate ;;
    update) shift; cmd_update "$@" ;;
    fix)    shift; cmd_fix "$@" ;;
    status) shift; cmd_status ;;
    *) usage; return 1 ;;
  esac
}
main "$@"
