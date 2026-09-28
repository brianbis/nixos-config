#!/usr/bin/env python3
"""Re-pin the dsh npm-closure data after the dsh flake input moves.

The dsh package (package.nix) fetches its npm production closure as one
fixed-output derivation per registry tarball (fetchurl); each sha256 lives
in deps-sha256.json (url -> sha256). This script regenerates the npm-side
data files from the pinned source tree:

1. Rewrite the `workspace:` dependencies in apps/cli/package.json to
   concrete versions (pnpm pack does the same rewrite at publish time; the
   npm lockfile must be generated from the rewritten manifest, since npm
   does not understand the workspace: protocol).
2. `npm install --package-lock-only` -> package-lock.json (the npm closure
   pin: exact placement + per-package sha512 integrity), stamped with
   _meta.srcRev = the dsh source rev it was generated from (package.nix
   asserts it matches the pinned input, so a stale re-pin fails loudly).
3. Download the closure tarballs (cached under $XDG_CACHE_HOME/dsh-deps),
   verify each sha512 against the lock's integrity, and record the sha256
   in deps-sha256.json.

The pnpm side is NOT pinned by data files anymore: tarball.nix pins its
store with a single fetchPnpmDeps `hash` and reads the source tree's own
pnpm-lock.yaml (see tarball.nix header for the hash-refresh flow).

Usage: update-deps.py <src-dir> <src-rev>
  <src-dir>   the pinned dsh source tree (e.g. the store path of the
              `dsh-src` flake output).
  <src-rev>   the full 40-char commit SHA of that tree (the flake.lock dsh
              rev), stamped into package-lock.json.

Stdlib only on purpose: the justfile runs this inside `nix shell
nixpkgs#nodejs nixpkgs#python3`, a minimal environment.
"""
import concurrent.futures
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from typing import NoReturn


def die(msg) -> NoReturn:
    sys.exit(f"update-deps: {msg}")


def workspace_globs(src):
    """The `packages:` globs from pnpm-workspace.yaml (simple list)."""
    text = open(os.path.join(src, "pnpm-workspace.yaml")).read()
    globs = []
    in_packages = False
    for line in text.splitlines():
        if re.match(r"^packages:\s*(#.*)?$", line):
            in_packages = True
            continue
        if in_packages:
            m = re.match(r"^\s+-\s+(\S+)", line)
            if m:
                globs.append(m.group(1).strip("'\""))
            elif line.strip() and not line.startswith(" "):
                break  # next top-level key
    if not globs:
        die("no packages: globs found in pnpm-workspace.yaml")
    return globs


def workspace_versions(src):
    """name -> version for every workspace member."""
    versions = {}
    for pattern in workspace_globs(src):
        for d in sorted(glob.glob(os.path.join(src, pattern))):
            pj = os.path.join(d, "package.json")
            if os.path.isfile(pj):
                with open(pj) as f:
                    meta = json.load(f)
                if meta.get("name"):
                    versions[meta["name"]] = meta.get("version")
    return versions


def rewrite_manifest(pj_path, versions):
    """Return the package.json with workspace: deps rewritten in place."""
    with open(pj_path) as f:
        meta = json.load(f)
    for section in ("dependencies", "devDependencies",
                    "optionalDependencies", "peerDependencies"):
        deps = meta.get(section) or {}
        for name, value in list(deps.items()):
            if not isinstance(value, str) or not value.startswith("workspace:"):
                continue
            if name not in versions:
                die(f"{name}: workspace: dep not found in workspace map "
                    f"(have {len(versions)} members)")
            rest = value[len("workspace:"):]
            version = versions[name]
            if rest in ("", "*"):
                deps[name] = version
            elif rest[0] in "~^><=":
                deps[name] = rest + version
            else:
                deps[name] = rest
    return meta


