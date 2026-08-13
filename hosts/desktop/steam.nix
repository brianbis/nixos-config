{ pkgs, ... }:

let
  gamingMode = pkgs.writeShellScript "steam-gaming-mode" ''
    set -eu

    mode="$1"

    case "$mode" in
      gaming)
        echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
        echo performance > /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference

        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
          [ -e "$cpu/cpufreq/scaling_governor" ] &&
            echo performance > "$cpu/cpufreq/scaling_governor"

          [ -e "$cpu/cpufreq/energy_performance_preference" ] &&
            echo performance > "$cpu/cpufreq/energy_performance_preference"
        done
        ;;

      normal)
        for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
          [ -e "$cpu/cpufreq/scaling_governor" ] &&
            echo powersave > "$cpu/cpufreq/scaling_governor"

          [ -e "$cpu/cpufreq/energy_performance_preference" ] &&
            echo balance_power > "$cpu/cpufreq/energy_performance_preference"
        done
        ;;

      *)
        echo "usage: $0 {gaming|normal}" >&2
        exit 1
        ;;
    esac
  '';

  steamGameWatcher = pkgs.writeShellScript "steam-game-watcher" ''
    set -eu

    gaming=0

    cleanup() {
      ${gamingMode} normal || true
    }

    trap cleanup EXIT INT TERM

    while true; do
      game_running=0

      for proc in /proc/[0-9]*; do
        pid="''${proc##*/}"

        [ -r "$proc/cmdline" ] || continue
        [ -r "$proc/exe" ] || continue

        cmdline="$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)"
        exe="$(readlink "$proc/exe" 2>/dev/null || true)"

        # Native Steam games.
        if printf '%s\n' "$cmdline" | grep -q '/steamapps/common/'; then
          game_running=1
          break
        fi

        # Proton/Wine games.
        if printf '%s\n' "$cmdline" | grep -qE '/compatdata/[0-9]+/.*(\\.exe|\\.EXE|wine64|wine32)'; then
          game_running=1
          break
        fi

        # Steam Linux Runtime game processes.
        if printf '%s\n' "$cmdline" | grep -q '/steamapps/compatdata/'; then
          game_running=1
          break
        fi

        # Native executable whose path lives inside a Steam library.
        case "$exe" in
          */steamapps/common/*)
            game_running=1
            break
            ;;
        esac
      done

      if [ "$game_running" -eq 1 ] && [ "$gaming" -eq 0 ]; then
        ${gamingMode} gaming
        gaming=1
      elif [ "$game_running" -eq 0 ] && [ "$gaming" -eq 1 ]; then
        ${gamingMode} normal
        gaming=0
      fi

      sleep 2
    done
  '';
in
{
  programs.steam.enable = true;

  # Keep GameMode available for games that explicitly use it,
  # but don't let its CPU configuration fight TLP.
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
    after = [ "tlp.service" ];
    wants = [ "tlp.service" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = steamGameWatcher;
      Restart = "always";
      RestartSec = 2;

      # If the service is killed, the script's EXIT trap restores normal mode.
      KillSignal = "SIGTERM";
    };
  };
}