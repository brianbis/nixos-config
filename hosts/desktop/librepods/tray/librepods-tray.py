#!/usr/bin/env python3
"""librepods battery system-tray indicator (StatusNotifierItem).

A small AirPod icon in the Plasma system tray that is a *glanceable, live*
status surface plus a compact action menu. This tray is a **dumb renderer**:
the librepods daemon (Rust) owns all merge / freshness / source-picking logic
and writes a flat "last-known" record per MAC to
$XDG_STATE_HOME/librepods/state.json. The tray just reads that file and
displays it directly — there is no dual-source (PPM + AACP) model, no
freshness windows, and no source-picking heuristics here.

Three surfaces:

  * Icon (SNI ``IconPixmap`` + ``Status``) — always visible in the panel.
    The glyph is colour-tinted by aggregate state (white = ok, red = low
    battery / desync, grey = no data) with a thin battery bar.
  * Hover tooltip (SNI ``ToolTip``) — multi-line, shows the full live status
    of every device (model, MAC, state, in-ear, case lid, L/R/Case battery,
    age) with **no interaction**.
  * Menu (``com.canonical.dbusmenu``) — flat, emoji-labelled, one line per
    device (named by model + MAC, with state + battery + age) plus a
    prominent **Reconnect** action and **Quit**.

On every poll the layout, tooltip, and icon are rebuilt; when they change the
``LayoutUpdated`` and ``PropertiesChanged`` signals are emitted so the tray
client re-fetches. The menu re-fetches fresh data on every open (``AboutToShow``
returns ``True``), so nothing shown is stale.

Implemented with dbus-next (pure-Python D-Bus, GLib-integrated). dbus-next
marshals the exact SNI wire types (a(iiay) IconPixmap, (sassas) ToolTip,
recursive (ia{sv}av) menu layout) correctly, which the C dbus-python binding
cannot do inside an a{sv} Properties.GetAll reply.
"""

import json
import os
import signal
import subprocess
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

# The "Reconnect" action shells out to this command (the smart connect flow in
# bluetooth.nix: ordering + flock + notification). Overridable at runtime.
CONNECT_CMD = os.environ.get("LIBREPODS_CONNECT_CMD", "bt-connect-headphones")

POLL_SECONDS = 5
# Below this aggregate battery level the icon/Status raise attention.
LOW_BATTERY_PCT = 20
# Retained for API stability; freshness windows now live in the WRITER (the
# daemon owns merge/freshness/source-picking), so the reader no longer applies
# a staleness window.
ACTIVE_SECONDS = 600
# Two pods that charge together should stay close; a difference at or above
# this signals a desync (poor seating / one pod not charging) -> red icon.
DESYNC_PCT = 15

# Icon rendering: 2x scale for HiDPI crispness.
ICON_SCALE = 2
ICON_SIZE = 24 * ICON_SCALE

# Menu ids. Root -> [device lines..., separator, reconnect, quit]. Device i
# (0-based, most recently seen first) owns DEVICE_ID_BASE + i*STRIDE.
MENU_ID_ROOT = 0
MENU_ID_SEPARATOR = 1
MENU_ID_RECONNECT = 2
MENU_ID_QUIT = 3
MENU_ID_NO_DEVICES = 4
MENU_ID_LAST_BEACON = 5
DEVICE_ID_BASE = 100
DEVICE_ID_STRIDE = 10

# Visual language: flat last-known state -> emoji (scannable in a plain-text
# menu). The writer owns state derivation; we only map it to a glyph.
STATE_EMOJI = {
    "connected": "\U0001f3a7",  # 🎧
    "out_of_case": "\U0001f4e1",  # 📡
    "music": "\U0001f3b5",  # 🎵
    "call": "\U0001f4de",  # 📞
    "ringing": "\U0001f514",  # 🔔
    "hanging_up": "\U0001f4f5",  # 📵
}
# The set of valid flat-schema state values (keys of the emoji map).
STATE_VALUES = set(STATE_EMOJI)
DEVICE_EMOJI = "\U0001f3a7"  # 🎧
CHARGE = "\u26a1"  # ⚡
EN_DASH = "\u2013"  # –
RECONNECT_EMOJI = "\U0001f50c"  # 🔌
QUIT_EMOJI = "\u23fb"  # ⏻


