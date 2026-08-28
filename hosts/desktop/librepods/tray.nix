{ lib
, python3
, writeShellApplication
}:

# librepods battery system-tray indicator (StatusNotifierItem).
#
# A tiny AirPod SNI icon for the Plasma system tray. It reads
# $XDG_STATE_HOME/librepods/state.json (written by the patched librepods
# daemon) and exposes all device information as a textual dbusmenu tree on
# right-click:
#
#   Devices
#     Device 1 - AirPods Pro 2 - active
#       Left - 85% - <1m
#       Right - 82% - <1m
#       Case - 97% - 3m
#     Device 2 - ...
#   Quit
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
