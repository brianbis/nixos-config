#!/usr/bin/env python3
"""librepods battery system-tray indicator (StatusNotifierItem).

A tiny AirPod icon in the Plasma system tray. All device information is
exposed as a textual dbusmenu tree on right-click:

    Devices
      Device 1 - AirPods Pro 2 - active
        Left - 85% - <1m
        Right - 82% - <1m
        Case - 97% - 3m
      Device 2 - ...
    Quit

It reads $XDG_STATE_HOME/librepods/state.json (written by the patched
librepods daemon). The menu layout is rebuilt on every poll; when it
changes the org.freedesktop.DBus.Menu AboutToShow signal is emitted so
the tray client re-fetches the layout.

Implemented with dbus-next (pure-Python D-Bus, GLib-integrated). dbus-next
marshals the exact SNI wire types (a(iiay) IconPixmap, (sassas) ToolTip,
a(ua{sv}) menu layout) correctly, which the C dbus-python binding cannot
do inside an a{sv} Properties.GetAll reply.
"""

import json
import os
import signal
import sys
import time

from gi.repository import GLib, GLibUnix
from PIL import Image, ImageDraw

from dbus_next import Message, MessageType, Variant
from dbus_next.constants import NameFlag, RequestNameReply, PropertyAccess
from dbus_next.glib.message_bus import MessageBus
from dbus_next.service import ServiceInterface, dbus_property, method
from dbus_next.service import signal as dbus_signal

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


def _state_home() -> str:
    return os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")


STATE_FILE = os.path.join(_state_home(), "librepods", "state.json")

BUS_NAME = "com.brian.librepods-battery"
OBJECT_PATH = "/StatusNotifierItem"
# The KDE StatusNotifierWatcher looks the item up on the KDE interface name
# (org.kde.StatusNotifierItem), not the freedesktop one — matching what ksni
# (the Rust SNI lib hushmic uses) exports.
SNI_IFACE = "org.kde.StatusNotifierItem"
MENU_IFACE = "com.canonical.dbusmenu"

WATCHER_NAME = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
WATCHER_IFACE = "org.kde.StatusNotifierWatcher"

POLL_SECONDS = 5
# A device is "active" in the menu if its PPM was seen within this window.
FRESH_SECONDS = 60
# Use the precise AACP battery sub-object while it is fresh.
AACP_FRESH_SECONDS = 300

# Icon rendering: 2x scale for HiDPI crispness, white fill + subtle dark
# outline so the pod is legible on both light and dark panels.
ICON_SCALE = 2
ICON_SIZE = 24 * ICON_SCALE
ICON_FILL = (235, 235, 235, 255)
ICON_STROKE = (25, 25, 25, 255)

# Menu ids. Device i (0-based, most recently seen first) owns
# DEVICE_ID_BASE + i*DEVICE_ID_STRIDE for itself and +1/+2/+3 for its
# Left/Right/Case leaves.
MENU_ID_ROOT = 0
MENU_ID_DEVICES = 1
MENU_ID_SEPARATOR = 2
MENU_ID_QUIT = 3
MENU_ID_NO_DEVICES = 4
DEVICE_ID_BASE = 100
DEVICE_ID_STRIDE = 10


# ---------------------------------------------------------------------------
# State model
# ---------------------------------------------------------------------------


def load_state() -> dict:
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return data
    except (OSError, ValueError):
        pass
    return {}


def _pct(v):
    if isinstance(v, (int, float)) and 0 <= v <= 100:
        return int(round(v))
    return None


def _aacp_fresh(entry: dict) -> bool:
    aacp = entry.get("aacp")
    if not isinstance(aacp, dict):
        return False
    ls = aacp.get("last_seen")
    return isinstance(ls, (int, float)) and (time.time() - ls) < AACP_FRESH_SECONDS


def _entry_last_seen(entry: dict):
    ls = entry.get("last_seen")
    return ls if isinstance(ls, (int, float)) else None


def _age_str(ts) -> str:
    """Rounded age of a timestamp: '<1m', '3m', '2h', '5d'."""
    if not isinstance(ts, (int, float)) or ts <= 0:
        return "n/a"
    age = max(0, int(time.time() - ts))
    if age < 60:
        return "<1m"
    if age < 3600:
        return f"{age // 60}m"
    if age < 86400:
        return f"{age // 3600}h"
    return f"{age // 86400}d"


# ---------------------------------------------------------------------------
# Menu layout
# ---------------------------------------------------------------------------


