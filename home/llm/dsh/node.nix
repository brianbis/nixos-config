# The official Node.js binary (linux-x64), pinned by sha256.
#
# Why not pkgs.nodejs: dsh's node-addon-require-builtin addon loads Node
# internals by probing the running node executable — it scans the binary for
# a machine-code getter pattern ("x64 sysv getter ... this->field accessor").
# That pattern only matches the official Node build. Every nixpkgs node build
# (verified: 24.18.0, 24.18.1, 24.19.0, 24.20.0) fails the probe with
# "Unsupported/no-getter", while the official node-v24.20.0-linux-x64 binary
# passes it. Since dsh 0.1.6-alpha.2 the default profile-resolution mode is
# 'runtime' (apps/cli/src/profile-boot.ts), so the probe runs on every
# `dsh --profile` boot; on a nixpkgs node the boot dies with
# "dsh: host preparation failed".
#
# The official binary is dynamically linked against /lib64/ld-linux-x86-64.so.2
# and libstdc++.so.6, neither of which is a declared input on a NixOS host
# (and /lib64 does not exist inside the bubblewrap jails at all). patchelf
# repoints the interpreter at the store glibc and sets a store-only rpath, so
# the binary is self-contained within /nix/store: it runs on the host and in
# every jail (which bind /nix/store), with no implicit host dependencies.
#
# Bump by downloading the new tarball, verifying its sha256 against
# https://nodejs.org/dist/v<ver>/SHASUMS256.txt, and updating url + sha256.
# dsh's engines require "^22.19.0 || >=24.0.0"; keep a version the pinned
# dsh's addon probe is known to accept (test: run the addon's
# requireBuiltin('internal/modules/esm/loader') under the new node).
{ pkgs }:

let
  version = "24.20.0";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nodejs-official";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://nodejs.org/dist/v${version}/node-v${version}-linux-x64.tar.gz";
    # Verified against SHASUMS256.txt for v24.20.0.
    sha256 = "855d581f8a4eb1a8117e3426de25fe02770592febcfb31369aee1ffbfee9e8ec";
  };

  nativeBuildInputs = [ pkgs.patchelf pkgs.gnutar ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    tar -xzf $src --strip-components=1
    # NEEDED: libdl/libm/libpthread/libc/ld-linux (glibc) + libstdc++/libgcc_s
    # (the default gcc's C++ runtime lib — the same one stdenv links against).
    # Both are store paths, so the binary resolves every dependency from
    # /nix/store alone.
    patchelf --set-interpreter ${pkgs.glibc}/lib/ld-linux-x86-64.so.2 \
      --set-rpath ${pkgs.glibc}/lib:${pkgs.gcc.cc.lib}/lib \
      bin/node
    mkdir -p $out
    cp -r bin lib $out/
  '';

  meta = with pkgs.lib; {
    description = "Official Node.js ${version} binary (linux-x64), store-relinked for dsh's native addon probing";
    homepage = "https://nodejs.org";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "node";
  };
}