# ---------------------------------------------------------------------------
# State model (dumb renderer — the file already holds merged last-known values)
# ---------------------------------------------------------------------------


def load_state() -> dict:
    """Read the flat per-MAC last-known records and normalize each one.

    The writer owns the merge; we just fold each record to the flat schema so
    a legacy (pre-flat) record still displays. Non-dict values are skipped.
    """
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            return {
                mac: normalize(entry)
                for mac, entry in data.items()
                if isinstance(entry, dict)
            }
    except (OSError, ValueError):
        pass
    return {}


def _pct(v):
    """Coerce a battery value to an int 0-100, else None (never a bad read)."""
    if isinstance(v, (int, float)) and 0 <= v <= 100:
        return int(round(v))
    return None


def normalize(entry: dict) -> dict:
    """Fold a (possibly legacy) record into the flat last-known schema.

    The writer (daemon) owns all merge/freshness/source-picking logic; this
    defensive reader-side fold lets a LEGACY record (an ``aacp`` sub-object +
    coarse PPM fields) still display. A no-op on records already in the new
    format. Returns a dict with exactly the 13 flat-schema keys.
    """
    if not isinstance(entry, dict):
        entry = {}
    raw_aacp = entry.get("aacp")
    aacp = raw_aacp if isinstance(raw_aacp, dict) else {}
    has_aacp = isinstance(raw_aacp, dict)

    # model: top-level, default "AirPods".
    model = entry.get("model") or "AirPods"

    # state: explicit top-level state (one of the 6) wins; else an audio
    # connection_state; else advertising => out_of_case; else an aacp
    # sub-object => connected; else out_of_case.
    state = entry.get("state")
    if state not in STATE_VALUES:
        conn = entry.get("connection_state")
        if conn in ("music", "call", "ringing", "hanging_up"):
            state = conn
        elif entry.get("advertising"):
            state = "out_of_case"
        elif has_aacp:
            state = "connected"
        else:
            state = "out_of_case"

    # left/right: top-level (if not null) else aacp, else null.
    def pick(key):
        v = entry.get(key)
        return v if v is not None else aacp.get(key)

    left = _pct(pick("left"))
    right = _pct(pick("right"))

    # case: top-level (if not null) else aacp.case ONLY while the case is
    # connected, else null. (Filters the AACP case:0/case_connected:false
    # sentinel; the writer owns that protection too.)
    case_src = entry.get("case")
    if case_src is None and aacp.get("case_connected"):
        case_src = aacp.get("case")
    case = _pct(case_src)

    def flag(key):
        v = entry.get(key)
        return bool(v) if v is not None else False

    # last_seen: top-level else last_change else 0.
    ls = entry.get("last_seen")
    if not isinstance(ls, (int, float)):
        ls = entry.get("last_change")
    if not isinstance(ls, (int, float)):
        ls = 0

    return {
        "model": model,
        "state": state,
        "left": left,
        "right": right,
        "case": case,
        "charging_left": flag("charging_left"),
        "charging_right": flag("charging_right"),
        "charging_case": flag("charging_case"),
        "in_ear_left": flag("in_ear_left"),
        "in_ear_right": flag("in_ear_right"),
        "in_case": flag("in_case"),
        "lid_open": flag("lid_open"),
        "last_seen": ls,
    }


def _age_str(ts) -> str:
    """Human-readable age of a timestamp: 'just now', '42s ago', '3m ago',
    '2h ago', '5d ago'."""
    if not isinstance(ts, (int, float)) or ts <= 0:
        return "n/a"
    age = max(0, int(time.time() - ts))
    if age < 5:
        return "just now"
    if age < 60:
        return f"{age}s ago"
    if age < 3600:
        return f"{age // 60}m ago"
    if age < 86400:
        return f"{age // 3600}h ago"
    return f"{age // 86400}d ago"


