{ lib
, python3
, writeShellApplication
}:

# librepods battery system-tray indicator (StatusNotifierItem): a tiny AirPod
# SNI icon for the Plasma tray. It is a *dumb renderer* — the librepods daemon
# (Rust) owns all merge / freshness / source-picking logic and writes a flat
# "last known" record per MAC to $XDG_STATE_HOME/librepods/state.json; the
# tray just reads it. Three surfaces: the icon (colour-tinted by aggregate
# state: white = ok, red = low battery / desync, grey = no data, with a thin
# battery bar), the hover tooltip (multi-line live status per device), and
# the dbusmenu (flat, emoji-labelled, one line per device, plus Reconnect and
# Quit, e.g. "🎧 AirPods Pro 2 · 74:77:86:25:E5:18 · 🎧 connected · L85
# R82⚡ C97 · 42s ago"). Pure Python (dbus-next + Pillow, no third-party SNI
# library): dbus-next's pure-Python marshaller handles the exact SNI wire
# types (a(iiay) IconPixmap, (sassas) ToolTip) that the C dbus-python binding
# cannot marshal inside an a{sv} Properties.GetAll reply. Runs as a long-
# running systemd user service (see default.nix); it needs the session bus to
# register with org.kde.StatusNotifierWatcher. Sources live in tray/ (all
# librepods files in one folder); this package only bundles the interpreter +
# deps and a launcher.

let
  # pygobject3 provides the GLib main loop that dbus-next's GLib bus drives.
  py = python3.withPackages (ps: with ps; [ pygobject3 dbus-next pillow ]);
in
writeShellApplication {
  name = "librepods-tray";
  text = ''
    exec "${py}/bin/python3" "${./tray/librepods-tray.py}" "$@"
  '';
}
