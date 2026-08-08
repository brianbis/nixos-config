import json
import math
import os
import subprocess
import sys
import time

from core import error, load_layout, resolve_physical

KSCREEN = os.environ["KSCREEN"]
DISCOVERY = os.environ["DISCOVERY"]
LAYOUT_PATH = os.environ["LAYOUT_PATH"]

layout = load_layout(LAYOUT_PATH)
physical = resolve_physical(layout, DISCOVERY)

# Autostart can fire before the KScreen session is fully up. Retry
# quietly rather than failing (or spamming stderr) on a one-off race.
kscreen = None
for attempt in range(15):
    try:
        result = subprocess.run(
            [KSCREEN, "--json"],
            check=True,
            capture_output=True,
            text=True,
        )
        kscreen = json.loads(result.stdout)
        break
    except (
        FileNotFoundError,
        subprocess.CalledProcessError,
        json.JSONDecodeError,
    ):
        if attempt == 14:
            error("KScreen session was not available")
        time.sleep(1)

outputs = kscreen.get("outputs")
if not isinstance(outputs, list):
    error("KScreen JSON does not contain an output list")


def resolve_output(desired, display):
    matches = [o for o in outputs if o.get("name") == display["connector"]]
    if not matches:
        error(
            f"could not resolve KScreen output for {desired['model']} "
            f"(connector {display['connector']})"
        )
    if len(matches) != 1:
        error(
            f"KScreen connector {display['connector']} is ambiguous "
            f"for {desired['model']}"
        )
    return matches[0]


def resolve_mode(desired, output):
    w = desired["mode"]["width"]
    h = desired["mode"]["height"]
    r = desired["mode"]["refresh"]
    matches = [
        m for m in output.get("modes", [])
        if m.get("size", {}).get("width") == w
        and m.get("size", {}).get("height") == h
        and m.get("refreshRate") is not None
        and math.isclose(float(m["refreshRate"]), float(r), abs_tol=0.5)
    ]
    if not matches:
        error(f"could not find {w}x{h}@{r} mode for {desired['model']}")
    if len(matches) > 1:
        error(f"multiple {w}x{h}@{r} modes found for {desired['model']}")
    return matches[0]["id"]


# Resolve everything before building the command: if one monitor is
# missing or ambiguous, nothing gets applied.
resolved = []
for name, desired in layout.items():
    output = resolve_output(desired, physical[name])
    mode_id = resolve_mode(desired, output)
    resolved.append((name, desired, physical[name], output, mode_id))

command = [KSCREEN]
for name, desired, display, output, mode_id in resolved:
    oid = output["id"]
    pos = desired["position"]
    command += [
        f"output.{oid}.mode.{mode_id}",
        f"output.{oid}.position.{pos['x']},{pos['y']}",
    ]

print("Applying monitor layout:", file=sys.stderr)
for name, desired, display, output, mode_id in resolved:
    pos = desired["position"]
    print(
        f"  {name}: {desired['manufacturer']} {desired['model']} "
        f"{desired['serial']!r} -> connector {display['connector']}, "
        f"output {output['id']}, mode {mode_id}, "
        f"position {pos['x']},{pos['y']}",
        file=sys.stderr,
    )

try:
    subprocess.run(command, check=True)
except subprocess.CalledProcessError as exc:
    error(f"kscreen-doctor failed with exit status {exc.returncode}")
