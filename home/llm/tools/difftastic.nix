# difftastic: a structural diff that understands syntax (Wilfred/difftastic).
#
# Not in nixpkgs, so built here from the flakeless `difftastic` input (see
# flake.nix); `nix flake update difftastic` re-pins the source. Pure Rust: the
# tree-sitter parsers come from crates.io, and build.rs compiles four vendored
# C parsers (janet-simple, kotlin, latex, smali) via the `cc` crate. The only
# native build input is a C compiler (cc), which also compiles the bundled
# jemalloc (tikv-jemallocator) on Linux. No system libraries beyond that.
{ lib, rustPlatform, src, stdenv }:

let
  # Read the crate's name/version from its manifest so a re-pin updates both
  # together (no hardcoded version to drift out of sync).
  cargo = builtins.fromTOML (builtins.readFile (src + "/Cargo.toml"));
in
rustPlatform.buildRustPackage {
  pname = cargo.package.name;      # "difftastic"
  version = cargo.package.version; # "0.72.0"
  inherit src;

  # Vendored cargo deps from the source's Cargo.lock; re-resolves automatically
  # when the input is updated (matches the knife/headroom cargoDeps pattern).
  cargoDeps = rustPlatform.importCargoLock {
    lockFile = src + "/Cargo.lock";
  };

  # build.rs compiles the four vendored tree-sitter C parsers via the `cc`
  # crate, and jemalloc compiles its own C sources too — both need a C
  # compiler (stdenv.cc). No system libraries beyond that.
  nativeBuildInputs = [ stdenv.cc ];

  # doCheck is false to keep the build lean; the crate's tests are exercised by
  # upstream CI (see .github/workflows), mirroring the knife doCheck = false
  # precedent.
  doCheck = false;

  meta = {
    description = "A structural diff that understands syntax";
    homepage = "https://github.com/Wilfred/difftastic";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    # The binary is named `difft` (see Cargo.toml [[bin]]), not `difftastic`.
    mainProgram = "difft";
    maintainers = [ ];
  };
}
