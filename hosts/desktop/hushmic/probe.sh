#!/usr/bin/env bash
# hushmic state probe: runs ON THE HOST (root), dumps mic-binding state into
# /var/log/hushmic/latest (atomically) so the jailed agent (which cannot
# see host PIDs or the user's PipeWire socket) can read it.
set -euo pipefail
out="${LOGS_DIRECTORY:-/var/log/hushmic}"
mkdir -p "$out"
# Same predicate the steam-game-watcher uses; run with -l to list WHICH
# cmdlines match. Pattern via file so no transient scanner argv ever carries
# it (which is what made find-based scans self-match).
steam_pattern='steamapps/common/|steamapps/compatdata/|compatdata/[0-9]+/.*\.(exe|EXE)|wine(64|32)'
printf '%s\n' "$steam_pattern" > "$out/steam-pattern.tmp"
mv -f "$out/steam-pattern.tmp" "$out/steam-pattern"
{
  date -u +%FT%TZ
  uid=$(stat -c %u /home/b 2>/dev/null || echo 1000)
  echo "hushmic_pid: $(pgrep -af 'bin/hushmic' 2>/dev/null | grep -vE 'hushmic-probe|hushmic-core-pin|hushmic-audio-cores|steam-game-watcher|probe\.sh|pgrep' | awk '{print $1}' | tr '\n' ' ')"
  echo "hushmic_proc: $(pgrep -af 'bin/hushmic' 2>/dev/null | grep -vE 'hushmic-probe|hushmic-core-pin|hushmic-audio-cores|steam-game-watcher|probe\.sh|pgrep' | tr '\n' '|')"
  echo "watchers: $(ps -eo pid,etime,comm,args 2>/dev/null | grep -E 'steam-game-watcher|hushmic-core-pin' | grep -v grep | tr '\n' '|')"
  echo "steam_match: $(find /proc -maxdepth 2 -type f -name cmdline -exec grep -lzE -f "$out/steam-pattern" {} + 2>/dev/null | tr '\n' ' ')"
  # user_hushmic: --machine=user@UID is more reliable than sudo+XDG_RUNTIME_DIR
  # because it talks directly to the user manager over its private socket, no
  # env-var juggling through sudo needed. Falls back to "n/a" if the user
  # manager isn't running or the unit isn't loaded.
  user_hushmic=$(systemctl --machine=user@$uid is-active hushmic.service 2>/dev/null || echo n/a)
  echo "unit_state: cores=$(systemctl is-active hushmic-audio-cores 2>/dev/null) pin=$(systemctl is-active hushmic-core-pin 2>/dev/null) probe=$(systemctl is-active hushmic-probe 2>/dev/null) steam=$(systemctl is-active steam-gaming-mode 2>/dev/null) user_hushmic=$user_hushmic linger=$(loginctl show-user b -p Linger 2>/dev/null | cut -d= -f2) user_mgr=$(systemctl is-active user@${uid}.service 2>/dev/null)"
  echo "journal: $(journalctl --no-pager -n 200 -u hushmic-audio-cores -u hushmic-core-pin -u hushmic-probe -u steam-gaming-mode 2>/dev/null | grep -E 'Started|Stopped|Deactivated|Activating|Main process' | tail -3 | tr '\n' '|')"
  echo "suspects: $(ps -eo pid,etime,comm,args 2>/dev/null | grep -iE 'gamemode|thermald|power-profiles|powertop|tlp|powerclamp|cpufreq' | grep -v grep | tr '\n' '|')"
  # --- audio RT scheduling + load evidence ---
  # Sched: (policy/rtprio) is NOT in /proc/PID/status on this kernel; the
  # policy lives in /proc/PID/stat field 19 and rtprio in field 20. rtlim
  # comes from /proc/PID/limits.
  echo "sched: $(for p in $(pgrep -f 'hushmic --enable|filter-chain\.conf|pipewire' 2>/dev/null | sort -u); do [ -r "/proc/$p/stat" ] || continue; pol=$(awk '{print $19}' "/proc/$p/stat" 2>/dev/null); rtpri=$(awk '{print $20}' "/proc/$p/stat" 2>/dev/null); rtlim=$(grep 'Max realtime priority' "/proc/$p/limits" 2>/dev/null | awk '{print $5}'); cpu=$(taskset -cp "$p" 2>/dev/null | awk -F: '{print $2}'); printf '[%s]pol=%s rtpri=%s rtlim=%s cpu=%s ' "$p" "${pol:-?}" "${rtpri:-?}" "${rtlim:-?}" "${cpu:-?}"; done)"
  echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg) cpu6_mhz: $(awk '{printf "%.0f", $1/1000}' /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null) cpu7_mhz: $(awk '{printf "%.0f", $1/1000}' /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq 2>/dev/null)"
  echo "filter_cfg: $(md5sum /home/b/.config/hushmic/filter-chain.conf 2>/dev/null | cut -c1-8) $(head -c 400 /home/b/.config/hushmic/filter-chain.conf 2>/dev/null | tr '\n' '|')"
  # pw-dump as user b: XDG_RUNTIME_DIR must survive sudo or PipeWire falls
  # back to /tmp/pipewire-0 and fails to reach the real session socket.
  pw_dump() { sudo -u b --preserve-env=XDG_RUNTIME_DIR XDG_RUNTIME_DIR=/run/user/$uid pw-dump 2>/dev/null; }
  echo "pw_session: $(pw_dump | jq -r '[.objects[] | select(.interface=="Stream") | "\(.stream.direction):\(.properties["application.name"] // "?")"] | join(",")' 2>/dev/null || echo failed)"
  echo "rtkit: $(systemctl is-active rtkit-daemon 2>/dev/null)"
  echo "pw_streams:"
  pw_dump | jq -r '.objects[] | select(.interface=="Stream") | "  \(.stream.direction) node=\(.stream.node.name // "none") client=\(.properties["application.name"] // "?")"' 2>/dev/null || echo "  (pw-dump failed)"
  echo "inputs:"
  pw_dump | jq -r '.objects[] | select(.interface=="Input") | "  name=\(.name // "?") client=\(.properties["application.name"] // "?")"' 2>/dev/null || true
  echo "cpu6_governor: $(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_governor 2>/dev/null || echo none)"
  echo "cpu6_epp: $(cat /sys/devices/system/cpu/cpu6/cpufreq/energy_performance_preference 2>/dev/null || echo none)"
  echo "cpu7_governor: $(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_governor 2>/dev/null || echo none)"
  echo "cpu7_epp: $(cat /sys/devices/system/cpu/cpu7/cpufreq/energy_performance_preference 2>/dev/null || echo none)"
  echo "governors: $(grep -h . /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s ' \n' ' ')"
} > "$out/latest.tmp"
mv -f "$out/latest.tmp" "$out/latest"