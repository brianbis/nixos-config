"""Write the declared layout into SDDM's persisted KWin output config.

Expects DISCOVERY, LAYOUT_PATH and everything in core.py to already be
defined above this point (Nix concatenates them in).

KWin's setups block references outputs by ARRAY INDEX, not by UUID or
connector name, so stale "Unknown-*" placeholder outputs (left behind
when a monitor was once connected and no longer is) have to be pruned
*before* any index is resolved — otherwise every index downstream is
wrong.
"""

import os
import pwd
import grp
import tempfile

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

outputs_block = next((b for b in config if b.get("name") == "outputs"), None)
setups_block = next((b for b in config if b.get("name") == "setups"), None)

if outputs_block is None:
    error("KWin configuration has no outputs block")
if setups_block is None:
    error("KWin configuration has no setups block")

outputs = outputs_block.get("data")
if not isinstance(outputs, list):
    error("KWin outputs block has no data list")

# Drop stale placeholders FIRST and build the old-index -> new-index
# map before anything else touches indices.
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
        (old_index, o) for old_index, o in enumerate(outputs)
        if o.get("connectorName") == display["connector"]
    ]
    if not matches:
        error(f'could not find KWin output for {name!r}: {display["connector"]}')
    if len(matches) != 1:
        error(f'KWin connector {display["connector"]} is ambiguous for {name!r}')

    old_index, output = matches[0]
    if old_index not in old_to_new_index:
        error(f"output for {name!r} was a stale Unknown-* placeholder")
    return old_to_new_index[old_index], output


# Resolve everything and stage the mode change before writing anything.
resolved = {}
for name, desired in layout.items():
    new_index, output = resolve_output_index(name, physical[name])
    output["mode"] = {
        "flags": 0,
        "height": desired["mode"]["height"],
        "refreshRate": desired["mode"]["refresh"] * 1000,  # persisted format wants mHz
        "width": desired["mode"]["width"],
    }
    resolved[name] = (new_index, output)

if len({i for i, _ in resolved.values()}) != len(resolved):
    error("multiple physical monitors resolved to the same KWin output")

desired_setup_outputs = []
for name, desired in layout.items():
    new_index, _ = resolved[name]
    pos = desired["position"]
    desired_setup_outputs.append({
        "enabled": True,
        "outputIndex": new_index,
        "position": {"x": pos["x"], "y": pos["y"]},
        "priority": len(desired_setup_outputs),
        "replicationSource": "",
    })

setups_block["data"] = [{"lidClosed": False, "outputs": desired_setup_outputs}]

# Write atomically, then restore SDDM's ownership/permissions.
sddm_uid = pwd.getpwnam("sddm").pw_uid
sddm_gid = grp.getgrnam("sddm").gr_gid

os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
os.chown(CONFIG_DIR, sddm_uid, sddm_gid)

fd, tmp = tempfile.mkstemp(prefix=".kwinoutputconfig.", dir=CONFIG_DIR)
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
    pos, mode = desired["position"], desired["mode"]
    print(
        f'  {name}: {desired["manufacturer"]} {desired["model"]} {desired["serial"]!r} '
        f'-> connector {physical[name]["connector"]}, output index {new_index}, '
        f'mode {mode["width"]}x{mode["height"]}@{mode["refresh"]}, position {pos["x"]},{pos["y"]}',
        file=sys.stderr,
    )
