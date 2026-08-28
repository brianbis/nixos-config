{ config, pkgs, lib, ... }:

# LibrePods headless daemon + notification watcher.
#
# librepods (pkgs.librepods, wired via the flake overlay) runs as a systemd
# user service. It owns the Apple-protocol (AACP) lifecycle for the paired
# AirPods: continuous BLE monitor, auto-connect on case-open (shells out
# `bluetoothctl connect <mac>`), and AACP features. Our patch makes it persist
# the parsed Proximity Pairing Message state to
# $XDG_STATE_HOME/librepods/state.json on every PPM event (unconditionally, so
# it works headless).
#
# The notification watcher is a 10s oneshot timer that diffs state.json
# against its own last-seen copy and fires KDE notifications on transitions
# (out-of-case, no-longer-advertising, out-of-ear-while-playing). state.json
# is the reusable hook: any future consumer (e.g. auto-connect-on-case-open)
# can read it the same way.
#
# ONBOARDING (one-time per device): connect each AirPods pair once while
# librepods is running (e.g. press Ctrl+Shift+C, or just pair them normally).
# librepods detects the connected AirPods (AACP UUID), runs the AACP handshake,
# and captures the LE keys (IRK + enc_key) into devices.json. After that the
# LE monitor matches the RPA and auto-connects on case-open. A service restart
# (or next login) makes the LE monitor pick up the freshly captured keys.

let
  notifyScript = pkgs.writeText "librepods-notify.py" ''
    #!/usr/bin/env python3
    """LibrePods notification watcher.

    Diffs $XDG_STATE_HOME/librepods/state.json (written by the patched
    librepods daemon) against a last-seen copy and fires KDE notifications on
    state transitions. Runs as a 10s oneshot timer.
    """
    import json, os, subprocess, time

    # Absolute busctl path: systemd user services have a minimal PATH.
    BUSCTL = "${pkgs.dbus}/bin/busctl"

    def state_home():
        return os.environ.get("XDG_STATE_HOME",
                              os.path.expanduser("~/.local/state"))

    STATE = os.path.join(state_home(), "librepods", "state.json")
    LAST = STATE + ".watcher-last"
    GRACE = 30  # seconds; a MAC is "no longer advertising" if last_seen is older

    def load(path):
        try:
            with open(path) as f:
                return json.load(f)
        except Exception:
            return {}

    def notify(summary, body):
        try:
            subprocess.run(
                [BUSCTL, "--user", "call", "org.freedesktop.Notifications",
                 "/org/freedesktop.Notifications", "org.freedesktop.Notifications",
                 "Notify", "s", "librepods", "s", "", "s", summary, "s", body,
                 "as", "0", "a{sv}", "0", "i", "5000"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        except Exception:
            pass  # never let a notification failure break the watcher

    def bat(e):
        def p(v):
            return "n/a" if v is None else f"{v}%"
        return f"L {p(e.get('left'))} R {p(e.get('right'))} · case {p(e.get('case'))}"

    now = int(time.time())
    state = load(STATE)
    last = load(LAST)

    # Current fresh/stale map.
    current = {}
    for mac, e in state.items():
        age = now - int(e.get("last_seen", 0))
        current[mac] = {"fresh": 0 <= age < GRACE, "entry": e}

    for mac in set(current) | set(last):
        c = current.get(mac)
        c_fresh = bool(c and c["fresh"])
        c_entry = c["entry"] if c else None
        l = last.get(mac) or {}
        l_fresh = bool(l.get("fresh"))
        l_entry = l.get("entry")

        if c_fresh and not l_fresh:
            notify(f"AirPods out of case",
                   f"{c_entry.get('model', 'AirPods')} — {bat(c_entry)}")
        elif l_fresh and not c_fresh:
            notify("AirPods no longer advertising",
                   "In case or on another device")
        elif c_fresh and l_fresh and c_entry:
            # Out-of-ear while audio is active (transition from in-ear).
            if c_entry.get("connection_state") in ("music", "call") \
                    and not c_entry.get("in_case"):
                for side in ("left", "right"):
                    if not c_entry.get(f"in_ear_{side}") \
                            and l_entry and l_entry.get(f"in_ear_{side}"):
                        notify(f"AirPods {side} pod out of ear",
                               f"Playing audio but the {side} pod reads out-of-ear")

    # Persist last-seen (current MACs + any that were fresh but are now gone,
    # marked stale so the stop-transition fires exactly once).
    new_last = {mac: {"fresh": c["fresh"], "entry": c["entry"]}
                for mac, c in current.items()}
    for mac, l in last.items():
        if mac not in new_last and l.get("fresh"):
            new_last[mac] = {"fresh": False, "entry": l.get("entry")}
    try:
        os.makedirs(os.path.dirname(LAST), exist_ok=True)
        with open(LAST + ".tmp", "w") as f:
            json.dump(new_last, f)
        os.replace(LAST + ".tmp", LAST)
    except Exception:
        pass
  '';

  notifyWrapper = pkgs.writeShellScriptBin "librepods-notify" ''
    exec ${pkgs.python3}/bin/python3 ${notifyScript}
  '';
in
{
  # Headless LibrePods daemon.
  systemd.user.services.librepods = {
    description = "LibrePods headless AirPods daemon (AACP lifecycle + state.json)";
    wantedBy = [ "default.target" ];
    # Let the system bluetoothd settle before the daemon calls set_powered.
    serviceConfig = {
      Type = "simple";
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      ExecStart = "${pkgs.librepods}/bin/librepods --no-tray";
      Restart = "always";
      RestartSec = "5";
      Environment = [ "RUST_LOG=info" ];
    };
  };

  # Battery system-tray indicator (StatusNotifierItem). A tiny AirPod SNI
  # icon for the Plasma system tray: reads state.json and exposes per-device
  # battery detail (Devices -> Device N -> Left/Right/Case, with charge and
  # rounded age) as a textual right-click menu. Runs in the user's graphical
  # session (needs the session bus to register with
  # org.kde.StatusNotifierWatcher); the app retries registration until the
  # watcher is up, so it tolerates plasmashell starting after this unit.
  systemd.user.services.librepods-tray = {
    description = "LibrePods battery system-tray indicator (SNI)";
    wantedBy = [ "default.target" ];
    after = [ "graphical-session.target" ];
    wants = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.librepodsTray}/bin/librepods-tray";
      Restart = "on-failure";
      RestartSec = "3";
    };
  };

  # Notification watcher (oneshot, driven by the timer below).
  systemd.user.services.librepods-notify = {
    description = "LibrePods notification watcher (one-shot)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${notifyWrapper}/bin/librepods-notify";
    };
  };

  systemd.user.timers.librepods-notify = {
    description = "LibrePods notification watcher timer (10s)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15"; # give librepods a head start before the first diff
      OnUnitActiveSec = "10";
      AccuracySec = "5s";
    };
  };
}
