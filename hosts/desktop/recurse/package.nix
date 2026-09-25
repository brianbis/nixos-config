{ lib
, rustPlatform
, buildNpmPackage
, pkg-config
, makeWrapper
, webkitgtk_4_1
, gtk3
, glib
, wayland
, libxkbcommon
, cargo-tauri
, src
, version
}:

# Recurse — agentic reverse-engineering environment ("Cursor for reverse
# engineering"). Tauri 2 desktop app: React/TypeScript frontend (tauri/) +
# Rust backend (tauri/src-tauri) over a pluggable analysis backend
# (crates/librecurse). The default backend is a pure-Rust native engine
# (object + capstone); an external radare2 engine is opt-in at runtime
# (RECURSE_BACKEND=r2) and is never linked or bundled.
#
# Layout: cargo workspace at the repo root (members: crates/librecurse,
# crates/recurse-eval, tauri/src-tauri); the npm package (package.json +
# package-lock.json + vite config) lives in tauri/.
#
# Build, two derivations:
#   1. frontend — buildNpmPackage on tauri/. The build sandbox blocks network,
#      so the npm closure comes from fetchNpmDeps, a fixed-output derivation
#      (the only network step; FODs are exempt from the sandbox network block —
#      same pattern as fetchPnpmDeps in home/llm/dsh/tarball.nix). `npm ci`
#      then runs offline from the fetched cache, and `npm run build` (tsc &&
#      vite build) emits dist/.
#   2. the app — rustPlatform.buildRustPackage. preBuild drops the prebuilt
#      dist/ where tauri.conf.json's frontendDist (../dist, relative to
#      tauri/src-tauri) points; tauri-build embeds it into the binary at
#      compile time, so a plain `cargo build` of the tauri/src-tauri crate
#      produces the whole app — the tauri CLI is only needed for bundling,
#      which we skip (we install the binary + icon directly).
let
  frontend = buildNpmPackage {
    pname = "recurse-frontend";
    inherit version;
    src = src + "/tauri";

    # Hash of the fetched npm cache (fetchNpmDeps FOD output): pins the npm
    # closure (npm + nodejs from this nixpkgs pin + the committed
    # package-lock.json). Re-pin when `nix flake update recurse` moves the
    # lockfile: set to lib.fakeHash, build, copy the `got: sha256-…` value
    # back.
    npmDepsHash = "sha256-8fbqE9et/cxzpfypB3Ucg6pMxOm7s9BImvJqS5Q84rw=";

    npmBuildScript = "build";

    # We only need the vite bundle, not an npm pack of the package.
    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist $out/dist
      runHook postInstall
    '';

    meta = {
      description = "Recurse frontend (React/TypeScript vite bundle)";
      homepage = "https://github.com/Recurse-Labs/recurse";
      license = lib.licenses.asl20;
    };
  };
in

rustPlatform.buildRustPackage rec {
  pname = "recurse";
  inherit version;

  # Source from the flakeless `recurse` input (see flake.nix);
  # `nix flake update recurse` re-pins it.
  inherit src;

  # Cargo workspace root is the repo root; the app crate is in
  # tauri/src-tauri. Vendored deps from the workspace Cargo.lock
  # (all registry crates; re-resolves when the input is updated).
  cargoRoot = ".";
  buildAndTestSubdir = "tauri/src-tauri";
  cargoDeps = rustPlatform.importCargoLock {
    lockFile = src + "/Cargo.lock";
  };

  # Enable Tauri's `custom-protocol` feature so the app compiles in
  # PRODUCTION mode. Tauri decides dev-vs-prod at build time: `tauri`'s
  # build.rs sets `dev = !custom-protocol`, and in dev mode the webview loads
  # the UI from `build.devUrl` (http://localhost:1420, a Vite dev server)
  # instead of the embedded `frontendDist`. The upstream app's Cargo.toml
  # declares `tauri = { version = "2", features = [] }` (no custom-protocol),
  # so a plain `cargo build` (what this derivation runs, rather than the
  # `tauri build` CLI that would enable the feature) produces a dev-mode
  # binary: the packaged app then shows a white screen and "could not connect
  # to localhost: Connection refused" because no dev server is running.
  # Patching the feature on (as `tauri build` does) makes tauri-build embed
  # the prebuilt dist and serve it over the custom tauri:// protocol.
  postPatch = ''
    sed -i 's|^\(tauri = { version = "2", features = \)\[\] }$|\1["custom-protocol"] }|' tauri/src-tauri/Cargo.toml
  '';

  nativeBuildInputs = [ pkg-config makeWrapper ];
  # Tauri/wry on Linux: webkit2gtk-4.1 (>= 2.40) + gtk3; tao's wayland
  # backend links wayland-client + libxkbcommon (X11 is dlopen'd at runtime,
  # no link dependency).
  buildInputs = [
    webkitgtk_4_1
    gtk3
    glib
    wayland
    libxkbcommon
  ];

  # tauri-build embeds frontendDist into the binary at compile time and
  # fails if the directory is missing, so the prebuilt bundle must be in
  # place before cargo build.
  preBuild = ''
    cp -r ${frontend}/dist tauri/dist
  '';

  # The app crate has no tests; the workspace's librecurse/eval tests run in
  # upstream CI.
  doCheck = false;

  postInstall = ''
    # App icon for the .desktop entry (referenced by absolute path).
    mkdir -p $out/share/icons
    cp tauri/src-tauri/icons/icon.png $out/share/icons/recurse.png

    # Webview media playback (asset:// protocol via the tauri gst plugin) +
    # the NVIDIA explicit-sync workaround — same env as nixpkgs' tauri hook.
    wrapProgram "$out/bin/recurse" \
      --set WEBKIT_GST_ALLOWED_URI_PROTOCOLS "asset" \
      --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${cargo-tauri.gst-plugin}/lib/gstreamer-1.0/" \
      --set __NV_DISABLE_EXPLICIT_SYNC 1;
  '';

  meta = {
    description = "AI-native IDE for reverse engineering (agentic RE environment)";
    longDescription = ''
      Cursor-style workspace (function list, disassembly/strings/imports tabs,
      CFG graph) with a grounded LLM agent sidebar that drives a live analysis
      session on any binary. Analysis goes through a pluggable Engine trait:
      the default native engine is pure Rust (object + capstone, multi-arch);
      an external radare2 engine is an opt-in alternative.
    '';
    homepage = "https://github.com/Recurse-Labs/recurse";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "recurse";
  };
}
