import grp
import json
import os
import pwd
import sys
import tempfile

from core import error, load_layout, resolve_physical

DISCOVERY = os.environ["DISCOVERY"]
LAYOUT_PATH = os.environ["LAYOUT_PATH"]

SDDM_HOME = "/var/lib/sddm"
CONFIG_DIR = os.path.join(SDDM_HOME, ".config")
CONFIG_FILE = os.path.join(CONFIG_DIR, "kwinoutputconfig.json")

layout = load_layout(LAYOUT_PATH)
physical = resolve_physical(layout, DISCOVERY)

if not os.path.exists(CONFIG_FILE):
    error(f"{CONFIG_FILE} does not exist")

try:
    with open(CONFIG_FILE) as f:
        config = json.load(f)
except (OSError, json.JSONDecodeError) as exc:
    error(f"could not read {CONFIG_FILE}: {exc}")

if not isinstance(config, list):
    error("KWin output configuration is not a JSON array")

outputs_block = next(
    (block for block in config if block.get("name") == "outputs"),
    None,
)
setups_block = next(
    (block for block in config if block.get("name") == "setups"),
    None,
)

if outputs_block is None:
    error("KWin configuration has no outputs block")

if setups_block is None:
    error("KWin configuration has no setups block")

outputs = outputs_block.get("data")
if not isinstance(outputs, list):
    error("KWin outputs block has no data list")


# Drop stale placeholders first and build the old-index -> new-index map
# before anything else touches output indices.
kept_outputs = []
old_to_new_index = {}

for old_index, output in enumerate(outputs):
    if output.get("connectorName", "").startswith("Unknown-"):
        continue

    old_to_new_index[old_index] = len(kept_outputs)
    kept_outputs.append(output)

outputs_block["data"] = kept_outputs


def resolve_output_index(name, display):
    matches = [
        (old_index, output)
        for old_index, output in enumerate(outputs)
        if output.get("connectorName") == display["connector"]
    ]

    if not matches:
        error(
            f"could not find KWin output for {name!r}: "
            f"{display['connector']}"
        )

    if len(matches) != 1:
        error(
            f"KWin connector {display['connector']} is ambiguous "
            f"for {name!r}"
        )

    old_index, output = matches[0]

    if old_index not in old_to_new_index:
        error(
            f"output for {name!r} was a stale Unknown-* placeholder"
        )

    return old_to_new_index[old_index], output


# Resolve everything and stage the mode changes before writing anything.
resolved = {}

for name, desired in layout.items():
    new_index, output = resolve_output_index(name, physical[name])

    output["mode"] = {
        "flags": 0,
        "height": desired["mode"]["height"],
        # KWin's persisted format expects refresh rate in mHz.
        "refreshRate": desired["mode"]["refresh"] * 1000,
        "width": desired["mode"]["width"],
    }

    resolved[name] = (new_index, output)

if len({index for index, _ in resolved.values()}) != len(resolved):
    error("multiple physical monitors resolved to the same KWin output")


desired_setup_outputs = []

# Nix attrsets are unordered, so layout may iterate in any order.
# Sort by declared position to make priority deterministic.
for name, desired in sorted(
    layout.items(),
    key=lambda item: (
        item[1]["position"]["x"],
        item[1]["position"]["y"],
    ),
):
    new_index, _ = resolved[name]
    position = desired["position"]

    desired_setup_outputs.append(
        {
            "enabled": True,
            "outputIndex": new_index,
            "position": {
                "x": position["x"],
                "y": position["y"],
            },
            "priority": len(desired_setup_outputs),
            "replicationSource": "",
        }
    )

setups_block["data"] = [
    {
        "lidClosed": False,
        "outputs": desired_setup_outputs,
    }
]


# Write atomically, then restore SDDM ownership and permissions.
sddm_uid = pwd.getpwnam("sddm").pw_uid
sddm_gid = grp.getgrnam("sddm").gr_gid

os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
os.chown(CONFIG_DIR, sddm_uid, sddm_gid)

fd, tmp = tempfile.mkstemp(
    prefix=".kwinoutputconfig.",
    dir=CONFIG_DIR,
)

try:
    with os.fdopen(fd, "w") as f:
        json.dump(config, f, indent=4)
        f.write("\n")

    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG_FILE)

    os.chown(CONFIG_FILE, sddm_uid, sddm_gid)
    os.chmod(CONFIG_FILE, 0o600)

except Exception:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise


print("Applied SDDM monitor layout:", file=sys.stderr)

for name, desired in layout.items():
    new_index, _ = resolved[name]
    position = desired["position"]
    mode = desired["mode"]

    print(
        "  "
        f"{name}: {desired['manufacturer']} {desired['model']} "
        f"{desired['serial']!r} -> connector "
        f"{physical[name]['connector']}, "
        f"output index {new_index}, "
        f"mode {mode['width']}x{mode['height']}@"
        f"{mode['refresh']}, "
        f"position {position['x']},{position['y']}",
        file=sys.stderr,
    )
