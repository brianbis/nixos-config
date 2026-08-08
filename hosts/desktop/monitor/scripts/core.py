"""Shared helpers for monitor-layout backends.

Imported by the backend scripts as a real module (`from core import
...`); the Nix expression ships it in the same store directory and puts
that directory on PYTHONPATH. See monitor/default.nix.
"""

import json
import subprocess
import sys


def error(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def run_json(command):
    try:
        result = subprocess.run(
            command, check=True, capture_output=True, text=True,
        )
    except FileNotFoundError:
        error(f"command not found: {command[0]}")
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip()
        error(f"{command[0]} failed" + (f": {detail}" if detail else ""))

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        error(f"{command[0]} returned invalid JSON: {exc}")


def load_layout(path):
    """Read the declared layout from a real JSON file on disk.

    Deliberately NOT read by splicing `builtins.toJSON monitor-layout`
    into Python source as a literal — JSON's true/false/null aren't
    Python's True/False/None, so that approach breaks the moment the
    layout gains a boolean or null field. Reading it as JSON via
    json.load sidesteps that entirely.
    """
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        error(f"could not read layout at {path}: {exc}")


def strip_gpu_prefix(connector):
    """'1-DP-2' (per-GPU) -> 'DP-2' (desktop-manager) connector."""
    if connector.startswith("DP-"):
        return connector
    _, _, tail = connector.partition("-")
    if not tail.startswith("DP-"):
        error(f"unsupported DRM connector format: {connector!r}")
    return tail


def resolve_physical(layout, discovery_bin):
    """Match each declared monitor to a currently-connected physical display.

    Returns {name: {**display_discovery_fields, "connector": "DP-N"}}.

    This is backend-independent: it only knows about EDID identity and
    display-discovery's output, never about KScreen or KWin. Both
    backends call it the same way and only diverge afterwards, when
    they map a connector name onto *their own* representation of an
    output.

    Fails loudly for ALL monitors before returning, so a layout is
    never half-applied because one monitor was missing or ambiguous.
    """
    displays = run_json([discovery_bin, "--json"])
    resolved = {}

    for name, desired in layout.items():
        matches = [
            d for d in displays
            if d.get("manufacturer") == desired["manufacturer"]
            and d.get("model") == desired["model"]
        ]

        serial = desired.get("serial", "")
        if serial:
            matches = [d for d in matches if d.get("serial") == serial]

        if not matches:
            error(f"physical monitor {name!r} was not discovered")

        if len(matches) != 1:
            found = ", ".join(
                f'{m.get("connector")} {m.get("manufacturer")} '
                f'{m.get("model")} {m.get("serial")!r}'
                for m in matches
            )
            error(f"physical monitor {name!r} is ambiguous: {found}")

        display = dict(matches[0])
        display["connector"] = strip_gpu_prefix(display["connector"])
        resolved[name] = display

    return resolved
