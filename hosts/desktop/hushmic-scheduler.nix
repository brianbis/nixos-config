{ pkgs, ... }:

# Single owner of the CPU governor + EPP for the desktop. Both the hushmic
# boost and the Steam gaming boost funnel through one debounced state machine
# so the governor is only ever written by a deterministic transition, never
# raced. TLP (which periodically re-asserted powersave and made the governor
# flap mid-audio-stream) is disabled in host.nix; thermald only caps max
# frequency on thermal events and is left in place.
let
  cpuMode = pkgs.writeShellScript "hushmic-cpu-mode" ''
    set -eu
    mode="$1"
    case "$mode" in
      performance)
        perf=performance
        epp=performance
        ;;
      normal)
        perf=powersave
        epp=balance_power
        ;;
      *)
        echo "usage: $0 {performance|normal}" >&2
        exit 1
        ;;
    esac
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
      [ -e "$cpu/cpufreq/scaling_governor" ] && echo "$perf" > "$cpu/cpufreq/scaling_governor" || true
      [ -e "$cpu/cpufreq/energy_performance_preference" ] && echo "$epp" > "$cpu/cpufreq/energy_performance_preference" || true
    done
  '';

  audioBoostWatcher = pkgs.writeShellScript "audio-cpu-watcher" ''
    set -eu
    cm=${cpuMode}
    trap '$cm normal' EXIT INT TERM
    # The makeWrapper binary's comm is ".hushmic-wrappe", so match the wrapped
    # binary path in the full cmdline instead.
    hp='bin/\.hushmic-wrapped'
    # Steam predicate: pattern via file so the watcher's own argv never
    # carries it (which made find-based scans self-match and pinned the
    # governor to performance).
    sp=/var/lib/hushmic-cpu-boost/steam-pattern
    mkdir -p /var/lib/hushmic-cpu-boost
    printf '%s\n' 'steamapps/common/|steamapps/compatdata/|compatdata/[0-9]+/.*\.(exe|EXE)|wine(64|32)' > "$sp.tmp"
    mv -f "$sp.tmp" "$sp"
    boosting=0
    seen=0
    miss=0
    while :; do
      if pgrep -f "$hp" >/dev/null 2>&1 || grep -qzE -f "$sp" /proc/[0-9]*/cmdline 2>/dev/null; then
        seen=$((seen+1))
        miss=0
      else
        miss=$((miss+1))
        seen=0
      fi
      # Debounce: two consecutive agreeing samples (4s) before any transition.
      if [ "$seen" -ge 2 ] && [ "$boosting" -eq 0 ]; then
        $cm performance
        boosting=1
      fi
      if [ "$miss" -ge 2 ] && [ "$boosting" -eq 1 ]; then
        $cm normal
        boosting=0
      fi
      if [ "$boosting" -eq 1 ]; then
        # Re-assert if an external actor drifted the governor while boosting.
        g0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
        if [ "$g0" != "performance" ]; then
          $cm performance
        fi
        # Boost hushmic process priority.
        for pid in $(pgrep -f "$hp" 2>/dev/null || true); do
          renice -n -10 -p "$pid" 2>/dev/null || true
        done
      fi
      sleep 2
    done
  '';

  probeDaemon = pkgs.writeShellScript "hushmic-probe-daemon" ''
    set -uo pipefail
    probe=/etc/nixos/hosts/desktop/hushmic-probe.sh
    ring=/var/lib/crush-system/hushmic-probe/ring
    while :; do
      # Tolerate transient probe failures (set -e here used to kill the whole
      # daemon when a script edit was mid-flight or a command misbehaved).
      "$probe" || echo "probe failed: $?" >> /var/lib/crush-system/hushmic-probe/errors
      cat /var/lib/crush-system/hushmic-probe/latest >> "$ring" 2>/dev/null || true
      # Keep the ring bounded.
      if [ -s "$ring" ]; then
        tail -n 3000 "$ring" > "$ring.tmp" && mv -f "$ring.tmp" "$ring"
      fi
      sleep 2
    done
  '';
in
{
  systemd.services.hushmic-cpu-boost = {
    description = "CPU performance boost for hushmic and Steam gaming";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" "pipewire.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = audioBoostWatcher;
      Restart = "always";
      RestartSec = 2;
      KillSignal = "SIGTERM";
      # Allow the watcher's own renice -10 and any RT scheduling headroom.
      Nice = 0;
    };
  };

  systemd.services.hushmic-probe = {
    description = "hushmic/PipeWire state probe ring";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" "pipewire.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = probeDaemon;
      Restart = "always";
      RestartSec = 2;
      StateDirectory = "crush-system";
    };
  };
}