def _battery_str(rec: dict) -> str:
    """Compact 'L85 R82⚡ C97' (nulls as an en dash); reads the flat record
    directly — no source picking (the writer owns the merge)."""

    def p(v):
        return EN_DASH if v is None else str(v)

    l, r, c = rec.get("left"), rec.get("right"), rec.get("case")
    cl = CHARGE if rec.get("charging_left") else ""
    cc = CHARGE if rec.get("charging_case") else ""
    return f"L{p(l)} R{p(r)}{cl} C{p(c)}{cc}"


def _state_emoji(state: str) -> str:
    """Map a flat state to its emoji (🎧 fallback for unknown)."""
    return STATE_EMOJI.get(state, DEVICE_EMOJI)


# ---------------------------------------------------------------------------
# Menu layout (flat — no submenu drill)
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


def _device_line(mac: str, rec: dict) -> str:
    """One scannable line:
    '🎧 AirPods Pro 2 · MAC · 🎧 connected · L85 R82⚡ C97 · 42s ago'."""
    model = rec.get("model") or "AirPods"
    state = rec.get("state") or "out_of_case"
    emoji = _state_emoji(state)
    return (
        f"{DEVICE_EMOJI} {model} · {mac} · "
        f"{emoji} {state} · {_battery_str(rec)} · {_age_str(rec.get('last_seen'))}"
    )


def _sorted_devices(pairs: dict):
    """Devices ordered most-recently-seen first (max last_seen), dicts only."""

    def sort_key(mac):
        e = pairs[mac]
        ls = e.get("last_seen") if isinstance(e, dict) else None
        return ls if isinstance(ls, (int, float)) else 0

    return [
        (mac, e)
        for mac, e in sorted(
            pairs.items(), key=lambda kv: sort_key(kv[0]), reverse=True
        )
        if isinstance(e, dict)
    ]


def _beacon_label(pairs: dict) -> str:
    """Footer line: most recent last_seen across all MACs (proves the daemon
    is alive and checking in)."""
    last_beacon = _last_beacon_activity(pairs)
    return (
        f"\u23F1 last beacon {_age_str(last_beacon)}"
        if last_beacon
        else "\u23F1 no beacon activity"
    )


def build_menu_layout(pairs: dict) -> dict:
    """Build the flat dbusmenu tree: {menu_id: (props, [child_ids])}.

    Devices are ordered most-recently-seen first (max last_seen) and labelled
    by model + MAC. Each device is a single disabled (informational) line; the
    only enabled actions are Reconnect and Quit.
    """
    devices = _sorted_devices(pairs)
    beacon_label = _beacon_label(pairs)

    layout = {
        MENU_ID_SEPARATOR: (_separator(), []),
        MENU_ID_RECONNECT: (_props(f"{RECONNECT_EMOJI} Reconnect AirPods"), []),
        MENU_ID_QUIT: (_props(f"{QUIT_EMOJI} Quit"), []),
        MENU_ID_LAST_BEACON: (_props(beacon_label, enabled=False), []),
    }

    if not devices:
        layout[MENU_ID_ROOT] = (
            _props("", display="none"),
            [
                MENU_ID_NO_DEVICES,
                MENU_ID_LAST_BEACON,
                MENU_ID_SEPARATOR,
                MENU_ID_RECONNECT,
                MENU_ID_QUIT,
            ],
        )
        layout[MENU_ID_NO_DEVICES] = (_props("No devices", enabled=False), [])
        return layout

    device_ids = []
    for i, (mac, e) in enumerate(devices):
        base = DEVICE_ID_BASE + i * DEVICE_ID_STRIDE
        device_ids.append(base)
        layout[base] = (_props(_device_line(mac, e), enabled=False), [])

    layout[MENU_ID_ROOT] = (
        _props("", display="none"),
        device_ids
        + [MENU_ID_LAST_BEACON, MENU_ID_SEPARATOR, MENU_ID_RECONNECT, MENU_ID_QUIT],
    )
    return layout