def _props(label: str, *, display: str = "none", enabled: bool = True) -> dict:
    return {
        "type": Variant("s", "standard"),
        "enabled": Variant("b", enabled),
        "visible": Variant("b", True),
        "label": Variant("s", label),
        "children-display": Variant("s", display),
    }


def _separator() -> dict:
    return {"type": Variant("s", "separator")}


def build_menu_layout(pairs: dict) -> dict:
    """Build the dbusmenu tree: {menu_id: (props, [child_ids])}.

    Devices are ordered most-recently-seen first, so "Device 1" is the
    active pair. Battery values come from the precise AACP sub-object
    while it is fresh, falling back to the coarse PPM values; ages are
    computed from the timestamp of the source actually used.
    """
    now = time.time()

    def sort_key(mac):
        e = pairs[mac]
        ls = _entry_last_seen(e) if isinstance(e, dict) else None
        return ls if ls is not None else 0

    devices = [
        (mac, e)
        for mac, e in sorted(
            pairs.items(), key=lambda kv: sort_key(kv[0]), reverse=True
        )
        if isinstance(e, dict)
    ]

    layout = {
        MENU_ID_ROOT: (
            _props("", display="none"),
            [MENU_ID_DEVICES, MENU_ID_SEPARATOR, MENU_ID_QUIT],
        ),
        MENU_ID_DEVICES: (_props("Devices", display="submenu"), []),
        MENU_ID_SEPARATOR: (_separator(), []),
        MENU_ID_QUIT: (_props("Quit"), []),
    }

    if not devices:
        layout[MENU_ID_DEVICES] = (
            _props("Devices", display="submenu"),
            [MENU_ID_NO_DEVICES],
        )
        layout[MENU_ID_NO_DEVICES] = (_props("No devices", enabled=False), [])
        return layout

    device_ids = []
    for i, (mac, e) in enumerate(devices):
        base = DEVICE_ID_BASE + i * DEVICE_ID_STRIDE
        device_ids.append(base)
        model = e.get("model") or "AirPods"
        ls = _entry_last_seen(e)
        status = "active" if (ls is not None and now - ls < FRESH_SECONDS) else "stale"
        use_aacp = _aacp_fresh(e)
        src = e.get("aacp") if use_aacp else e
        src_ls = src.get("last_seen") if use_aacp else ls
        layout[base] = (
            _props(f"Device {i + 1} - {model} - {status}", display="submenu"),
            [base + 1, base + 2, base + 3],
        )
        for j, (name, key) in enumerate(
            [("Left", "left"), ("Right", "right"), ("Case", "case")], start=1
        ):
            pct = _pct(src.get(key))
            bolt = " \u26a1" if src.get(f"charging_{key}") else ""
            p = f"{pct}%" if pct is not None else "?"
            layout[base + j] = (_props(f"{name} - {p}{bolt} - {_age_str(src_ls)}"), [])
    # Wire the device nodes under the Devices node (most recently seen first).
    layout[MENU_ID_DEVICES] = (_props("Devices", display="submenu"), device_ids)
    return layout


# ---------------------------------------------------------------------------
# Icon rendering
# ---------------------------------------------------------------------------


