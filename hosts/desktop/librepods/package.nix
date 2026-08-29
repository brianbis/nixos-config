{ lib
, rustPlatform
, fetchFromGitHub
, pkg-config
, makeWrapper
, patchelf
, dbus
, libpulseaudio
, alsa-lib
, bluez
, expat
, fontconfig
, freetype
, libGL
, xorg
, wayland
, libxkbcommon
, vulkan-loader
,
}:

# LibrePods (Rust rewrite) — the "AirPods liberated from Apple's ecosystem"
# daemon, run headless (--no-tray) as a systemd user service.
#
# It owns the Apple-protocol (AACP) lifecycle for the paired AirPods:
#   * continuous BLE monitor that matches the devices' RPA against the LE IRK
#     captured during onboarding (one-time: connect each pair once while this
#     runs, so the AACP handshake stores IRK + enc_key in devices.json),
#   * auto-connect on case-open (shells out `bluetoothctl connect <mac>`,
#     gated by the per-MAC `autoConnect` preference, default true),
#   * AACP features (precise battery, ear detection, noise control, gestures).
#
# We patch it (patches/persist-state.patch) to persist a thin "last known"
# record per MAC to $XDG_STATE_HOME/librepods/state.json. Each record is a flat
# set of the last REAL values observed: a null/0xFF observation never
# overwrites a stored value, and case metrics are only written by a source
# actually reading the case (AACP: case connected; PPM: case is the
# advertiser). Both the PPM (advertising) and AACP (connected) handlers merge
# into the same flat record, so readers (tray, notification watcher, the
# Ctrl+Shift+C connect order) are dumb renderers with no freshness/source
# heuristics. Written unconditionally, so it works headless.
#
# Pinned to the linux/rust branch HEAD (in-PR, not yet tagged):
#   rev 672e65ad36eebf21ff1c1a508066f9197ee56d17 (2026-05-15)
# The build is heavy (iced/wgpu/winit + bluer + libpulse + dbus) because the
# `ui` module compiles even in headless mode. It is built locally under the
# justfile build-flags caps (--cores 4 --max-jobs 4), which keep it within the
# box's memory budget.
let
  # System libraries required by bluer / iced / libpulse-binding / ksni.
  # Mirrors the buildInputs in the project's own flake.nix.
  guiLibs = [
    dbus
    libpulseaudio
    alsa-lib
    bluez
    expat
    fontconfig
    freetype
    libGL
    xorg.libX11
    xorg.libXcursor
    xorg.libXi
    xorg.libXrandr
    wayland
    libxkbcommon
    vulkan-loader
  ];
in
rustPlatform.buildRustPackage rec {
  pname = "librepods";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "librepods-org";
    repo = "librepods";
    rev = "672e65ad36eebf21ff1c1a508066f9197ee56d17";
    hash = "sha256-EuIYvBqBtpgutVqPOLIO3E9OhVzQ5q5TDoz/F+9MHEE=";
  };

  # Cargo workspace lives in a subdirectory.
  # cargoRoot: tells the setup hook where Cargo.lock / the vendor dir are.
  # buildAndTestSubdir: tells the build hook to `pushd` into the crate dir
  # before running `cargo build` (otherwise it looks for Cargo.toml at the
  # source root and fails).
  cargoRoot = "linux-rust";
  buildAndTestSubdir = "linux-rust";
  # Hash of the vendored cargo deps (computed via fetchCargoVendor).
  cargoHash = "sha256-17dE+oYvECU4f1SL6LHS95sXEea/Z0VgTPQ4u6TZTic=";

  # Persist a thin per-MAC last-known record to state.json (headless-friendly).
  patches = [ ./patches/persist-state.patch ];

  nativeBuildInputs = [ pkg-config makeWrapper patchelf ];
  buildInputs = guiLibs;

  # The binary shells out to `bluetoothctl` for auto-connect; make sure it is
  # on the PATH at runtime. Bake the GUI/pulse/dbus libs into the ELF RUNPATH
  # so the headless binary resolves them without a wrapper (mirrors hushmic).
  postInstall = ''
    wrapProgram "$out/bin/librepods" \
      --prefix PATH : ${lib.makeBinPath [ bluez ]} \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath guiLibs};
  '';

  postFixup = ''
    patchelf --add-rpath "${lib.makeLibraryPath guiLibs}" "$out/bin/.librepods-wrapped";
  '';

  # No tests / checks in the upstream crate.
  doCheck = false;

  meta = {
    description = "AirPods liberated from Apple's ecosystem (headless daemon)";
    homepage = "https://github.com/librepods-org/librepods";
    license = lib.licenses.agpl3Only;
    mainProgram = "librepods";
    platforms = [ "x86_64-linux" ];
  };
}
