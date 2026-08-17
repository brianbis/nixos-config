{ pkgs, ... }:

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

  hushmicWatcher = pkgs.writeShellScript "hushmic-cpu-watcher" ''
    set -eu
    cm=${cpuMode}
    trap '$cm normal' EXIT INT TERM
    boosting=0
    while :; do
      if pgrep -x hushmic >/dev/null 2>&1; then
        if [ "$boosting" -eq 0 ]; then
          $cm performance
          boosting=1
        fi
        # Boost hushmic process priority
        for pid in $(pgrep -x hushmic); do
          renice -n -10 -p "$pid" 2>/dev/null || true
        done
      else
        if [ "$boosting" -eq 1 ]; then
          $cm normal
          boosting=0
        fi
      fi
      sleep 2
    done
  '';
in
{
  systemd.services.hushmic-cpu-boost = {
    description = "CPU performance boost for hushmic";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" "pipewire.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = hushmicWatcher;
      Restart = "always";
      RestartSec = 2;
      KillSignal = "SIGTERM";
    };
  };
}