def render_airpod_pixmap():
    """Render the tiny AirPod icon to an ARGB32 big-endian byte string.

    A single pod silhouette drawn directly in the ICON_SIZE (48x48) canvas:
    a round bud (head) with a stem hanging from it.
    """
    img = Image.new("RGBA", (ICON_SIZE, ICON_SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Stem first (rounded bottom); the head fill is drawn over its top so the
    # junction is seamless. Stem: x 19..29 (width 10), y 10..44.
    d.rounded_rectangle(
        [19, 10, 29, 44],
        radius=5,
        fill=ICON_FILL,
        outline=ICON_STROKE,
        width=2,
    )
    # Head: circle centred at (24,15), r=11 -> bbox [13,4,35,26]. Its fill
    # covers the stem's top. Then only the exposed arc of the head's outline:
    # the bottom of the circle is hidden inside the stem, so a full ellipse
    # stroke would draw a line across the stem. The stem edges (x=19/29)
    # leave the head circle at angles ~117deg / ~63deg, so the visible
    # outline runs 117 -> 423 (i.e. 117 -> 63 the long way, over the top).
    d.ellipse([13, 4, 35, 26], fill=ICON_FILL)
    d.arc(
        [13, 4, 35, 26],
        start=117,
        end=423,
        fill=ICON_STROKE,
        width=2,
    )
    raw = img.convert("RGBA").tobytes()  # R G B A per pixel
    out = bytearray()
    for i in range(0, len(raw), 4):
        out += bytes((raw[i + 3], raw[i], raw[i + 1], raw[i + 2]))  # A R G B
    return (ICON_SIZE, ICON_SIZE, bytes(out))


def _pixmap_list(w: int, h: int, data: bytes) -> list:
    """a(iiay): a list of [width, height, argb_bytes] structs (dbus-next)."""
    return [[w, h, data]]


def _tooltip_struct(lines: list) -> list:
    """(sassas): [icon_name, lines, main_text, extra_lines] (dbus-next)."""
    return ["", lines, "AirPods", []]


# ---------------------------------------------------------------------------
# SNI service (dbus-next)
# ---------------------------------------------------------------------------


class SNI(ServiceInterface):
    """org.freedesktop.StatusNotifierItem.

    dbus-next auto-exports the org.freedesktop.DBus.Properties interface
    (Get/GetAll/Set) for the @dbus_property members, so the a{sv} GetAll
    reply is marshalled by dbus-next's pure-Python code (which handles the
    a(iiay) and (sassas) types that the C dbus-python binding cannot).
    All properties are static: the icon is a fixed AirPod glyph and the
    device detail lives in the dbusmenu tree (right-click).
    """

    def __init__(self, tray: "Tray"):
        super().__init__(SNI_IFACE)
        self._tray = tray

    # -- properties ---------------------------------------------------------
    @dbus_property(PropertyAccess.READ)
    def Category(self) -> "s":
        return "Hardware"

    @dbus_property(PropertyAccess.READ)
    def Id(self) -> "s":
        return "librepods-battery"

    @dbus_property(PropertyAccess.READ)
    def Status(self) -> "s":
        return "Active"

    @dbus_property(PropertyAccess.READ)
    def Title(self) -> "s":
        return "AirPods"

    @dbus_property(PropertyAccess.READ)
    def WindowId(self) -> "u":
        return 0

    @dbus_property(PropertyAccess.READ)
    def IconName(self) -> "s":
        return ""

    @dbus_property(PropertyAccess.READ)
    def IconThemePath(self) -> "as":
        return []

    @dbus_property(PropertyAccess.READ)
    def IconPixmap(self) -> "a(iiay)":
        return self._tray.icon_pixmap

    @dbus_property(PropertyAccess.READ)
    def OverlayIconName(self) -> "s":
        return ""

    @dbus_property(PropertyAccess.READ)
    def OverlayIconPixmap(self) -> "a(iiay)":
        return []

    @dbus_property(PropertyAccess.READ)
    def AttentionIconName(self) -> "s":
        return ""

    @dbus_property(PropertyAccess.READ)
    def AttentionIconPixmap(self) -> "a(iiay)":
        return []

    @dbus_property(PropertyAccess.READ)
    def AttentionMovieName(self) -> "s":
        return ""

    @dbus_property(PropertyAccess.READ)
    def ItemIsMenu(self) -> "b":
        # True: treat the item as a menu. Plasma 6 reliably shows the
        # dbusmenu on click for ItemIsMenu=true items; with false the
        # right-click trigger does not fire for third-party SNI items, so
        # the menu never appeared. With true the menu shows on click
        # (and right-click still works), which is where the device detail lives.
        return True

    @dbus_property(PropertyAccess.READ)
    def Menu(self) -> "o":
        # Object path of the dbusmenu (org.freedesktop.DBus.Menu) that the
        # client shows on right-click. The Menu service is exported at the
        # same object path as the SNI item, so point at OBJECT_PATH. Without
        # this property KDE/plasma has no way to find the menu.
        return OBJECT_PATH

    @dbus_property(PropertyAccess.READ)
    def ToolTip(self) -> "(sassas)":
        return self._tray.tooltip_struct

    # -- SNI methods ---------------------------------------------------------
    @method()
    def Activate(self, x: "i", y: "i") -> "":
        pass

    @method()
    def SecondaryActivate(self, x: "i", y: "i") -> "":
        pass

    @method()
    def ContextMenu(self, x: "i", y: "i") -> "":
        pass

    @method()
    def ProvideXdgActivationToken(self, token: "s") -> "":
        # Plasma 6 uses this during SNI activation to pass the KWin/XDG
        # activation token to the item. This tray has no application window
        # to activate, so accepting and ignoring the token is sufficient.
        pass

    @method()
    def Scroll(self, dx: "i", dy: "i", orientation: "i") -> "":
        pass


class Menu(ServiceInterface):
    """com.canonical.dbusmenu implementation.

    The DBusMenu protocol uses:
      GetLayout(i, i, as) -> (u, (ia{sv}av))
      GetGroupProperties(ai, as) -> a(ia{sv})
      GetProperty(i, s) -> v
      Event(i, s, v, u)
      AboutToShow(i) -> b

    Menu layout items are recursive:
      (menu_id, properties, [Variant("(ia{sv}av)", child), ...])
    """

    def __init__(self, tray: "Tray"):
        super().__init__(MENU_IFACE)
        self._tray = tray

    # ------------------------------------------------------------------
    # DBusMenu properties
    # ------------------------------------------------------------------

    @dbus_property(PropertyAccess.READ)
    def Version(self) -> "u":
        return 3

    @dbus_property(PropertyAccess.READ)
    def Status(self) -> "s":
        return "normal"

    @dbus_property(PropertyAccess.READ)
    def TextDirection(self) -> "s":
        return "ltr"

    @dbus_property(PropertyAccess.READ)
    def IconThemePath(self) -> "as":
        return []

    # ------------------------------------------------------------------
    # Layout
    # ------------------------------------------------------------------

    def _filtered_props(self, props: dict, property_names: list) -> dict:
        """Return requested DBusMenu properties, or all if property_names empty."""
        if not property_names:
            return props

        return {name: value for name, value in props.items() if name in property_names}

    def _layout_item(
        self,
        menu_id: int,
        recursion_depth: int,
        property_names: list,
    ) -> list:
        """Build one recursive DBusMenuLayoutItem.

        Wire type:
            (ia{sv}av)

        The third member is an array of variants, each containing another
        DBusMenuLayoutItem.
        """
        entry = self._tray.menu_layout.get(menu_id)
        if entry is None:
            return [menu_id, {}, []]

        props, children = entry
        props = self._filtered_props(props, property_names)

        child_variants = []

        if recursion_depth != 0:
            next_depth = recursion_depth - 1 if recursion_depth > 0 else -1

            for child_id in children:
                child = self._layout_item(
                    child_id,
                    next_depth,
                    property_names,
                )
                child_variants.append(Variant("(ia{sv}av)", child))

        return [menu_id, props, child_variants]

    @method()
    def GetLayout(
        self,
        parent_id: "i",
        recursion_depth: "i",
        property_names: "as",
    ) -> "u(ia{sv}av)":
        """Return the requested recursive DBusMenu layout."""
        layout = self._layout_item(
            parent_id,
            recursion_depth,
            property_names,
        )

        return [
            self._tray.menu_revision,
            layout,
        ]

    # ------------------------------------------------------------------
    # AboutToShow
    # ------------------------------------------------------------------

    @method()
    def AboutToShow(self, menu_id: "i") -> "b":
        """Tell the client whether it needs to refresh this menu item.

        The tray already rebuilds its layout on every polling cycle and
        emits LayoutUpdated when the layout changes, so there is no need
        to request an additional refresh here.
        """
        return False

    # ------------------------------------------------------------------
    # Group/property access
    # ------------------------------------------------------------------

    @method()
    def GetGroupProperties(
        self,
        ids: "ai",
        property_names: "as",
    ) -> "a(ia{sv})":
        result = []

        for menu_id in ids:
            entry = self._tray.menu_layout.get(menu_id)
            if entry is None:
                continue

            props, _children = entry
            props = self._filtered_props(props, property_names)
            result.append([menu_id, props])

        return result

    @method()
    def GetProperty(
        self,
        menu_id: "i",
        property_name: "s",
    ) -> "v":
        entry = self._tray.menu_layout.get(menu_id)
        if entry is None:
            raise ValueError(f"Unknown menu id {menu_id}")

        props, _children = entry
        value = props.get(property_name)

        if value is None:
            raise ValueError(
                f"Unknown property {property_name!r} " f"for menu id {menu_id}"
            )

        return value

    # ------------------------------------------------------------------
    # Activation/events
    # ------------------------------------------------------------------

    @method()
    def Event(
        self,
        menu_id: "i",
        event_id: "s",
        data: "v",
        timestamp: "u",
    ) -> None:
        if menu_id == MENU_ID_QUIT and event_id == "clicked":
            print("Quit requested via menu", file=sys.stderr)
            self._tray.quit()

    # ------------------------------------------------------------------
    # Signals
    # ------------------------------------------------------------------

    @dbus_signal(name="LayoutUpdated")
    def _emit_layout_updated(self) -> "ui":
        """Notify clients that the complete menu layout changed."""
        return [self._tray.menu_revision, MENU_ID_ROOT]


class Tray:
    def __init__(self, bus: MessageBus):
        self.bus = bus
        self.pairs = {}
        self.menu_layout = {}
        self.menu_revision = 0
        self.icon_pixmap = _pixmap_list(*render_airpod_pixmap())
        self.tooltip_struct = _tooltip_struct(["Right-click for details"])
        self._registered = False
        self.sni = SNI(self)
        self.menu = Menu(self)
        bus.export(OBJECT_PATH, self.sni)
        bus.export(OBJECT_PATH, self.menu)

    # -- state refresh ------------------------------------------------------
    def refresh(self):
        pairs = load_state()
        self.pairs = pairs
        layout = build_menu_layout(pairs)
        if layout != self.menu_layout:
            self.menu_layout = layout
            self.menu_revision += 1
            self.menu._emit_layout_updated()
        # Retry watcher registration until plasmashell's StatusNotifierWatcher
        # is up (it may lag the service at session start).
        if not self._registered:
            self.register_with_watcher()
        return True

    def menu_subtree(self, parent_id: int) -> list:
        """Pre-order [menuId, props] list for the subtree rooted at parent_id.

        Depth-first pre-order (the root first, then each child's full
        subtree) — the conventional dbusmenu layout ordering that KDE's
        KDBusMenu expects.
        """
        out = []

        def walk(mid):
            entry = self.menu_layout.get(mid)
            if entry is None:
                return
            props, children = entry
            out.append([mid, props])
            for child in children:
                walk(child)

        walk(parent_id)
        return out

    # -- lifecycle ----------------------------------------------------------
    def register_with_watcher(self):
        """Register with org.kde.StatusNotifierWatcher.

        The KDE watcher's RegisterStatusNotifierItem takes a SINGLE string
        (serviceOrPath): a value starting with '/' is an object path (the
        caller's bus name is used as the service); otherwise it's a bus name
        and the item is assumed to live at /StatusNotifierItem. We pass the
        object path. If the watcher isn't up yet the call fails fast
        (NameHasNoOwner) and we retry on the next poll; if it is up the call
        returns immediately (void).
        """
        if self._registered:
            return
        msg = Message(
            destination=WATCHER_NAME,
            path=WATCHER_PATH,
            interface=WATCHER_IFACE,
            member="RegisterStatusNotifierItem",
            message_type=MessageType.METHOD_CALL,
            signature="s",
            body=[OBJECT_PATH],
        )
        try:
            self.bus.call_sync(msg)
            print(
                f"Watcher registered {OBJECT_PATH} with {WATCHER_NAME}", file=sys.stderr
            )
            self._registered = True
        except Exception as e:  # noqa: BLE001
            print(f"Watcher registration failed (will retry): {e}", file=sys.stderr)

    def quit(self):
        # Ask systemd to stop us (we run as a user service).
        try:
            os.kill(os.getpid(), signal.SIGTERM)
        except OSError:
            sys.exit(0)


def main() -> int:
    try:
        bus = MessageBus()
        bus.connect_sync()
    except Exception as e:  # noqa: BLE001
        print(f"Could not connect to session bus: {e}", file=sys.stderr)
        return 1

    try:
        reply = bus.request_name_sync(BUS_NAME, NameFlag.NONE)
    except Exception as e:  # noqa: BLE001
        print(f"Could not own bus name {BUS_NAME}: {e}", file=sys.stderr)
        return 1
    if reply != RequestNameReply.PRIMARY_OWNER:
        print(
            f"Bus name {BUS_NAME} not acquired (reply={reply}); another instance?",
            file=sys.stderr,
        )
        return 1

    tray = Tray(bus)
    tray.refresh()  # initial state + menu layout

    loop = GLib.MainLoop()
    GLib.timeout_add_seconds(POLL_SECONDS, tray.refresh)

    def _on_sigterm(*_):
        print("SIGTERM received, shutting down", file=sys.stderr)
        loop.quit()
        return False

    GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, _on_sigterm, None)

    print(f"librepods-tray: serving {BUS_NAME} at {OBJECT_PATH}", file=sys.stderr)
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
