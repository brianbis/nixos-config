# Archipelago Multi-Game Randomizer and Server. Assembles the pinned upstream
# source tree (read-only, in the store) with a python3.13 environment built
# from a uv.lock via uv2nix (see hosts/desktop/archipelago/uv/), then exposes
# entry-point wrappers: archipelago-webhost (WebHost.py: web UI + seed
# generator + in-process room hosting + web tracker), archipelago-server
# (MultiServer.py), archipelago-generate (Generate.py), archipelago-launcher
# (Launcher.py, the Kivy GUI). All Python deps come from the uv2nix env (the
# `env` argument), which uv resolves from the upstream requirements.txt
# (uv.lock). kivy is 2.3.1 — the self-contained manylinux wheel bundling SDL2
# with the compiled _window_sdl2 provider (pre-3.0 API the launcher/OC/UT
# code expects) — so the launcher uses the sdl2 window provider; no SDL3
# build, no kivy source patches. Runtime state lives outside the store: CWD
# (config.yaml, uploads/, logs/, ap.db3, Players/) and
# ~/.local/share/Archipelago/ (user_path fallback; custom worlds load from
# ~/.local/share/Archipelago/worlds/ because the store tree is read-only).
# ModuleUpdate's pip auto-install is bypassed at runtime with
# SKIP_REQUIREMENTS_UPDATE=1 (set by the wrappers).
{ lib
, stdenvNoCC
, src
, env
}:

let
  # Source from the flakeless `archipelago` input; `nix flake update archipelago` re-pins it.
  repo = src;
