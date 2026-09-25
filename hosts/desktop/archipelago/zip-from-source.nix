# zip-from-source.nix — package a subdirectory of a pinned source tree into a
# zip with a chosen top-level prefix. Builds the Archipelago apworlds and
# client-mod zips from the pinned source inputs (the tether pattern): the
# source is pinned by the flake lock, `nix flake update archipelago` re-pins
# it, and the zips follow — no manual re-pin, no build-time network, no
# sandbox relaxation. The prebuilt apworld/mod zips are plain zips of the
# (public) source tree, so building them from the pinned source is pure and
# reproducible. Exception: balatro.apworld (Python source not published) is
# pinned as a fixed-output fetchurl instead (games/balatro/balatro.nix).
#
# { pkgs, src, subdir, prefix, name }
#   src     — store path of the source tree (a flake input's .outPath).
#   subdir  — path within src to package; "." for the whole tree.
#   prefix  — top-level directory name inside the resulting zip.
#   name    — short identifier for the derivation pname.
{ pkgs, src, subdir, prefix, name }:
pkgs.stdenv.mkDerivation {
  pname = "archipelago-zip-${name}";
  # A bare `pname` yields a nameless derivation that `derivationStrict`
  # rejects ("attribute 'name' missing"); `name` is only emitted when set or
  # (pname AND version).
  version = "1.0";
  nativeBuildInputs = [ pkgs.zip pkgs.unzip ];
  src = src;
  buildCommand = ''
    set -euo pipefail
    work="$(mktemp -d)"
    # cp -a preserves the store's read-only mode bits, so make the tree
    # owner-writable before rm -rf (a plain rm fails with "Permission denied").
    trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
    mkdir -p "$work/${prefix}"
    if [ "${subdir}" = "." ]; then
      cp -a "$src/." "$work/${prefix}/"
    else
      # Copy the subdir's *contents* into $prefix (the `/.` + trailing `/`),
      # matching the `.` branch. A bare `cp -a "$src/${subdir}" ...` would copy
      # the subdir *into* the already-created $prefix dir, producing a doubled
      # prefix/prefix/ tree that Archipelago's world discovery (which requires
      # $prefix/__init__.py) then rejects.
      cp -a "$src/${subdir}/." "$work/${prefix}/"
    fi
    ( cd "$work" && zip -r -q "$out" "${prefix}" )
    # Sanity: the archive must be non-empty and carry the prefix dir. No
    # `grep -q`: it exits on the first match and SIGPIPEs `unzip -l` (141)
    # under `set -o pipefail` once the listing is large enough.
    test -s "$out"
    unzip -l "$out" | grep "${prefix}/" > /dev/null
  '';
}
