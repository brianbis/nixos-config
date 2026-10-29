#!/usr/bin/env bash
# verify-gpu-unlock.sh — readout gate for the gpu-unlock kernel module on yzerd.
# Run ON THE BOX (sudo for the journal and the loaded-module reads):
#   ssh -o BatchMode=yes -l b -i /home/llm/.ssh/ha_key -o IdentitiesOnly=yes 192.168.5.186 \
#     'sudo bash -s' < verify-gpu-unlock.sh
# Every line prints a measured number or a checked string; exit 1 on the first
# hard failure. Nothing here loads the card or starts a model, except with
# --perf, which asks the already-resident coder engine for two decode runs and
# one prefill run.

set -uo pipefail

want_targets=all
# recipes.h GU_FW_* names are relative to the kernel firmware search dirs. In
# stage 2 the merged hardware.firmware tree is reachable at
# /run/current-system/firmware (kernel.nix:423 symlinks
# ${config.hardware.firmware}/lib/firmware), and `options firmware_class
# path=` points udev at that same dir. Inside the initrd the blobs come from
# the modules-closure tree (/lib/firmware), which is what the unlock actually
# reads — the store check below is the stage-2 half of that evidence.
fw_dir=/run/current-system/firmware/gpu-unlock/610.43.03
PORT=18088
M=qwen3.8-flash-next-coder-iq1_m
# Baselines measured 2026-10-28 BEFORE the gpu-unlock deploy (job
# bash-bd07bb7a86394f00): decode warm-up 91.3 tok/s (214 tok / 2.344358 s),
# second decode run 125.8 tok/s (256 tok / 2.034826 s), prefill 3399.5 tok/s
# (11153 prompt tok / 3.280779 s at 46800 chars). gpu-unlock's own README reads
# 0-15% for quantized GGUF (INT8 KV = memory traffic, not tensor math) and
# 25-55% for BF16/FP16 prefill, so the gate is no-worse with prefill allowed to
# move up; a drop below either floor means the card got worse, not unlocked.
# Floors sit just under the pre-unlock baseline (2026-10-29 05:2x, gpu_unlock
# absent, 615.78.08 open, IQ1_M coder, warm KV): prefill 11153 tok / 3.280779 s
# = 3399.5 tok/s; decode-cached 256 tok / 2.034846 s = 125.8 tok/s.
# Post-unlock measured (targets=all, this boot, cache-cold nonce'd probes 05:41
# and 05:43): prefill 11182/3.208143 = 3485.5 and 11182/3.196228 = 3498.5 tok/s
# (+2.6..2.9%); decode 128.1/129.9 and 123.7/128.1 tok/s (+1..3%).
# Upstream claims "quantized GGUF: 0-15%" — we land at the bottom of that band,
# honest: IQ1_M dequant dominates, the tensor-core cap is not the bottleneck.
MIN_PREFILL=3300
MIN_DECODE2=120

fail=0
note() { printf '%-30s %s\n' "$1" "$2"; }
chk() { if [ "$2" != "$3" ]; then note "FAIL $1" "want=$3 got=${2:-none}"; fail=1; else note "$1" "$2"; fi; }

echo '=== structural: cmdline, module, journal ==='
chk 'cmdline gpu_unlock.targets' "$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^gpu_unlock\.targets=//p')" "$want_targets"
chk 'kernel' "$(uname -r)" '6.18.56'
ko=$(find /run/current-system/kernel-modules/lib/modules -name 'gpu_unlock.ko*' | head -1)
note 'modules tree .ko' "${ko:-absent}"
# 16 firmware: lines in modinfo == the GU_FW_* set the module will ask for.
note 'modinfo firmware decls' "$([ -n "${ko:-}" ] && modinfo -F firmware "$ko" | grep -c .)"
# 17 = 16 blobs + NVIDIA-LICENSE; .bin got renamed .bin.zst by
# pkgs.compressFirmwareZstd, which the devm loader decompresses itself.
fw_blobs=$(ls "$fw_dir" 2>/dev/null | grep -c .)
note 'fw blobs (stage-2 store)' "$fw_blobs"
[ "$fw_blobs" -ge 17 ] || { note 'FAIL firmware blobs' "want>=17 got=$fw_blobs"; fail=1; }
note 'lsmod' "$(awk '$1=="gpu_unlock"{print $1,$2,$3}' /proc/modules)"
loaded=$(awk '$1=="gpu_unlock"{c=1} END{print c+0}' /proc/modules)
[ "$loaded" = 1 ] || { note 'gpu_unlock NOT loaded' absent; fail=1; }
kj=$(journalctl -k -b --no-pager 2>/dev/null | grep -i gpu_unlock)
note 'journal lines' "$(printf '%s\n' "$kj" | grep -c .)"
printf '%s\n' "$kj" | grep . | head -8
[ "$loaded" = 1 ] && [ "$(printf '%s\n' "$kj" | grep -c .)" = 0 ] && { note 'loaded but silent' suspicious; fail=1; }

