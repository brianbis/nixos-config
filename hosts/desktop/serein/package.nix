{ lib
, rustPlatform
, cmake
, pkg-config
, alsa-lib
, pulseaudio
, webkitgtk_4_1
, gtk3
, libsoup_3
, glib
, gst_all_1
, gtk4
, webkitgtk_6_0
, wayland
, libxkbcommon
, fontconfig
, src
}:

# Serein — a lightweight native Discord desktop client written in Rust
# (egui/wgpu immediate-mode rendering, direct gateway/REST transport,
# native voice engine). Cargo workspace at the repo root (members:
# apps/desktop, crates/*, tools/*); the binary is apps/desktop (crate
# `serein`). The vendored patched crates (hpke-rs, davey, wry) live under
# vendor/ and are wired in via [patch.crates-io] in the workspace
# Cargo.toml, so no extra fetches are needed.
#
# Native C built from source: libopus (bundled, via cmake), sqlite
# (rusqlite bundled, cc crate), openh264 (openh264-sys2), rnnoise
# (nnnoiseless).
# Login webview: two stacks — vendored wry 0.57 (webkit2gtk-4.1 + gtk3 +
# libsoup_3, the 3.x line that webkit2gtk-4.1 links; bare `libsoup` is the
# 2.4 alias) and the platform crate's webkit6 (WebKitGTK 6.0 + gtk4 +
# graphene-gobject). Webview media playback: gst_all_1.gstreamer.dev
# (gstreamer-app/video crates; the .pc files are in the dev output).
# Audio (cpal): alsa-lib + pulseaudio (rodio links libpulse directly).
# Wayland/X11 (winit/arboard): wayland +
# libxkbcommon (X11 goes through x11rb, pure Rust, no link dependency).
# Vulkan is dlopen'd at runtime by wgpu — no build dependency.

rustPlatform.buildRustPackage rec {
  pname = "serein";
  version = src.shortRev;

  # Source from the flakeless `serein` input (see flake.nix);
  # `nix flake update serein` re-pins it.
  inherit src;

  # Cargo workspace root is the repo root; the app crate is in
  # apps/desktop. Vendored deps from the workspace Cargo.lock
  # (registry + git deps; re-resolves when the input is updated).
  cargoRoot = ".";
  buildAndTestSubdir = "apps/desktop";
  cargoDeps = rustPlatform.importCargoLock {
    lockFile = src + "/Cargo.lock";

    # The egui monorepo crates are git deps pinned by the workspace
    # (emilk/egui rev 99df44a, see the workspace Cargo.toml).
    # outputHashes maps each crate to the NAR hash of the FULL repository
    # checkout at that rev (importCargoLock keys them by git SHA and feeds
    # the value to a fetchgit FOD), so every crate from the repo shares the
    # one hash. Computed with `nix hash path` on a checkout of that rev
    # (minus .git). Re-pin when the workspace bumps the egui rev: set the
    # entries to lib.fakeHash and copy the `got: sha256-…` value back.
    outputHashes = {
      "ecolor-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "eframe-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "egui-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "egui-wgpu-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "egui-winit-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "egui_glow-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "egui_system_fonts-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "emath-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "epaint-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
      "epaint_default_fonts-0.36.2" = "sha256-zwh3bSl1NYGqFdU62yYAAYHa3d2iTTfq70xjHz2yWY4=";
    };
  };

  # cmake: libopus_sys configures libopus via the cmake crate.
  nativeBuildInputs = [ cmake pkg-config ];
  buildInputs = [
    alsa-lib
    # rodio/cpal links the PulseAudio client lib directly (-l:libpulse.so.0).
    pulseaudio
    webkitgtk_4_1
    gtk3
    libsoup_3
    glib
    # gstreamer-sys (webview media playback, gstreamer-app/video crates):
    # the .pc files live in the dev output (top-level `gst` is an unrelated
    # ghq tool; the GStreamer scope is gst_all_1).
    gst_all_1.gstreamer.dev
    # gstreamer-video-1.0 (video decode pipeline) ships in the base plugins.
    gst_all_1."gst-plugins-base"
    # The platform crate's login webview links WebKitGTK 6.0 / GTK4
    # (webkit6 + gdk4 + graphene) on top of wry's GTK3/WebKitGTK-4.1 stack.
    gtk4
    webkitgtk_6_0
    wayland
    libxkbcommon
    # egui's system_fonts feature reads fontconfig at runtime.
    fontconfig
  ];

  # The workspace tests run in upstream CI.
  doCheck = false;

  postInstall = ''
    # .desktop entry + hicolor icons (upstream packaging/linux/).
    install -Dm644 packaging/linux/serein.desktop $out/share/applications/serein.desktop
    # mkdir first: with $out/share/icons absent, `cp -r hicolor $out/share/icons/`
    # would copy hicolor AS $out/share/icons (dropping the hicolor theme dir).
    mkdir -p $out/share/icons
    cp -r packaging/linux/hicolor $out/share/icons/
  '';

  meta = {
    description = "Lightweight native Discord desktop client (Rust, egui/wgpu)";
    homepage = "https://github.com/ViceVerse-cz/Serein";
    license = with lib.licenses; [ mit asl20 ];
    platforms = lib.platforms.linux;
    mainProgram = "serein";
  };
}