in
stdenvNoCC.mkDerivation {
  pname = "archipelago";
  version = "0.6.8";
  src = repo;

  dontConfigure = true;
  dontBuild = true;

  # WebHost generates option templates + tutorial docs into
  # <install>/WebHostLib/static/generated at startup and serves them from the
  # Flask static folder; the store install is read-only, so redirect that
  # generated tree to user_path (~/.local/share/Archipelago/...) — the same
  # fallback user_path() uses to load custom worlds. The reads in misc.py are
  # patched to match. (Image links inside the generated tutorial docs 404;
  # cosmetic, and the bundled/skeleton docs carry no images.)
  postPatch = ''
    # copy_tutorials_files_to_static() (WebHost.py); the per-file copyfile
    # targets are absolute paths under it, so they follow.
    sed -i 's|base_target_path = Utils.local_path("WebHostLib", "static", "generated", "docs")|base_target_path = Utils.user_path("WebHostLib", "static", "generated", "docs")|' WebHost.py

    # options.create(): the option yaml templates (WebHostLib/options.py).
    sed -i 's|from Utils import local_path$|from Utils import local_path, user_path|; s|target_folder = local_path("WebHostLib", "static", "generated")|target_folder = user_path("WebHostLib", "static", "generated")|' WebHostLib/options.py

    # update_sprites_lttp() (WebHostLib/lttpsprites.py; user_path already imported).
    sed -i 's|output_dir = local_path("WebHostLib", "static", "generated")|output_dir = user_path("WebHostLib", "static", "generated")|' WebHostLib/lttpsprites.py

    # The generated-docs reads (WebHostLib/misc.py, two occurrences).
    sed -i 's|from Utils import title_sorted, utcnow|from Utils import title_sorted, utcnow, user_path|; s|os.path.join(app.static_folder, "generated", "docs", secure_game_name)|os.path.join(user_path("WebHostLib", "static", "generated"), "docs", secure_game_name)|g' WebHostLib/misc.py

    # Custom-world loading (worlds/__init__.py): WorldSource.load() does
    # importlib.import_module, which only resolves if the world's directory is
    # on the worlds package __path__. User worlds load from user_folder
    # (~/.local/share/Archipelago/worlds from a read-only store install),
    # which upstream never adds to __path__, so custom worlds (including the
    # bundled skeleton, seeded there by archipelago-init) fail with
    # ModuleNotFoundError. Append it to __path__ so they load.
    sed -i '/^user_folder = user_path/a if user_folder:\n    __path__.append(user_folder)' worlds/__init__.py

    # user_path() one-time home copy (Utils.py): the manifest comparison uses
    # shallow=True (mtime + size). Nix strips write bits on store import, so
    # the copy2-based home copy is read-only and the store manifest's mtime
    # changes on every rebuild — the copytree would re-run on every start
    # after a rebuild and crash overwriting read-only home files. Compare
    # content instead: identical across rebuilds, so the copytree runs once
    # (and again only if the manifest content actually changes).
    sed -i 's|user_path("manifest.json"), shallow=True|user_path("manifest.json"), shallow=False|' Utils.py
  '';

  installPhase = ''
        mkdir -p $out/bin $out/lib/archipelago $out/share/archipelago/worlds

        # Source tree. Copy from the current directory (the unpacked source
        # root that postPatch modified) — NOT $src, which still points at the
        # pristine (unpatched) store path. user_path() falls back to
        # ~/.local/share/Archipelago because the store is not writable.
        cp -r . $out/lib/archipelago/

        # user_path() populates the home dir from the source tree by
        # copytree'ing Players/, data/sprites/ and data/lua/ (a code path that
        # only runs from a read-only install). Players/ is absent from a git
        # clone (untracked), so create it here; the other two ship with the
        # source. (Nix strips write bits on store import, so no chmod in the
        # build can make the home copies writable — archipelago-init re-asserts
        # them in the home dir at runtime instead.)
        mkdir -p $out/lib/archipelago/Players

        # manifest.json marks a "proper install": with it present (and copied
        # to the home dir) user_path() populates the home once instead of
        # re-copying the data tree on every start. Content-based (shallow=False,
        # see postPatch), so the two stay equal across rebuilds.
        cat > $out/lib/archipelago/manifest.json <<'EOF'
        {
          "buildtime": "nix",
          "hashes": {},
          "version": [0, 6, 8]
        }
    EOF

        # Custom worlds (per-game subdirectories of games/ containing an
        # archipelago.json), seeded into ~/.local/share/Archipelago/worlds/ by
        # archipelago-init (see module.nix); non-world game folders are not copied.
        for d in ${./games}/*/; do
          if [ -f "$d/archipelago.json" ]; then
            cp -r "$d" $out/share/archipelago/worlds/
          fi
        done

        # Entry-point wrappers: each runs the uv2nix env's interpreter (the
        # `env` argument) on the corresponding upstream script. Positional
        # parameters instead of shell parameter expansion: the dollar-brace
        # syntax is Nix string interpolation and cannot appear in single-quoted
        # strings, so the loop is written with a function taking $1/$2.
        mk_wrapper() {
          cat > "$out/bin/archipelago-$1" <<EOF
    #!/bin/sh
    exec env SKIP_REQUIREMENTS_UPDATE=1 ${env}/bin/python $out/lib/archipelago/$2 "\$@"
    EOF
          chmod +x "$out/bin/archipelago-$1"
        }
        mk_wrapper webhost WebHost.py
        mk_wrapper server MultiServer.py
        mk_wrapper generate Generate.py
        # The launcher is the only Kivy GUI: kivy 2.3.1 bundles SDL2 and ships
        # the compiled _window_sdl2 provider, so force the sdl2 window provider
        # (works on Wayland via XWayland and on X11).
        cat > "$out/bin/archipelago-launcher" <<EOF
    #!/bin/sh
    exec env SKIP_REQUIREMENTS_UPDATE=1 KIVY_WINDOW=sdl2 ${env}/bin/python $out/lib/archipelago/Launcher.py "\$@"
    EOF
        chmod +x "$out/bin/archipelago-launcher"
  '';

  meta = with lib; {
    description = "Archipelago Multi-Game Randomizer and Server (WebHost + MultiServer + 76 bundled worlds)";
    homepage = "https://github.com/ArchipelagoMW/Archipelago";
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "archipelago-webhost";
  };
}
