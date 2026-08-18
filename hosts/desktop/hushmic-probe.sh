#!/usr/bin/env bash
# hushmic state probe: runs ON THE HOST (root), dumps mic-binding state into
# /var/lib/hushmic-probe/latest (atomically) so the jailed agent (which cannot
# see host PIDs or the user's PipeWire socket) can read it.
set -euo pipefail
out=/var/lib/crush-system/hushmic-probe
mkdir -p "$out"
{
  date -u +%FT%TZ
  echo "hushmic_pid: $(pgrep -x hushmic | tr '\n' ' ')"
  echo "pw_streams:"
  pw-dump 2>/dev/null | jq -r '.objects[] | select(.interface=="Stream") | "  \(.stream.direction) node=\(.stream.node.name // "none") client=\(.properties["application.name"] // "?")"' 2>/dev/null || echo "  (pw-dump failed)"
  echo "inputs:"
  pw-dump 2>/dev/null | jq -r '.objects[] | select(.interface=="Input") | "  name=\(.name // "?") client=\(.properties["application.name"] // "?")"' 2>/dev/null || true
  echo "cpu0_governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo none)"
  echo "cpu0_epp: $(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo none)"
} > "$out/latest.tmp"
mv -f "$out/latest.tmp" "$out/latest"