# ---------------------------------------------------------------------------
# Hover tooltip (multi-line, no interaction)
# ---------------------------------------------------------------------------


def _device_detail(mac: str, rec: dict) -> str:
    """Detailed line: '🎧 connected · in-ear L/R · case open · L85 R82⚡ C97 · 42s ago'."""
    state = rec.get("state") or "out_of_case"
    emoji = _state_emoji(state)

    ear = [s for s, k in (("L", "in_ear_left"), ("R", "in_ear_right")) if rec.get(k)]
    ear_s = "in-ear " + "/".join(ear) if ear else "out-of-ear"

    lid = rec.get("lid_open")
    lid_s = "case open" if lid else ("case closed" if lid is False else "case ?")

    parts = [
        f"{emoji} {state}",
        ear_s,
        lid_s,
        _battery_str(rec),
        _age_str(rec.get("last_seen")),
    ]
    if rec.get("in_case"):
        parts.insert(1, "in case")
    return " · ".join(parts)


def build_tooltip(pairs: dict) -> list:
    """Multi-line hover text: one two-line block per device (most recent first)."""
    devices = _sorted_devices(pairs)

    if not devices:
        return ["No AirPods detected"]

    lines = []
    for mac, e in devices:
        model = e.get("model") or "AirPods"
        lines.append(f"{model} · {mac}")
        lines.append("  " + _device_detail(mac, e))
    lines.append(_beacon_label(pairs))
    return lines


def _tooltip_struct(lines: list, main_text: str = "AirPods") -> list:
    """(sassas): [icon_name, lines, main_text, extra_lines] (dbus-next)."""
    return ["", lines, main_text, []]


# ---------------------------------------------------------------------------
# Icon rendering (state-aware)
# ---------------------------------------------------------------------------


def _last_beacon_activity(pairs: dict) -> float:
    """Most recent last_seen across ALL MACs (0 if none). A recent value proves
    the daemon is alive and checking in."""
    best = 0
    for e in pairs.values():
        if isinstance(e, dict):
            ls = e.get("last_seen")
            if isinstance(ls, (int, float)) and ls > 0:
                best = max(best, ls)
    return best


def _aggregate(pairs: dict):
    """Return (no_data, desync, bucket) for the icon + SNI Status.

    The tray is a dumb renderer: the file already holds the merged last-known
    values, so we pick the most-recently-seen MAC (max last_seen) and read its
    left/right directly.
      * no_data — no records at all, or the chosen record has both left and
                  right null (greys the icon).
      * desync  — abs(left - right) >= DESYNC_PCT (nulls treated as 0).
      * bucket  — min(left, right) // 10 (nulls as 0); the coarse 10%-stepped
                  level the icon bar is drawn at.
    """
    best_mac = None
    best_ts = 0
    for mac, e in pairs.items():
        if not isinstance(e, dict):
            continue
        ls = e.get("last_seen")
        if isinstance(ls, (int, float)) and ls > 0 and ls > best_ts:
            best_ts = ls
            best_mac = mac
    if best_mac is None:
        return True, False, None
    rec = pairs[best_mac]
    l = rec.get("left")
    r = rec.get("right")
    if l is None and r is None:
        return True, False, None
    lv = l if l is not None else 0
    rv = r if r is not None else 0
    level = min(lv, rv)
    desync = abs(lv - rv) >= DESYNC_PCT
    return False, desync, level // 10


def _palette(level, no_data, desync):
    """(fill, stroke, bar_color) for the glyph + battery bar."""
    if no_data:
        return (150, 150, 150, 255), (90, 90, 90, 255), (120, 120, 120, 255)
    if desync or (level is not None and level < LOW_BATTERY_PCT):
        return (235, 235, 235, 255), (25, 25, 25, 255), (230, 80, 80, 255)
    bar = (80, 200, 120, 255) if (level or 0) >= 50 else (255, 196, 0, 255)
    return (235, 235, 235, 255), (25, 25, 25, 255), bar