def npm_lockfile(src, out_lock):
    """Generate package-lock.json from the rewritten apps/cli manifest.

    The working directory is always cleaned up, so a failed run leaves no
    state behind (an earlier version leaked .lockfile-tmp/ on npm failure).
    """
    meta = rewrite_manifest(os.path.join(src, "apps", "cli", "package.json"),
                            workspace_versions(src))
    tmp = os.path.join(os.path.dirname(os.path.abspath(out_lock)),
                       ".lockfile-tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    try:
        os.makedirs(tmp)
        with open(os.path.join(tmp, "package.json"), "w") as f:
            json.dump(meta, f, indent=2)
        npm = shutil.which("npm")
        if not npm:
            die("npm not on PATH")
        r = subprocess.run([npm, "install", "--package-lock-only",
                            "--ignore-scripts",
                            "--registry=https://registry.npmjs.org"],
                           cwd=tmp, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(
                f"npm install --package-lock-only failed:\n{r.stdout}\n{r.stderr}")
        shutil.move(os.path.join(tmp, "package-lock.json"), out_lock)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def linux_applicable(v):
    if v.get("os") and "linux" not in v["os"]:
        return False
    if v.get("cpu") and "x64" not in v["cpu"]:
        return False
    return True


def npm_entries(lock):
    """(url, integrity) for the production linux-x64 npm closure."""
    out = []
    for key, e in lock.get("packages", {}).items():
        if not key or e.get("dev") or not linux_applicable(e):
            continue
        if not e.get("resolved") or not e.get("integrity"):
            die(f"npm lock entry {key!r} has no resolved/integrity")
        out.append((e["resolved"], e["integrity"]))
    return out


def fetch(url, integrity, cache_dir):
    """Download url (cached), verify sha512 integrity, return sha256 hex."""
    digest = hashlib.sha1(url.encode()).hexdigest()
    path = os.path.join(cache_dir, digest + ".tgz")
    if not os.path.isfile(path):
        req = urllib.request.Request(url, headers={"User-Agent": "dsh-update-deps"})
        with urllib.request.urlopen(req) as r, open(path + ".part", "wb") as f:
            shutil.copyfileobj(r, f)
        os.replace(path + ".part", path)
    data = open(path, "rb").read()
    import base64
    algo, b64 = integrity.split("-", 1)
    if algo != "sha512":
        die(f"unsupported integrity algo {algo!r} for {url}")
    if hashlib.sha512(data).digest() != base64.b64decode(b64):
        die(f"sha512 mismatch for {url} (lock integrity {integrity})")
    return hashlib.sha256(data).hexdigest()


def main():
    if len(sys.argv) != 3:
        die(f"usage: {sys.argv[0]} <src-dir> <src-rev>")
    src = os.path.abspath(sys.argv[1])
    rev = sys.argv[2].strip()
    if not re.fullmatch(r"[0-9a-f]{40}", rev):
        die(f"src-rev must be a full 40-char sha, got {rev!r}")
    here = os.path.dirname(os.path.abspath(__file__))
    out_lock = os.path.join(here, "package-lock.json")
    out_sha = os.path.join(here, "deps-sha256.json")
    cache_dir = os.path.join(os.environ.get("XDG_CACHE_HOME",
                                            os.path.expanduser("~/.cache")),
                             "dsh-deps")
    os.makedirs(cache_dir, exist_ok=True)

    npm_lockfile(src, out_lock)
    with open(out_lock) as f:
        lock = json.load(f)

    # Stamp the source rev the closure was resolved against (package.nix
    # asserts it equals the pinned dsh input's rev at eval time).
    lock["_meta"] = {"srcRev": rev}
    tmp = out_lock + ".tmp"
    with open(tmp, "w") as f:
        json.dump(lock, f, indent=2)
        f.write("\n")
    os.replace(tmp, out_lock)
    print(f"wrote {out_lock} (srcRev {rev})")

    wanted = {}
    for url, integrity in npm_entries(lock):
        if url in wanted and wanted[url] != integrity:
            die(f"conflicting integrity for {url}: {wanted[url]} vs {integrity}")
        wanted[url] = integrity
    print(f"{len(wanted)} unique tarballs in the npm closure")

    existing = {}
    if os.path.isfile(out_sha):
        with open(out_sha) as f:
            existing = json.load(f)

    to_fetch = [u for u in wanted if u not in existing]
    print(f"{len(to_fetch)} to download, {len(wanted) - len(to_fetch)} cached")
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        futures = {pool.submit(fetch, u, wanted[u], cache_dir): u
                   for u in to_fetch}
        for fut in concurrent.futures.as_completed(futures):
            u = futures[fut]
            existing[u] = fut.result()
            print(f"  {u.rsplit('/', 1)[-1]}")

    result = {u: existing[u] for u in sorted(wanted)}
    tmp = out_sha + ".tmp"
    with open(tmp, "w") as f:
        json.dump(result, f, indent=1)
        f.write("\n")
    os.replace(tmp, out_sha)
    print(f"wrote {out_sha} ({len(result)} entries)")


if __name__ == "__main__":
    main()