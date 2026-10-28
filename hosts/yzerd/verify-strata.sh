#!/usr/bin/env bash
# verify-strata.sh — readout gate for the Strata coder stack on yzerd.
# Run ON THE BOX (sudo for the journal and the /var/lib/strata reads).
# Every line prints a measured number; exit 1 on the first hard failure.
# Nothing here starts a model: it reads what is already staged/resident.

set -uo pipefail

PORT=18088
MODEL_ID=qwen3.8-flash-next-coder-iq1_m
REPO_DIR=/var/lib/strata/models
CODER=coder-IQ1_M
S1=$REPO_DIR/$CODER/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00001-of-00002.gguf
S2=$REPO_DIR/$CODER/Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-00002-of-00002.gguf
MM=$REPO_DIR/mmproj-Qwen3.8-Flash-Next-BF16.gguf
REV_FILE=$REPO_DIR.revision-coder
EXPECT_REV=5348543e0147355ac9cbcb031184a3546350988e
EXPECT_S1=29608446496
EXPECT_S2=28800138432
EXPECT_MM=907543008
# LFS oids (hf embeds them in its cache names); --sha recomputes them on disk.
OID_S1=e11083ba855e7666b48ea3f2db6a9c3a20c18751a012cc24f948de91b7087fad
OID_S2=316b46f3a2dbd68c900f43136ab9449f9dcc3725dfd8c794847c204bc161e113
OID_MM=b1a82259702816a5330d7bd7607cd9676b11780e79ff7348c21103ff3ce49bd0

fail=0
note() { printf '%-34s %s\n' "$1" "$2"; }
chk() { if [ "$2" != "$3" ]; then note "FAIL $1" "want=$3 got=$2"; fail=1; else note "$1" "$2"; fi; }

note 'current system' "$(readlink /run/current-system)"
chk 'revision stamp' "$(cat "$REV_FILE" 2>/dev/null)" "$EXPECT_REV"
chk 'shard1 bytes' "$(stat -c %s "$S1" 2>/dev/null || echo 0)" "$EXPECT_S1"
chk 'shard2 bytes' "$(stat -c %s "$S2" 2>/dev/null || echo 0)" "$EXPECT_S2"
chk 'mmproj bytes' "$(stat -c %s "$MM" 2>/dev/null || echo 0)" "$EXPECT_MM"
# setup.py's own completion marks: without them its step 5 re-downloads.
for f in "$S1.done" "$S2.done"; do
  [ -f "$f" ] && note "mark $(basename "$f")" present || { note "mark $(basename "$f")" MISSING; fail=1; }
done
[ -d "$REPO_DIR/IQ1_M" ] && { note 'stray IQ1_M/' present; fail=1; } || note 'stray IQ1_M/' absent

# --sha re-reads 59 GB (about a minute on the NVMe); the size gate above is
# what the stage service itself tests, the oids are the integrity gate.
if [ "${1:-}" = "--sha" ]; then
  for f in "$S1" "$S2" "$MM"; do
    [ -f "$f" ] || continue
    want=$OID_S1; [ "$f" = "$S2" ] && want=$OID_S2; [ "$f" = "$MM" ] && want=$OID_MM
    chk "sha256 $(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)" "$want"
  done
else
  note 'sha256' 'pass --sha to re-read the 59 GB against the LFS oids'
fi

note 'engine BUILD.json' "$(cat "$(ls -d /nix/store/*-strata-engine-0.1.30 2>/dev/null | tail -1)/app/engine/BUILD.json" 2>/dev/null)"
note 'gpu' "$(nvidia-smi -L 2>/dev/null | head -1)"
note 'unit: serve' "$(systemctl is-active strata-coder-serve)"
note 'unit: stage' "$(systemctl is-active strata-coder-stage)"
note 'unit: prep' "$(systemctl is-active strata-prep.target)"

curl -sS -m 10 -o /tmp/strata-health.json -w 'health http=%{http_code} t=%{time_total}s\n' \
  "http://127.0.0.1:$PORT/health" || fail=1
if grep -q '"loaded": *true' /tmp/strata-health.json 2>/dev/null; then note 'health loaded' true; else note 'health loaded' 'not loaded'; fail=1; fi
curl -sS -m 10 "http://127.0.0.1:$PORT/v1/models" -o /dev/null -w 'models http=%{http_code}\n' || fail=1
curl -sS -m 240 "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
  -d '{"model":"coder","messages":[{"role":"user","content":"Reply with exactly: ok"}],"max_tokens":64,"temperature":0}' \
  -o /tmp/strata-reply.json -w 'completion http=%{http_code} t=%{time_total}s\n' || fail=1
if grep -q "$MODEL_ID" /tmp/strata-reply.json 2>/dev/null; then note 'reply model' "$MODEL_ID"; else note 'reply model' 'model id absent'; fail=1; fi
# the box has no jq; grep the timings field straight out of the reply body.
grep -o '"predicted_per_second": *[0-9.]*' /tmp/strata-reply.json 2>/dev/null \
  | sed 's/.*: *//;s/^/tok\/s: /'
note 'disk used' "$(du -sh "$REPO_DIR" | tail -1 | cut -f1)"
note 'gpu vram used' "$(nvidia-smi | sed -n '10p' | grep -o '[0-9]*MiB /  *[0-9]*MiB')"
exit "$fail"
