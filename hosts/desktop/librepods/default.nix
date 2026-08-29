{ config, pkgs, lib, ... }:

# LibrePods headless daemon + notification watcher.
#
# librepods (pkgs.librepods, wired via the flake overlay) runs as a systemd
# user service. It owns the Apple-protocol (AACP) lifecycle for the paired
# AirPods: continuous BLE monitor, auto-connect on case-open (shells out
# `bluetoothctl connect <mac>`), and AACP features. Our patch makes it persist
# a thin "last known" record per MAC to $XDG_STATE_HOME/librepods/state.json.
# Each record is a flat set of the last REAL values observed: a null/0xFF
# observation never overwrites a stored value, and case metrics are only
# written by a source actually reading the case (AACP: case connected; PPM:
# case is the advertiser). Both the PPM (advertising) and AACP (connected)
# handlers merge into the same flat record, so readers (tray, this watcher,
# the connect-order script) are dumb renderers with no freshness/source
# heuristics. Written unconditionally (headless-safe).
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
  cfg = config.librepods;

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

    # A device is "active" (out of case / advertising) when its state is one
    # of the advertising states and it was seen within GRACE seconds. The
    # daemon owns the state field (and the last-real merge); the watcher just
    # renders it. "connected" means the pods hold an AACP link to this PC.
    ACTIVE_STATES = {"out_of_case", "music", "call", "ringing", "hanging_up"}

    def active(e):
        age = now - int(e.get("last_seen", 0))
        return e.get("state") in ACTIVE_STATES and 0 <= age < GRACE

    # Current fresh/stale map.
    current = {}
    for mac, e in state.items():
        current[mac] = {"fresh": active(e), "entry": e}

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
            if c_entry.get("state") in ("music", "call") \
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

  # Re-assert the LibrePods connect global shortcut into the user's
  # kglobalshortcutsrc at graphical session start. Merges only the
  # "Connect AirPods" key under the [Custom Commands] group, preserving every
  # other shortcut. (Plasma rewrites this file when shortcuts are edited, so a
  # session-start writer that re-asserts the key is the robust, declarative
  # choice.) The shortcut + command are passed via the service's Environment.
  #
  # NOTE: the value format is "shortcut,command". If the desktop's KDE stores
  # it as "command,shortcut", flip the two in new_value below.
  shortcutScript = pkgs.writeText "librepods-shortcut.py" ''
    #!/usr/bin/env python3
    import os

    name = "Connect AirPods"
    shortcut = os.environ.get("LIBREPODS_SHORTCUT", "Ctrl+Shift+C")
    command = os.environ.get("LIBREPODS_CONNECT_CMD", "bt-connect-headphones")
    path = os.path.join(os.path.expanduser("~/.config"), "kglobalshortcutsrc")

    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        lines = []

    new_value = f"{shortcut},{command}"
    key_prefix = f"{name}="
    section = "[Custom Commands]"

    out = []
    replaced = False
    section_start = None
    for line in lines:
        s = line.strip()
        if s.startswith("["):
            if s == section:
                section_start = len(out)
            out.append(line)
            continue
        if s.startswith(key_prefix):
            out.append(f"{name}={new_value}")
            replaced = True
            continue
        out.append(line)

    if not replaced:
        if section_start is None:
            if out and out[-1].strip() != "":
                out.append("")
            out.append(section)
            out.append(f"{name}={new_value}")
        else:
            insert_at = len(out)
            for j in range(section_start + 1, len(out)):
                if out[j].strip().startswith("["):
                    insert_at = j
                    break
            out.insert(insert_at, f"{name}={new_value}")

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".tmp", "w") as f:
        f.write("\n".join(out) + "\n")
    os.replace(path + ".tmp", path)
  '';

  shortcutWrapper = pkgs.writeShellScriptBin "librepods-shortcut" ''
    exec ${pkgs.python3}/bin/python3 ${shortcutScript}
  '';
in
{
  # --- User-facing options -------------------------------------------------
  options.librepods.connectShortcut = lib.mkOption {
    type = lib.types.str;
    default = "Ctrl+Shift+C";
    description = "KDE global shortcut that triggers the LibrePods connect flow.";
  };
  options.librepods.connectCommand = lib.mkOption {
    type = lib.types.str;
    default = "${config.bluetooth.connectScript}/bin/bt-connect-headphones";
    description = "Command the tray Reconnect action and the global shortcut run.";
  };

  config = {
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
        # The daemon is a multi-threaded tokio runtime (a worker thread per core)
        # at default priority, doing bursty work (battery notifications ->
        # parse + log + state.json write, plus a 1s D-Bus poll). The A2DP audio
        # output path (bluetoothd -> PipeWire -> speaker) also runs at default
        # priority, so the daemon's bursts can delay the audio decode/write
        # thread on a shared core -> sink underrun -> choppy audio. Back the
        # daemon off so it yields to the audio pipeline. It is a control daemon
        # (battery/ear readings, auto-connect) NOT on the audio data path and
        # needs no latency, so this is safe. (audio.nix's priority.driver=2000
        # is WirePlumber node-selection, not CPU priority, so it does not
        # protect the A2DP threads on its own.)
        Nice = 10;
        CPUWeight = 50;
      };
    };

    # Battery system-tray indicator (StatusNotifierItem). A small AirPod SNI
    # icon for the Plasma system tray: a live, colour-tinted icon + a
    # multi-line hover tooltip show every device's status at a glance; the
    # click menu is a flat, emoji-labelled status list plus a Reconnect action
    # and Quit. Reads state.json; runs in the user's graphical session (needs
    # the session bus to register with org.kde.StatusNotifierWatcher); the app
    # retries registration until the watcher is up, so it tolerates
    # plasmashell starting after this unit.
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
        # The menu's Reconnect action shells out to this (non-blocking).
        Environment = [ "LIBREPODS_CONNECT_CMD=${cfg.connectCommand}" ];
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

    # Install the connect global shortcut into the user's kglobalshortcutsrc at
    # graphical session start (re-asserts the key so it survives Plasma
    # rewrites of the file).
    systemd.user.services.librepods-shortcut = {
      description = "LibrePods: install the connect global shortcut into kglobalshortcutsrc";
      wantedBy = [ "default.target" ];
      after = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${shortcutWrapper}/bin/librepods-shortcut";
        Environment = [
          "LIBREPODS_SHORTCUT=${cfg.connectShortcut}"
          "LIBREPODS_CONNECT_CMD=${cfg.connectCommand}"
        ];
      };
    };
  };
}
