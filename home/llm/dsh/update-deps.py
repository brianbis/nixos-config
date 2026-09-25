#!/usr/bin/env python3
"""Re-pin the dsh npm-closure data after `nix flake update dsh`.

The dsh package (package.nix) and the dsh tarball (tarball.nix) fetch their
registry tarballs with per-package fixed-output derivations whose sha256
hashes live in deps-sha256.json (url -> sha256). This script regenerates
both data files from the pinned source tree:

1. Rewrite the `workspace:` dependencies in apps/cli/package.json to
   concrete versions (pnpm pack does the same rewrite at publish time; the
   npm lockfile must be generated from the rewritten manifest, since npm
   does not understand the workspace: protocol).
2. `npm install --package-lock-only` -> package-lock.json (the npm closure
   pin: exact placement + per-package sha512 integrity).
3. Collect the union of tarballs across the npm lock (production,
   linux-x64) and the source's pnpm-lock.yaml (linux-x64-applicable),
   download any missing tarballs (cached under $XDG_CACHE_HOME/dsh-deps),
   verify each sha512 against the lock's integrity, and record the sha256.

Usage: update-deps.py <src-dir> <pnpm-lock.json>
  <src-dir>          the pinned dsh source tree (e.g. the store path of the
                     `dsh-src` flake output).
  <pnpm-lock.json>   the source's pnpm-lock.yaml converted to JSON (the
                     justfile does this with yq), so this script needs only
                     the python stdlib.

The script also writes home/llm/dsh/pnpm-lock.json (the same JSON plus a
_meta.pnpmLockYamlSha256 of the source's pnpm-lock.yaml) — tarball.nix
reads it at evaluation time (this Nix has no builtins.fromYAML) and asserts
the hash matches the pinned source, so a stale re-pin fails loudly.

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
    """Generate package-lock.json from the rewritten apps/cli manifest."""
    meta = rewrite_manifest(os.path.join(src, "apps", "cli", "package.json"),
                            workspace_versions(src))
    tmp = os.path.join(os.path.dirname(os.path.abspath(out_lock)),
                       ".lockfile-tmp")
    shutil.rmtree(tmp, ignore_errors=True)
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
        die(f"npm install --package-lock-only failed:\n{r.stdout}\n{r.stderr}")
    shutil.move(os.path.join(tmp, "package-lock.json"), out_lock)
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


def pnpm_entries(pnpm_lock):
    """(url, integrity) for the linux-x64-applicable pnpm lock entries."""
    out = []
    for key, e in (pnpm_lock.get("packages") or {}).items():
        if not isinstance(e, dict) or not linux_applicable(e):
            continue
        res = e.get("resolution") or {}
        integrity = res.get("integrity")
        if not integrity:
            continue  # link: / workspace entries
        if res.get("tarball"):
            url = res["tarball"]
        else:
            # name@version key (scoped names start with @)
            name, _, version = key.rpartition("@")
            base = name.rsplit("/", 1)[-1]
            url = f"https://registry.npmjs.org/{name}/-/{base}-{version}.tgz"
        out.append((url, integrity))
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
    algo, b64 = integrity.split("-", 1)
    if algo != "sha512":
        die(f"unsupported integrity algo {algo!r} for {url}")
    import base64
    if hashlib.sha512(data).digest() != base64.b64decode(b64):
        die(f"sha512 mismatch for {url} (lock integrity {integrity})")
    return hashlib.sha256(data).hexdigest()


def main():
    if len(sys.argv) != 3:
        die(f"usage: {sys.argv[0]} <src-dir> <pnpm-lock.json>")
    src = os.path.abspath(sys.argv[1])
    with open(sys.argv[2]) as f:
        pnpm_lock = json.load(f)
    here = os.path.dirname(os.path.abspath(__file__))
    out_lock = os.path.join(here, "package-lock.json")
    out_pnpm = os.path.join(here, "pnpm-lock.json")
    out_sha = os.path.join(here, "deps-sha256.json")
    cache_dir = os.path.join(os.environ.get("XDG_CACHE_HOME",
                                            os.path.expanduser("~/.cache")),
                             "dsh-deps")
    os.makedirs(cache_dir, exist_ok=True)

    npm_lockfile(src, out_lock)
    with open(out_lock) as f:
        lock = json.load(f)

    wanted = {}
    for url, integrity in npm_entries(lock) + pnpm_entries(pnpm_lock):
        if url in wanted and wanted[url] != integrity:
            die(f"conflicting integrity for {url}: {wanted[url]} vs {integrity}")
        wanted[url] = integrity
    print(f"{len(wanted)} unique tarballs across both locks")

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

    # Commit the pnpm lock as JSON (this Nix has no builtins.fromYAML),
    # stamped with the sha256 of the source pnpm-lock.yaml so tarball.nix
    # can detect staleness at eval time.
    with open(os.path.join(src, "pnpm-lock.yaml"), "rb") as f:
        yaml_sha = hashlib.sha256(f.read()).hexdigest()
    out = dict(pnpm_lock)
    out["_meta"] = {"pnpmLockYamlSha256": yaml_sha}
    tmp = out_pnpm + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, indent=1)
        f.write("\n")
    os.replace(tmp, out_pnpm)
    print(f"wrote {out_pnpm}")


if __name__ == "__main__":
    main()
