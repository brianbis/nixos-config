{ lib, pkgs, ... }:

let
  headphoneDevices = [
    "A4:C6:F0:CB:F3:52"
    "74:77:86:25:E5:18"
  ];

  # The newer Pro pair — preferred when the two pairs tie (better sound).
  preferredMac = "74:77:86:25:E5:18";

  # Rank the two pairs from librepods state.json (the patched daemon's flat
  # last-known record): out-of-case (advertising state, seen within 60s) first,
  # then the preferred Pro pair, then higher effective battery (min of L/R).
  # Falls back to Pro-first when state.json is absent/stale. Prints MACs best-first.
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
    active_states = {"out_of_case", "music", "call", "ringing", "hanging_up"}
    def eff(e):
        v = [e.get(k) for k in ("left", "right") if e.get(k) is not None]
        return min(v) if v else -1
    def key(mac):
        e = data.get(mac, {})
        # Out of case only when the daemon's state is advertising AND fresh.
        fresh = 1 if (e.get("state") in active_states
                      and 0 <= now - int(e.get("last_seen", 0)) < 60) else 0
        return (-fresh, 0 if mac == pro else 1, -eff(e))
    print(" ".join(sorted(macs, key=key)))
  '';

  # Connect to the AirPods (Ctrl+Shift+C and the boot/resume services call
  # this). flock-guarded against double-connect; exits 0 if either pair is
  # already connected; otherwise round-robins `timeout 15 bluetoothctl connect`
  # in state.json order until the window expires (default 60s; 1st arg
  # overrides). Notifies on success or expiry.
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
  # Exposed so other modules (librepods tray Reconnect, the KDE shortcut
  # installer) can reference the connect script by path.
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
          # Do NOT set ControllerMode = "bredr": it is machine-wide, disables LE
          # entirely (BlueZ refuses to create any LE bearer), and makes ANCS
          # notification mirroring from the iPhone impossible. "dual" is required.
          Experimental = true;
          FastConnectable = true;
          JustWorksRepairing = "always";

          # Present the controller as Apple hardware (vendor id 004C) so BlueZ
          # reports Modalias bluetooth:v004Cp0000d0000, which tether's
          # presents_as_apple() publishes as apple_device_id in bt_status.
          # Without it the AirPods offer no AAP ownership here, so a call hands
          # them to the iPhone by disconnecting instead of using Apple's
          # handoff. Machine-wide: once the firmware believes it talks to Apple
          # it applies Apple expectations (session watchdogs, ownership
          # arbitration, intolerance of rapid profile changes) — intended here,
          # since both pairs are AirPods.
          DeviceID = "bluetooth:004C:0000:0000";
        };

        Policy = {
          AutoEnable = true;
          ReconnectAttempts = 7;
          ReconnectIntervals = "1,2,4,8,16,32,64";
        };
      };
    };

    # On the system PATH so the KDE global shortcut (Ctrl+Shift+C) and the
    # .desktop command shortcut can both call it by name.
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
