#!/bin/bash
# Run ON THE BOX: `just ci-progress` ssh-streams this file and runs it there.
# Honest progress for a NixOS toplevel build: BFS the toplevel derivation's
# inputDrvs graph over the drvs that are STILL PENDING — valid subtrees are
# not expanded, so `pending` is exactly the work left and `% done` compares
# valid subtrees against the whole remaining graph.
# No jq/python on the box: greps the .drv/.fd file text directly (both
# dialects: the output path is the first /nix/store path in the file; the
# input drvs are every /nix/store/*.drv|*.fd occurrence).
set -uo pipefail

drvpat=${DRV_PAT:-*nixos-system-nixos-*.dr*}
D=$(ls -t /nix/store/$drvpat 2>/dev/null | head -1)
chrootcount() {
    find /nix/store -maxdepth 1 \( -name '*.drv.chroot' -o -name '*.fd.chroot' \) 2>/dev/null | wc -l
}
if [ ! -e "$D" ]; then
    echo "top-level drv not instantiated yet (still evaluating the flake)"
    echo "chroots=$(chrootcount)"
    exit 0
fi

outpath() { grep -m1 -o '/nix/store/[a-z0-9]\{32,\}-[a-z0-9._+-]*' "$1" 2>/dev/null | head -1; }
ins() { grep -o '/nix/store/[a-z0-9]\{32,\}-[a-z0-9._+-]*\.dr[a-z]*' "$1" 2>/dev/null | sort -u; }

OUT=$(outpath "$D")
if [ -n "$OUT" ] && [ -e "$OUT" ]; then
    echo "TOPLEVEL IS VALID — the build finished; run: just switch"
    echo "outlink=$(readlink /tmp/desk-gen 2>/dev/null || echo none)"
    echo "chroots=$(chrootcount)"
    exit 0
fi

# File-backed BFS: store paths never contain spaces, so line files are the queue.
: > /tmp/ci-seen.txt; printf '%s\n' "$D" > /tmp/ci-seen.txt
: > /tmp/ci-q.txt; printf '%s\n' "$D" > /tmp/ci-q.txt
TOTAL=0 DONE=0 DEPTH=0
while [ -s /tmp/ci-q.txt ] && [ "$DEPTH" -lt 40 ] && [ "$TOTAL" -lt 200000 ]; do
    : > /tmp/ci-next.txt
    while read -r d; do
        TOTAL=$((TOTAL + 1))
        o=$(outpath "$d")
        if [ -n "$o" ] && [ -e "$o" ]; then
            DONE=$((DONE + 1))
        else
            ins "$d" >> /tmp/ci-next.txt
        fi
        [ "$TOTAL" -ge 30000 ] && break
    done < /tmp/ci-q.txt
    sort -u /tmp/ci-next.txt > /tmp/ci-n2.txt
    sort -u /tmp/ci-seen.txt > /tmp/ci-seen2.txt
    mv /tmp/ci-seen2.txt /tmp/ci-seen.txt
    comm -23 /tmp/ci-n2.txt /tmp/ci-seen.txt > /tmp/ci-new.txt
    mv /tmp/ci-new.txt /tmp/ci-q.txt
    DEPTH=$((DEPTH + 1))
    [ "$TOTAL" -ge 30000 ] && break
done

pend=$((TOTAL - DONE))
tot=$((TOTAL > 0 ? TOTAL : 1))
pct=$((DONE * 100 / tot))
echo "drv-graph: seen=$TOTAL done=$DONE pending=$pend ($pct% done, depth=$DEPTH)"
echo "toplevel-out=$OUT"
echo "chroots=$(chrootcount)"
M=/tmp/ci-build-marker
if [ -e "$M" ]; then
    echo "fetch-locks-since-build-start=$(find /nix/store -maxdepth 1 -name '*.lock' -newer "$M" 2>/dev/null | wc -l)"
    echo "store-paths-since-build-start=$(find /nix/store -maxdepth 1 -type d -newer "$M" 2>/dev/null | wc -l)"
fi
