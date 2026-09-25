#!/usr/bin/env python3
"""Assemble a pnpm v11 store (files/ + index.db) from registry tarballs.

Input: ENTRIES json [{key, url, integrity, tarball}], one per
linux-x64-applicable package in the source's pnpm-lock.yaml (the key is
the lock's `packages` key, name@version). Each tarball is a fetchurl
fixed-output derivation already verified against its sha256
(deps-sha256.json, cross-checked against the lock's sha512 integrity by
update-deps.py).

Output layout (pnpm store v11, as written by pnpm 11):
  $out/v11/files/<sha512hex[0:2]>/<sha512hex[2:]>         file contents
  $out/v11/files/<sha512hex[0:2]>/<sha512hex[2:]>-exec    executable files
  $out/v11/index.db                                        SQLite package_index

index.db: CREATE TABLE package_index (key TEXT PRIMARY KEY, data BLOB
NOT NULL) WITHOUT ROWID. key = "<integrity>\t<name>@<version>". data is
the msgpackr "records" extension of MessagePack (pnpm's store-index
format): the top-level record (slot 0x40) is
{requiresBuild, manifest, algo, files}; nested objects are record-encoded
with slots 0x41+ assigned in first-seen order; file-info records are
{checkedAt, digest, mode, size}. Symlinks are dropped, matching pnpm's
own store behavior.

The store is consumed by `pnpm install --offline --ignore-scripts
--frozen-lockfile --store-dir <this>`, which verifies the lockfile
against it.
"""
import hashlib
import json
import os
import sqlite3
import struct
import sys
import tarfile
from typing import NoReturn


def die(msg: str) -> NoReturn:
    sys.exit(f"assemble-pnpm-store: {msg}")


def package_id(key: str) -> str:
    """The store-index pkgId pnpm looks up (its tryGetPackageId).

    Registry deps key by name@version. Tarball-URL deps (name@https://...)
    key by the bare URL: pnpm strips everything up to and including the
    first '@' when the dep path contains ':'.
    """
    if "://" in key:
        at = key.find("@", 1)
        if at != -1:
            return key[at + 1:]
    return key


# ---------------------------------------------------------------------------
# Minimal MessagePack encoder with the msgpackr "records" extension.
#
# Record definition (first occurrence of a field-name tuple):
#   d4 72 <slot>  <array of field names>  <value 0> ... <value n-1>
# Record reference (later occurrences of the same tuple):
#   <slot>  <value 0> ... <value n-1>
# Slots: 0x40 + n, assigned in first-seen order. Integers in 0x40..0x7f
# are written as uint8 (0xcc) to avoid colliding with slot bytes.
#
# pnpm record-encodes JS Objects (the top-level index, the manifest, the
# file-info structs) but plain-msgpack-maps JS Maps (the `files` field).
# Map marks a dict for plain-map encoding.
# ---------------------------------------------------------------------------

class Map(dict):
    """A dict encoded as a plain MessagePack map (not a record)."""


class Encoder:
    def __init__(self):
        self.slots = {}
        self.next_slot = 0x40

    def encode(self, v) -> bytes:
        if v is None:
            return b"\xc0"
        if isinstance(v, bool):
            return b"\xc2" if v else b"\xc3"
        if isinstance(v, int):
            if 0x40 <= v <= 0x7F:
                return b"\xcc" + bytes([v])
            if 0 <= v < 0x80:
                return bytes([v])
            if v < 0x10000:
                return b"\xcd" + v.to_bytes(2, "big")
            if v < 0x100000000:
                return b"\xce" + v.to_bytes(4, "big")
            return b"\xcf" + v.to_bytes(8, "big")
        if isinstance(v, float):
            return b"\xcb" + struct.pack(">d", v)
        if isinstance(v, str):
            b = v.encode("utf-8")
            if len(b) < 32:
                return bytes([0xA0 | len(b)]) + b
            if len(b) < 256:
                return b"\xd9" + bytes([len(b)]) + b
            return b"\xda" + len(b).to_bytes(2, "big") + b
        if isinstance(v, Map):
            return self.encode_map(v)
        if isinstance(v, (list, tuple)):
            return self.encode_array(list(v))
        if isinstance(v, dict):
            return self.encode_record(v)
        die(f"unsupported value type: {type(v)!r}")

    def encode_array(self, items):
        if len(items) < 16:
            head = bytes([0x90 | len(items)])
        elif len(items) < 65536:
            head = b"\xdc" + len(items).to_bytes(2, "big")
        else:
            head = b"\xdd" + len(items).to_bytes(4, "big")
        return head + b"".join(self.encode(x) for x in items)

    def encode_map(self, d):
        if len(d) < 16:
            head = bytes([0x80 | len(d)])
        elif len(d) < 65536:
            head = b"\xde" + len(d).to_bytes(2, "big")
        else:
            head = b"\xdf" + len(d).to_bytes(4, "big")
        return head + b"".join(
            self.encode(k) + self.encode(v) for k, v in d.items())

    def encode_record(self, d):
        fields = tuple(d.keys())
        slot = self.slots.get(fields)
        if slot is None:
            slot = self.next_slot
            self.next_slot += 1
            self.slots[fields] = slot
            head = b"\xd4\x72" + bytes([slot]) + self.encode_array(list(fields))
        else:
            head = bytes([slot])
        return head + b"".join(self.encode(d[k]) for k in fields)