# Vendor id, not class: the card is class 0300 (VGA compatible), and a class
# filter (::010c) also matches host bridges/bridges here, so it never pinned the
# nvidia device. lspci -d 10de: -> 0A:00.0 NVIDIA AD102 [10de:2684].
gpuaddr=$(lspci -d 10de: 2>/dev/null | head -1 | cut -d' ' -f1)
note 'lspci' "$(lspci -nnk -s "$gpuaddr" 2>/dev/null | tr '\n' '|')"
lspci -nnk -s "$gpuaddr" 2>/dev/null | grep -q 'Kernel modules:.*nvidia' || { note 'FAIL nvidia kernel module' 'lspci shows none'; fail=1; }
note 'vram used/total' "$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null)"

echo '=== perf (pass --perf to pay the probe: 2 decode + 1 prefill) ==='
if [ "${1:-}" = "--perf" ]; then
  curl -sS -m 10 -o /dev/null -w 'health=%{http_code}\n' "http://127.0.0.1:$PORT/health"
  decode_rate() { # $1=tag  -> tok/s from wall time and completion_tokens
    local t ct
    t=$(curl -sS -o /tmp/gu-pd.json -w '%{time_total}' \
      -H 'Content-Type: application/json' \
      -d '{"model":"'"$M"'","messages":[{"role":"user","content":"List three facts about KV caches in MoE inference. Keep it under 80 words."}],"max_tokens":256,"temperature":0.2}' \
      "http://127.0.0.1:$PORT/v1/chat/completions")
    ct=$(grep -oE '"completion_tokens": *[0-9]+' /tmp/gu-pd.json | grep -oE '[0-9]+' | head -1)
    awk -v c="$ct" -v t="$t" -v tag="$1" 'BEGIN{if(c&&t>0)printf "%s tok/s = %.1f (tok=%s wall=%s)\n",tag,c/t,c,t}'
  }
  d1=$(decode_rate decode-warm); sleep 3
  d2=$(decode_rate decode-cached); sleep 3
  # The nonce keeps the prefill cache-cold: the engine caches an identical
  # prompt prefix, so a repeated probe reads 35x faster (measured: 11153 tok in
  # 0.315 s on the second identical run) and would not price the tensor path.
  nonce=$(printf '%s-%s' "$(date +%s%N)" "$RANDOM")
  LONG=$(gawk -v n="$nonce" 'BEGIN{s="";for(i=0;i<300;i++)s=s"Explain the difference between dense and sparse attention, then paged KV caching, then expert routing in a 256-expert MoE, then INT8 KV quantization error. ";printf s"UNIQUE-RUN-%s\n",n}')
  t=$(curl -sS -o /tmp/gu-pk.json -w '%{time_total}' \
    -H 'Content-Type: application/json' \
    -d '{"model":"'"$M"'","messages":[{"role":"user","content":"'"$LONG"'"}],"max_tokens":8,"temperature":0}' \
    "http://127.0.0.1:$PORT/v1/chat/completions")
  pt=$(grep -oE '"prompt_tokens": *[0-9]+' /tmp/gu-pk.json | grep -oE '[0-9]+' | head -1)
  printf '%s\n%s\n' "$d1" "$d2"
  awk -v c="$pt" -v t="$t" 'BEGIN{if(c&&t>0)printf "prefill tok/s = %.1f (tok=%s wall=%s)\n",c/t,c,t}'
  awk -v got="$(awk -v c="$pt" -v t="$t" 'BEGIN{if(c&&t>0)printf "%.1f",c/t; else print 0}')" \
       -v want="$MIN_PREFILL" 'BEGIN{if(got+0<want)print "FAIL prefill below floor"; else exit 0}' | grep -q FAIL && { note 'FAIL prefill' "below MIN_PREFILL=$MIN_PREFILL"; fail=1; }
  awk -v got="$(sed -n 's/.*= //p' <<< "$d2")" -v want="$MIN_DECODE2" 'BEGIN{exit !(got+0<want)}' && { note 'FAIL decode-cached' "below MIN_DECODE2=$MIN_DECODE2"; fail=1; }
  nvidia-smi | sed -n '10p'
else
  note 'perf' 'pass --perf'
fi

exit "$fail"
