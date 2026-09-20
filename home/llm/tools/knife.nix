# knife: a reverse engineer's binary Swiss-army knife (bl4ckr0ss3/knife).
#
# Pure-Rust static analysis of PE/ELF/Mach-O: triage, disassembly, function/CFG
# recovery, crypto-constant + YARA scanning. It ships a built-in stdio MCP
# server (`knife mcp`) that exposes the same analysis engine the CLI/TUI use, so
# an agent can drive it without the target ever being executed.
#
# Not in nixpkgs, so built here from the flakeless `knife` input (see flake.nix);
# `nix flake update knife` re-pins the source. The crate is `reknife` (the
# `knife` name is taken on crates.io) but its `[[bin]]` installs as `knife`, so
# pname follows the crate name and the produced binary is `knife`.
{ lib, rustPlatform, src }:

let
  # Read the crate's name/version from its manifest so a re-pin updates both
  # together (no hardcoded version to drift out of sync).
  cargo = builtins.fromTOML (builtins.readFile (src + "/Cargo.toml"));
in
rustPlatform.buildRustPackage {
  pname = cargo.package.name;      # "reknife"
  version = cargo.package.version; # "1.8.0"
  inherit src;

  # Vendored cargo deps from the source's Cargo.lock; re-resolves automatically
  # when the input is updated (matches the headroom cargoDeps pattern).
  cargoDeps = rustPlatform.importCargoLock {
    lockFile = src + "/Cargo.lock";
  };

  # All deps (goblin, pdb, iced-x86, ratatui, ...) are pure Rust — no C
  # toolchain or system libraries required.
  #
  # The `record` feature (the knife-record README demo recorder) is off by
  # default, so a plain build produces only the `knife` binary.
  #
  # doCheck is false to keep the build lean; the crate's tests are exercised by
  # upstream CI (see .github/workflows/ci.yml), mirroring the headroom
  # doCheck = false precedent.
  doCheck = false;

  meta = {
    description = "A reverse engineer's binary Swiss-army knife: parse, triage, and disassemble PE/ELF/Mach-O; ships a built-in `knife mcp` stdio server";
    homepage = "https://github.com/bl4ckr0ss3/knife";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
    mainProgram = "knife";
    maintainers = [ ];
  };
}
