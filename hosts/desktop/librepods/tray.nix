{ lib
, python3
, writeShellApplication
}:

# librepods battery system-tray indicator (StatusNotifierItem).
#
# A tiny AirPod SNI icon for the Plasma system tray. It is a *dumb renderer*:
# the librepods daemon (Rust) owns all merge / freshness / source-picking logic
# and writes a flat "last known" record per MAC to
# $XDG_STATE_HOME/librepods/state.json. The tray just reads that file and
# displays it directly — no dual-source (PPM + AACP) model, no freshness
# windows, no source-picking heuristics.
#
# Three surfaces:
#   * Icon (SNI IconPixmap + Status) — always visible in the panel; colour-
#     tinted by aggregate state (white = ok, red = low battery / desync,
#     grey = no data) with a thin battery bar.
#   * Hover tooltip (SNI ToolTip) — multi-line live status of every device
#     (model, MAC, state, in-ear, case lid, L/R/Case battery, age).
#   * Menu (com.canonical.dbusmenu) — flat, emoji-labelled, one line per
#     device (named by model + MAC, with state + battery + age) plus a
#     Reconnect action and Quit, e.g.:
#
#       🎧 AirPods Pro 2 · 74:77:86:25:E5:18 · 🎧 connected · L85 R82⚡ C97 · 42s ago
#       🎧 AirPods 2 · A4:C6:F0:CB:F3:52 · 📡 out_of_case · L75 R73 C93 · 3m ago
#       ⏱ last beacon 42s ago
#       🔌 Reconnect AirPods
#       ⏻ Quit
#
# Pure Python (dbus-next + Pillow) — no third-party SNI library. dbus-next's
# pure-Python marshaller handles the exact SNI wire types (a(iiay) IconPixmap,
# (sassas) ToolTip) that the C dbus-python binding cannot marshal inside an
# a{sv} Properties.GetAll reply. The app is a long-running systemd *user*
# service (see hosts/desktop/librepods/default.nix); it needs the session bus
# to register with org.kde.StatusNotifierWatcher.
#
# Sources live in hosts/desktop/librepods/tray/ (all librepods files in one
# folder); this package only bundles the interpreter + deps and a launcher.

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
