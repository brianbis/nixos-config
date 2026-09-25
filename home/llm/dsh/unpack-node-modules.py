#!/usr/bin/env python3
"""Unpack fetched npm tarballs into a node_modules tree.

Mirrors `npm ci --ignore-scripts` + `npm prune --omit=dev` for linux-x64
without npm's JS tree builder, which is memory-pathological on this tree:
npm ci's heap grows linearly with the V8 limit (57 min to OOM at 4 GiB,
111 min at 8 GiB), so each dsh re-pin cost 2-4 h and risked OOM.

Placement follows the lockfile's `packages` keys (node_modules/... paths);
each tarball is a fetchurl fixed-output derivation already verified against
its sha256 (deps-sha256.json, cross-checked against the lock's sha512
integrity by update-deps.py). Entries marked `dev: true` or restricted to
other os/cpu were filtered out at evaluation time (mirrors
`npm prune --omit=dev` and npm's optional-dep filtering).
"""
import json
import os
import sys
import tarfile


def die(msg):
    sys.exit(f"unpack-node-modules: {msg}")


def main():
    out = os.environ["OUT"]
    # The entries JSON is passed as a file path (writeText store path):
    # inlining it as an env var risks exceeding MAX_ARG_STRLEN.
    with open(os.environ["ENTRIES_FILE"]) as f:
        entries = json.load(f)

    count = 0
    for entry in entries:
        key, tarball = entry["key"], entry["tarball"]
        if not os.path.isfile(tarball):
            die(f"missing tarball for {key!r}: {tarball}")
        parent, name = os.path.split(key)
        dest_dir = os.path.join(out, parent)
        os.makedirs(dest_dir, exist_ok=True)
        # Scoped packages (@scope/name) keep the scope dir in the path, and
        # their package.json `name` is the full @scope/name, not just the
        # last segment. Non-scoped packages use the last segment only.
        scope = os.path.basename(parent)
        expected_name = f"{scope}/{name}" if scope.startswith("@") else name
        # npm tarballs carry a single top-level dir, named `package/` for
        # most packages but the package name for some (e.g. @types/*).
        # Extract to a temp subdir, locate that dir, verify the name, then
        # move it into place. The `data` filter strips setuid bits and
        # resolves links (reproducible).
        import tempfile
        tmp = tempfile.mkdtemp(dir=dest_dir)
        try:
            with tarfile.open(tarball) as t:
                t.extractall(tmp, filter="data")
            tops = os.listdir(tmp)
            if len(tops) != 1 or not os.path.isdir(os.path.join(tmp, tops[0])):
                die(f"tarball for {key!r} has {len(tops)} top-level entries: {tops}")
            with open(os.path.join(tmp, tops[0], "package.json")) as f:
                if json.load(f).get("name") != expected_name:
                    die(f"tarball for {key!r} has unexpected package name")
            os.replace(os.path.join(tmp, tops[0]), os.path.join(dest_dir, name))
        finally:
            if os.path.isdir(tmp):
                import shutil
                shutil.rmtree(tmp)
        count += 1

    print(f"unpacked {count} packages into {out}")


if __name__ == "__main__":
    main()
