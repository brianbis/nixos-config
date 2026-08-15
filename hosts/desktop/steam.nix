{ pkgs, ... }:

let
  gamingMode = pkgs.writeShellScript "steam-gaming-mode" ''
    set -eu
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
      [ -e "$cpu/cpufreq/scaling_governor" ] && echo "$perf" > "$cpu/cpufreq/scaling_governor" || true
      [ -e "$cpu/cpufreq/energy_performance_preference" ] && echo "$epp" > "$cpu/cpufreq/energy_performance_preference" || true
    done
  '';

  steamGameWatcher = pkgs.writeShellScript "steam-game-watcher" ''
    set -eu
    gm=${gamingMode}
    trap '$gm normal' EXIT INT TERM
    gaming=0
    while :; do
      if find /proc -maxdepth 2 -type f -name cmdline -exec grep -qzE 'steamapps/common/|steamapps/compatdata/|compatdata/[0-9]+/.*\.(exe|EXE)|wine(64|32)' {} + 2>/dev/null; then
        if [ "$gaming" -eq 0 ]; then
          $gm gaming
          gaming=1
        fi
      else
        if [ "$gaming" -eq 1 ]; then
          $gm normal
          gaming=0
        fi
      fi
      sleep 2
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

  systemd.services.steam-gaming-mode = {
    description = "Automatic Steam gaming CPU performance mode";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = steamGameWatcher;
      Restart = "always";
      RestartSec = 2;
      KillSignal = "SIGTERM";
    };
  };
}