def render_icon(level, no_data, desync):
    """Render the AirPod icon (tinted by state + a battery bar) to ARGB32 BE.

    A single pod silhouette (round bud + stem) with a thin battery bar along
    the bottom edge. The bar is the worst of the two pods (unified), coloured
    by level — but red when desynced or low. Pass a *bucketed* level (multiple
    of 10) so the bar only moves in 10% steps (no 'spazzing'). Greyed only
    when no_data.
    """
    fill, stroke, bar = _palette(level, no_data, desync)

    img = Image.new("RGBA", (ICON_SIZE, ICON_SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Battery bar along the bottom edge (width proportional to level).
    if level is not None:
        maxw = ICON_SIZE - 8
        w = max(2, int(maxw * level / 100))
        d.rounded_rectangle(
            [4, ICON_SIZE - 4, 4 + w, ICON_SIZE - 1], radius=2, fill=bar
        )

    # Stem first (rounded bottom); the head fill is drawn over its top so the
    # junction is seamless. Stem: x 19..29 (width 10), y 10..40.
    d.rounded_rectangle(
        [19, 10, 29, 40],
        radius=5,
        fill=fill,
        outline=stroke,
        width=2,
    )
    # Head: circle centred at (24,15), r=11 -> bbox [13,4,35,26]. Its fill
    # covers the stem's top. Then only the exposed arc of the head's outline
    # (the bottom of the circle is hidden inside the stem).
    d.ellipse([13, 4, 35, 26], fill=fill)
    d.arc([13, 4, 35, 26], start=117, end=423, fill=stroke, width=2)

    raw = img.convert("RGBA").tobytes()  # R G B A per pixel
    out = bytearray()
    for i in range(0, len(raw), 4):
        out += bytes((raw[i + 3], raw[i], raw[i + 1], raw[i + 2]))  # A R G B
    return (ICON_SIZE, ICON_SIZE, bytes(out))


def _pixmap_list(w: int, h: int, data: bytes) -> list:
    """a(iiay): a list of [width, height, argb_bytes] structs (dbus-next)."""
    return [[w, h, data]]


# ---------------------------------------------------------------------------
# SNI service (dbus-next)
# ---------------------------------------------------------------------------


class SNI(ServiceInterface):
    """org.kde.StatusNotifierItem.

    dbus-next auto-exports the org.freedesktop.DBus.Properties interface
    (Get/GetAll/Set) for the @dbus_property members, so the a{sv} GetAll
    reply is marshalled by dbus-next's pure-Python code (which handles the
    a(iiay) and (sassas) types that the C dbus-python binding cannot).

    IconPixmap, ToolTip, and Status are *dynamic*: they read the current
    values off the tray, and the tray emits PropertiesChanged when they
    change so Plasma re-reads them (live icon + hover tooltip).
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
        # SNI Status: "Active" | "Passive" | "NeedsAttention".
        return self._tray.sni_status

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
        # right-click trigger does not fire for third-party SNI items, so the
        # menu never appeared. With true the menu shows on click (and
        # right-click still works), which is where the actions live.
        return True

    @dbus_property(PropertyAccess.READ)
    def Menu(self) -> "o":
        # Object path of the dbusmenu that the client shows on click. The Menu
        # service is exported at the same object path as the SNI item.
        return OBJECT_PATH

    @dbus_property(PropertyAccess.READ)
    def ToolTip(self) -> "(sassas)":
        return self._tray.tooltip_struct

    # -- SNI methods (no-ops; KDE uses them for click/scroll) --------------
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
        # activation token to the item. This tray has no application window to
        # activate, so accepting and ignoring the token is sufficient.
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
        self, menu_id: int, recursion_depth: int, property_names: list
    ) -> list:
        """Build one recursive DBusMenuLayoutItem: (ia{sv}av).

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
                child = self._layout_item(child_id, next_depth, property_names)
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
        layout = self._layout_item(parent_id, recursion_depth, property_names)
        return [self._tray.menu_revision, layout]

    # ------------------------------------------------------------------
    # AboutToShow
    # ------------------------------------------------------------------

    @method()
    def AboutToShow(self, menu_id: "i") -> "b":
        """Tell the client to re-fetch the layout before showing it.

        The tray rebuilds its layout on every poll, so always report that the
        menu may have changed; the client then calls GetLayout and gets fresh
        data (this is what makes the menu auto-refresh instead of showing
        stale ages).
        """
        return True

    # ------------------------------------------------------------------
    # Group/property access
    # ------------------------------------------------------------------

    @method()
    def GetGroupProperties(self, ids: "ai", property_names: "as") -> "a(ia{sv})":
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
    def GetProperty(self, menu_id: "i", property_name: "s") -> "v":
        entry = self._tray.menu_layout.get(menu_id)
        if entry is None:
            raise ValueError(f"Unknown menu id {menu_id}")
        props, _children = entry
        value = props.get(property_name)
        if value is None:
            raise ValueError(
                f"Unknown property {property_name!r} for menu id {menu_id}"
            )
        return value

    # ------------------------------------------------------------------
    # Activation/events
    # ------------------------------------------------------------------

    @method()
    def Event(self, menu_id: "i", event_id: "s", data: "v", timestamp: "u") -> None:
        if event_id != "clicked":
            return
        if menu_id == MENU_ID_QUIT:
            print("Quit requested via menu", file=sys.stderr)
            self._tray.quit()
        elif menu_id == MENU_ID_RECONNECT:
            self._tray.reconnect()

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
        self.icon_pixmap = _pixmap_list(*render_icon(None, True, False))
        self._icon_key = (True, None, False)  # (no_data, bucket, desync)
        self.tooltip_struct = _tooltip_struct(build_tooltip({}))
        self.sni_status = "Active"
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
        tooltip = _tooltip_struct(build_tooltip(pairs))
        no_data, desync, bucket = _aggregate(pairs)
        # Coarse (10%-stepped) value drives both the icon and the SNI Status,
        # so the icon only re-renders when the reading crosses a 10% boundary
        # (no per-poll 'spazzing'). Only 'no data at all' greys the icon.
        coarse = 0 if no_data else (bucket * 10)
        status = (
            "NeedsAttention"
            if (no_data or desync or coarse < LOW_BATTERY_PCT)
            else "Active"
        )

        changed = []
        if layout != self.menu_layout:
            self.menu_layout = layout
            self.menu_revision += 1
            self.menu._emit_layout_updated()
        if tooltip != self.tooltip_struct:
            self.tooltip_struct = tooltip
            changed.append("ToolTip")
        icon_key = (no_data, bucket, desync)
        if icon_key != self._icon_key:
            self._icon_key = icon_key
            self.icon_pixmap = _pixmap_list(*render_icon(coarse, no_data, desync))
            changed.append("IconPixmap")
        if status != self.sni_status:
            self.sni_status = status
            changed.append("Status")

        # Tell Plasma to re-read the SNI properties that changed (live icon +
        # hover tooltip). dbus-next marshals the a(iiay)/(sassas)/s types.
        if changed:
            values = {
                "ToolTip": self.tooltip_struct,
                "IconPixmap": self.icon_pixmap,
                "Status": self.sni_status,
            }
            self.sni.emit_properties_changed({k: values[k] for k in changed})

        # Retry watcher registration until plasmashell's StatusNotifierWatcher
        # is up (it may lag the service at session start).
        if not self._registered:
            self.register_with_watcher()
        return True

    # -- actions ------------------------------------------------------------
    def reconnect(self):
        """Trigger the connect flow (non-blocking) from the menu's Reconnect."""
        try:
            subprocess.Popen(
                [CONNECT_CMD],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            print(f"Reconnect requested: {CONNECT_CMD}", file=sys.stderr)
        except Exception as e:  # noqa: BLE001
            print(f"Reconnect failed ({CONNECT_CMD}): {e}", file=sys.stderr)

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
    tray.refresh()  # initial state + menu layout + icon + tooltip

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