# Fixed timestamp (ms) for file-info checkedAt: deterministic store.
CHECKED_AT = 1700000000000.0


def main():
    out = os.environ["OUT"]
    # The entries JSON is passed as a file path (writeText store path):
    # inlining it as an env var would exceed MAX_ARG_STRLEN.
    with open(os.environ["ENTRIES_FILE"]) as f:
        entries = json.load(f)
    files_dir = os.path.join(out, "v11", "files")
    os.makedirs(files_dir, exist_ok=True)

    rows = []
    n_files = 0
    n_symlinks = 0

    for entry in entries:
        # Slot space is per-blob (each index row is encoded independently).
        enc = Encoder()
        key, tarball = entry["key"], entry["tarball"]
        if not os.path.isfile(tarball):
            die(f"missing tarball for {key!r}: {tarball}")
        # name@version (scoped names start with @): version is after the
        # last @; url deps (name@https://...) are excluded upstream.
        name, _, version = key.rpartition("@")

        files_map = {}
        manifest = None
        with tarfile.open(tarball) as t:
            members = t.getmembers()
            tops = {m.name.split("/")[0] for m in members}
            if len(tops) != 1:
                die(f"tarball for {key!r} has {len(tops)} top-level entries")
            top = tops.pop()
            for m in members:
                rel = m.name[len(top) + 1:]
                if not rel:
                    continue
                if m.issym():
                    # pnpm drops symlinks when storing packages; match it.
                    n_symlinks += 1
                    continue
                if m.isdir():
                    continue
                # hardlink: extractfile resolves it to the linked file's
                # content; anything else (fifo, chardev) is unsupported
                fh = t.extractfile(m) if m.isreg() or m.islnk() else None
                if fh is None:
                    die(f"unsupported member {m.name!r} in {key!r}")
                data = fh.read()
                h = hashlib.sha512(data).hexdigest()
                mode = m.mode & 0o7777
                # pnpm stores files with any exec bit (mode & 0o111) under a
                # "-exec" suffixed path and verifies them there; match it.
                suffix = "-exec" if mode & 0o111 else ""
                dest = os.path.join(files_dir, h[:2], h[2:] + suffix)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                if not os.path.exists(dest):
                    with open(dest, "wb") as f:
                        f.write(data)
                    # pnpm links store files into node_modules by hardlink,
                    # inheriting the on-disk mode; set the exec bit so
                    # executables (esbuild, native binaries) are runnable.
                    os.chmod(dest, 0o755 if mode & 0o111 else 0o644)
                files_map[rel] = {
                    "checkedAt": CHECKED_AT,
                    "digest": h,
                    "mode": mode,
                    "size": len(data),
                }
                n_files += 1
                if rel == "package.json":
                    manifest = json.loads(data)
        if manifest is None:
            die(f"tarball for {key!r} has no package.json")

        scripts = manifest.get("scripts") or {}
        requires_build = any(
            h in scripts for h in ("preinstall", "install", "postinstall"))
        blob = enc.encode({
            "requiresBuild": requires_build,
            "manifest": manifest,
            "algo": "sha512",
            "files": Map(files_map),
        })
        rows.append((f"{entry['integrity']}\t{package_id(key)}", blob))

    rows.sort(key=lambda r: r[0])
    con = sqlite3.connect(os.path.join(out, "v11", "index.db"))
    con.execute("PRAGMA journal_mode=DELETE")
    con.execute(
        "CREATE TABLE package_index ("
        "key TEXT PRIMARY KEY, data BLOB NOT NULL) WITHOUT ROWID")
    con.executemany("INSERT INTO package_index (key, data) VALUES (?, ?)",
                    rows)
    con.commit()
    con.close()
    print(f"assembled store: {len(rows)} packages, {n_files} files"
          + (f", {n_symlinks} symlinks dropped" if n_symlinks else ""))


if __name__ == "__main__":
    main()
