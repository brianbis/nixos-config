#!/usr/bin/env bash
# hushmic state probe: runs ON THE HOST (root), dumps mic-binding state into
# /var/log/hushmic/latest (atomically) so the jailed agent (which cannot
# see host PIDs or the user's PipeWire socket) can read it.
set -euo pipefail
out=/var/log/hushmic
mkdir -p "$out"
# Same predicate the steam-game-watcher uses; run with -l to list WHICH
# cmdlines match. Pattern via file so no transient scanner argv ever carries
# it (which is what made find-based scans self-match).
steam_pattern='steamapps/common/|steamapps/compatdata/|compatdata/[0-9]+/.*\.(exe|EXE)|wine(64|32)'
printf '%s\n' "$steam_pattern" > "$out/steam-pattern.tmp"
mv -f "$out/steam-pattern.tmp" "$out/steam-pattern"
{
  date -u +%FT%TZ
  echo "hushmic_pid: $(pgrep -af 'bin/\.hushmic-wrapped' 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  echo "hushmic_proc: $(pgrep -af hushmic 2>/dev/null | grep -vE 'hushmic-probe|hushmic-core-pin|hushmic-audio-cores|steam-game-watcher|pgrep' | tr '\n' '|')"
  echo "watchers: $(ps -eo pid,etime,comm,args 2>/dev/null | grep -E 'steam-game-watcher|hushmic-core-pin' | grep -v grep | tr '\n' '|')"
  echo "steam_match: $(find /proc -maxdepth 2 -type f -name cmdline -exec grep -lzE -f "$out/steam-pattern" {} + 2>/dev/null | tr '\n' ' ')"
  echo "unit_state: cores=$(systemctl is-active hushmic-audio-cores 2>/dev/null) pin=$(systemctl is-active hushmic-core-pin 2>/dev/null) probe=$(systemctl is-active hushmic-probe 2>/dev/null) steam=$(systemctl is-active steam-gaming-mode 2>/dev/null) user_hushmic=$(sudo -u b systemctl --user is-active hushmic 2>/dev/null || echo n/a)"
  echo "journal: $(journalctl --no-pager -n 200 -u hushmic-audio-cores -u hushmic-core-pin -u hushmic-probe -u steam-gaming-mode 2>/dev/null | grep -E 'Started|Stopped|Deactivated|Activating|Main process' | tail -3 | tr '\n' '|')"
  echo "suspects: $(ps -eo pid,etime,comm,args 2>/dev/null | grep -iE 'gamemode|thermald|power-profiles|powertop|tlp|powerclamp|cpufreq' | grep -v grep | tr '\n' '|')"
  # --- audio RT scheduling + load evidence ---
  uid=$(stat -c %u /home/b 2>/dev/null || echo 1000)
  echo "sched: $(for p in $(pgrep -f 'hushmic-wrapped|filter-chain|pipewire' 2>/dev/null | sort -u); do printf '[%s]pol=%s rtlim=%s cpu=%s ' "$p" "$(awk '/^Sched:/{print $2}' /proc/$p/status 2>/dev/null)" "$(awk '/Max real-time priority/{print $4}' /proc/$p/limits 2>/dev/null)" "$(taskset -cp "$p" 2>/dev/null | awk -F: '{print $2}')"; done)"
  echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg) cpumhz: $(grep -m1 'cpu MHz' /proc/cpuinfo | awk '{print $4}')"
  echo "filter_cfg: $(md5sum /home/b/.config/hushmic/filter-chain.conf 2>/dev/null | cut -c1-8) $(head -c 400 /home/b/.config/hushmic/filter-chain.conf 2>/dev/null | tr '\n' '|')"
  export PULSE_SERVER="unix:/run/user/$uid/pipewire-0"
  echo "pw_session: $(pw-dump 2>/dev/null | jq -r '[.objects[] | select(.interface=="Stream") | "\(.stream.direction):\(.properties["application.name"] // "?")"] | join(",")' 2>/dev/null || echo failed)"
  echo "rtkit: $(systemctl is-active rtkit-daemon 2>/dev/null)"
  echo "pw_streams:"
  pw-dump 2>/dev/null | jq -r '.objects[] | select(.interface=="Stream") | "  \(.stream.direction) node=\(.stream.node.name // "none") client=\(.properties["application.name"] // "?")"' 2>/dev/null || echo "  (pw-dump failed)"
  echo "inputs:"
  pw-dump 2>/dev/null | jq -r '.objects[] | select(.interface=="Input") | "  name=\(.name // "?") client=\(.properties["application.name"] // "?")"' 2>/dev/null || true
  echo "cpu6_governor: $(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_governor 2>/dev/null || echo none)"
  echo "cpu6_epp: $(cat /sys/devices/system/cpu/cpu6/cpufreq/energy_performance_preference 2>/dev/null || echo none)"
  echo "cpu7_governor: $(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_governor 2>/dev/null || echo none)"
  echo "cpu7_epp: $(cat /sys/devices/system/cpu/cpu7/cpufreq/energy_performance_preference 2>/dev/null || echo none)"
  echo "governors: $(grep -h . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' \n' ' ')"
} > "$out/latest.tmp"
mv -f "$out/latest.tmp" "$out/latest"