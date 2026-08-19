{ pkgs, ... }:

# Steam gaming CPU boost. The audio cores (cpu6/7) are owned by
# hushmic-audio-cores (see hushmic/scheduler.nix) and stay at performance;
# this service flips ALL cores to performance while a game is running and back
# to powersave/balance_power when it exits. It never touches cpu6/7's EPP
# state in a conflicting way (writing performance there is a no-op), so the
# two services cannot race on the audio cores. GameMode still applies
# per-process tuning for games.
let
  gamingMode = pkgs.writeShellScript "steam-gaming-mode" ''
    ${pkgs.bash}/bin/bash -euo pipefail
    mode="$1"
    case "$mode" in
      gaming)
        perf=performance
        epp=performance
        ;;
      normal)
        perf=powersave
        epp=balance_power
        ;;
      *)
        echo "usage: $0 {gaming|normal}" >&2
        exit 1
        ;;
    esac
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
      base=$(basename "$cpu")
      # Audio cores 6/7 are permanently pinned to performance by hushmic
      [ "$base" = cpu6 ] || [ "$base" = cpu7 ] && continue
      [ -e "$cpu/cpufreq/scaling_governor" ] && echo "$perf" > "$cpu/cpufreq/scaling_governor" || true
      [ -e "$cpu/cpufreq/energy_performance_preference" ] && echo "$epp" > "$cpu/cpufreq/energy_performance_preference" || true
    done
  '';

  steamGameWatcher = pkgs.writeShellScript "steam-game-watcher" ''
    ${pkgs.bash}/bin/bash -euo pipefail
    gm=${gamingMode}
    # Keep watcher off audio cores 6/7
    taskset -pc "0-5,8-23" $$ 2>/dev/null || true
    trap 'exit 0' INT TERM
    trap '$gm normal' EXIT
    gaming=0
    up=0
    down=0
    # Pattern via file so the watcher's own argv never carries it (which made
    # find-based scans self-match and pinned the governor to performance).
    sp=/var/log/hushmic/steam-pattern
    # /var/log/hushmic is created by hushmic-probe's LogsDirectory; mkdir -p
    # only covers the brief window before that unit has started at boot.
    mkdir -p /var/log/hushmic
    printf '%s\n' 'steamapps/common/|steamapps/compatdata/|compatdata/[0-9]+/.*\.(exe|EXE)|wine(64|32)' > "$sp.tmp"
    mv -f "$sp.tmp" "$sp"
    while :; do
      if timeout 1 find /proc -maxdepth 2 -type f -name cmdline -exec grep -qzE -f "$sp" {} + 2>/dev/null; then
        up=$((up+1))
        down=0
        if [ "$gaming" -eq 0 ] && [ "$up" -ge 2 ]; then
          $gm gaming
          gaming=1
          up=0
        fi
      else
        down=$((down+1))
        up=0
        if [ "$gaming" -eq 1 ] && [ "$down" -ge 3 ]; then
          $gm normal
          gaming=0
          down=0
        fi
      fi
      sleep 3
    done
  '';

  steamCpuIsolate = pkgs.writeShellScript "steam-cpu-isolate" ''
    ${pkgs.bash}/bin/bash -euo pipefail
    mask="0-5,8-23"
    trap 'exit 0' INT TERM
    while :; do
      # Isolate Steam client and its children from audio cores 6/7
      for pid in $(pgrep -f '^/nix/store/.*/bin/steam' 2>/dev/null || true); do
        taskset -pc "$mask" "$pid" 2>/dev/null || true
      done
      # Also isolate Proton/Wine game processes
      for pid in $(pgrep -f 'wine(64|32).*steamapps' 2>/dev/null || true); do
        taskset -pc "$mask" "$pid" 2>/dev/null || true
      done
      sleep 5
    done
  '';
in
{
  programs.steam.enable = true;

  programs.gamemode = {
    enable = true;
    settings = {
      general.renice = 10;
    };
  };

  # The watcher needs root because it writes CPU policy sysfs files.
  systemd.services.steam-gaming-mode = {
    description = "Automatic Steam gaming CPU performance mode";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = steamGameWatcher;
      Restart = "always";
      RestartSec = 3;
      KillSignal = "SIGTERM";
      TimeoutStopSec = "5s";
      CPUAffinity = [ 0 1 2 3 4 5 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 ];
    };
  };

  systemd.services.steam-cpu-isolate = {
    description = "Keep Steam/Proton off audio cores 6/7";
    wantedBy = [ "multi-user.target" ];
    after = [ "steam-gaming-mode.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = steamCpuIsolate;
      Restart = "always";
      RestartSec = 2;
      TimeoutStopSec = "5s";
    };
  };
}