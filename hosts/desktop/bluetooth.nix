{ lib, pkgs, ... }:

let
  headphoneDevices = [
    "A4:C6:F0:CB:F3:52"
    "74:77:86:25:E5:18"
  ];

  # The newer Pro pair — preferred when the two pairs tie (better sound).
  preferredMac = "74:77:86:25:E5:18";

  # Rank the two pairs from librepods state.json (written by the patched
  # daemon on every PPM event): advertising (out of case) first, then the
  # preferred (newer Pro) pair, then higher effective battery (min of L/R).
  # Falls back to Pro-first when state.json is absent or stale. Prints the
  # MACs space-separated, best first.
  orderScript = pkgs.writeText "librepods-order.py" ''
    import json, os, time
    pro = "74:77:86:25:E5:18"
    macs = ["A4:C6:F0:CB:F3:52", pro]
    sh = os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
    try:
        data = json.load(open(os.path.join(sh, "librepods", "state.json")))
    except Exception:
        data = {}
    now = int(time.time())
    def eff(e):
        v = [e.get(k) for k in ("left", "right") if e.get(k) is not None]
        return min(v) if v else -1
    def key(mac):
        e = data.get(mac, {})
        fresh = 1 if now - int(e.get("last_seen", 0)) < 60 else 0
        return (-fresh, 0 if mac == pro else 1, -eff(e))
    print(" ".join(sorted(macs, key=key)))
  '';

  # Connect to the AirPods. Ctrl+Shift+C (and the boot/resume services) call
  # this. Behaviour:
  #   * flock-guarded so concurrent presses don't double-connect (a second
  #     press while one is in flight exits 0 immediately);
  #   * fast path: if either pair is already connected, exit 0;
  #   * order the pairs from state.json (out-of-case first, then Pro, then
  #     battery) and round-robin `timeout 15 bluetoothctl connect` until the
  #     60s window expires;
  #   * notify on success; on expiry notify and exit 1.
  # Optional 1st arg overrides the window (default 60s).
  bluetoothConnectScript = pkgs.writeShellScriptBin "bt-connect-headphones" ''
    #!${pkgs.bash}/bin/bash
    set -u

    BTCTL=${pkgs.bluez}/bin/bluetoothctl
    TIMEOUT=${pkgs.coreutils}/bin/timeout
    FLOCK=${pkgs.util-linux}/bin/flock
    BUSCTL=${pkgs.dbus}/bin/busctl
    PYTHON=${pkgs.python3}/bin/python3
    ORDER=${orderScript}

    MACS=(${builtins.concatStringsSep " " headphoneDevices})
    WINDOW=''${1:-60}

    notify() {
      "$BUSCTL" --user call org.freedesktop.Notifications /org/freedesktop.Notifications \
        org.freedesktop.Notifications Notify s librepods s "" s "$1" s "$2" \
        as 0 a{sv} 0 i 5000 >/dev/null 2>&1 || true
    }

    # Concurrency guard: if another instance is already connecting, bail out.
    LOCKFILE="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bt-connect-headphones.lock"
    exec 9>"$LOCKFILE"
    if ! "$FLOCK" -n 9; then
      exit 0
    fi

    # Fast path: already connected to one of the pairs.
    for mac in "''${MACS[@]}"; do
      if "$BTCTL" info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
        exit 0
      fi
    done

    # Order the pairs (out-of-case first, then Pro, then battery).
    ORDERED_MACS=($("$PYTHON" "$ORDER"))

    START=$(date +%s)
    DEADLINE=$((START + WINDOW))

    while (( $(date +%s) < DEADLINE )); do
      for mac in "''${ORDERED_MACS[@]}"; do
        (( $(date +%s) >= DEADLINE )) && break
        if "$TIMEOUT" 15 "$BTCTL" connect "$mac" 2>&1 | grep -q "Connection successful"; then
          notify "Connected to AirPods" "$mac"
          exit 0
        fi
      done
      sleep 1
    done

    notify "Could not connect" "No AirPods connected within ''${WINDOW}s"
    exit 1
  '';
in
{
  # Expose the connect script so other modules (e.g. librepods's tray Reconnect
  # action and the KDE global-shortcut installer) can reference it by path.
  options.bluetooth.connectScript = lib.mkOption {
    internal = true;
    default = bluetoothConnectScript;
    type = lib.types.raw;
  };

  config = {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;

      settings = {
        General = {
          # Force BlueZ to use Classic Bluetooth (BR/EDR) only for audio devices.
          # This prevents BlueZ from getting confused by AirPods BLE "Find My" addresses.
          ControllerMode = "bredr";

          Experimental = true;
          FastConnectable = true;
          JustWorksRepairing = "always";
        };

        Policy = {
          AutoEnable = true;
          ReconnectAttempts = 7;
          ReconnectIntervals = "1,2,4,8,16,32,64";
        };
      };
    };

    # Exposed on the system PATH so the KDE global shortcut (Ctrl+Shift+C)
    # and the .desktop-based command shortcut can both call it by name.
    environment.systemPackages = [ bluetoothConnectScript ];

    services.blueman.enable = false;

    systemd.services.bluetooth-trust-headphones = {
      description = "Trust & auto-connect AirPods & Bluetooth Headphones on boot";
      after = [ "bluetooth.service" ];
      wants = [ "bluetooth.service" ];
      wantedBy = [ "bluetooth.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart =
          (map
            (mac: "${pkgs.bash}/bin/bash -c '${pkgs.bluez}/bin/bluetoothctl trust ${mac} || true'")
            headphoneDevices)
          ++ [ "${bluetoothConnectScript}/bin/bt-connect-headphones" ];
      };
    };

    systemd.services.bluetooth-reconnect-on-resume = {
      description = "Reconnect Bluetooth headphones after resume";
      after = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];
      wantedBy = [ "suspend.target" "hibernate.target" "hybrid-sleep.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
        ExecStart = "${bluetoothConnectScript}/bin/bt-connect-headphones";
      };
    };
  };
}
