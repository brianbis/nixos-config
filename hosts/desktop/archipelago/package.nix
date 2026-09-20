# Archipelago Multi-Game Randomizer and Server.
#
# Assembles the pinned upstream source tree (read-only, in the store) with a
# python3.13 environment containing every runtime dependency, then exposes
# entry-point wrappers:
#
#   archipelago-webhost   WebHost.py  (web UI + seed generator + in-process
#                                      room hosting + web tracker)
#   archipelago-server    MultiServer.py (standalone websocket game server)
#   archipelago-generate  Generate.py   (CLI seed generation)
#   archipelago-launcher  Launcher.py   (GUI launcher + "Build APWorlds" CLI)
#
# Runtime state lives outside the store:
#   CWD (config.yaml, uploads/, logs/, ap.db3, Players/)
#   ~/.local/share/Archipelago/ (user_path fallback; custom worlds load from
#   ~/.local/share/Archipelago/worlds/ because the store tree is read-only)
#
# ModuleUpdate's pip auto-install is bypassed at runtime with
# SKIP_REQUIREMENTS_UPDATE=1 (set by the wrappers); all requirements are
# pre-installed in the environment below.
{ lib
, stdenvNoCC
, fetchPypi
, fetchurl
, python313
, src
, kivymdSrc
, zilliandomizerSrc
, sdl3
, sdl3-image
, sdl3-mixer
, sdl3-ttf
}:

let
  py = python313.pkgs;

  # Source from the flakeless `archipelago` input (see flake.nix);
  # `nix flake update archipelago` re-pins it.
  repo = src;

  # nixpkgs' kivy is built against SDL2 only, so its `window_sdl3` provider
  # ships without the compiled `_window_sdl3` extension and Kivy aborts with
  # "Unable to find any valuable Window provider". Rebuild kivy with SDL3 so
  # setup.py's pkg-config autodetect compiles `_window_sdl3` (USE_SDL3=1 forces
  # it). SDL3 is a build input (for the .pc files + link) and is propagated to
  # the runtime RPATH so the extension resolves at load time.
  kivy = py.kivy.overrideAttrs (old: {
    # The .pc files (sdl3.pc, sdl3-image.pc, …) that setup.py's pkg-config
    # autodetect needs live in the .dev outputs (which depend on .lib, so the
    # shared libraries land on the runtime RPATH). sdl3-ttf has no .dev output
    # — its single .out carries the .pc file directly.
    buildInputs = (old.buildInputs or [ ])
      ++ [ sdl3.dev sdl3-image.dev sdl3-mixer.dev sdl3-ttf ];
    USE_SDL3 = 1;
    # setup.py's determine_sdl3() sanity-checks that the SDL3 + sub-library
    # headers exist by looking for SDL.h / SDL_mixer.h / … directly inside
    # each include dir. The .pc Cflags point at <prefix>/include, but the
    # headers live in subdirs (<prefix>/include/SDL3/SDL.h, …), so the check
    # fails and use_sdl3 is reverted to False (no _window_sdl3 built). Point
    # KIVY_SDL3_PATH at the subdirs so the headers are found; the link flags
    # still come from pkg-config.
    KIVY_SDL3_PATH = builtins.concatStringsSep ":" [
      "${sdl3.dev}/include/SDL3"
      "${sdl3-mixer.dev}/include/SDL3_mixer"
      "${sdl3-ttf}/include/SDL3_ttf"
      "${sdl3-image.dev}/include/SDL3_image"
    ];
  });

  # PyPI packages that are missing from nixpkgs or pinned to a version
  # incompatible with Archipelago. Hashes are the PyPI sdist sha256.

  # nixpkgs ships websockets 16.x, but Archipelago pins 13.1 (<14): 16.x
  # dropped the `port=` kwarg of websockets.connect (CommonClient.py) and the
  # awaitable Server (MultiServer.py does `await ctx.server`).
  websockets = py.buildPythonPackage {
    pname = "websockets";
    version = "13.1";
    pyproject = true;
    src = fetchPypi {
      pname = "websockets";
      version = "13.1";
      hash = "sha256-o7M2YIfBvAonlREe3K3duLO1lQnV211+o/3Wn5VKiHg=";
    };
    build-system = [ py.setuptools py.wheel ];
  };

  # pyproject build-system requires setuptools_scm>=6.2 (dynamic version,
  # write_to pyshortcuts/version.py); with the pypa hook's --no-isolation it
  # must be importable in the build env, and the pretend version stands in
  # for the missing .git metadata. charset-normalizer is a runtime dep
  # (checked by pythonRuntimeDepsCheckHook).
  pyshortcuts = py.buildPythonPackage {
    pname = "pyshortcuts";
    version = "1.9.7";
    pyproject = true;
    src = fetchPypi {
      pname = "pyshortcuts";
      version = "1.9.7";
      hash = "sha256-vy8o1efl5dglNm/2MlG+VRiUbx4xpnK10X/BmQm3ifs=";
    };
    build-system = [ py.setuptools py.wheel py.setuptools-scm ];
    env = {
      SETUPTOOLS_SCM_PRETEND_VERSION = "1.9.7";
      SETUPTOOLS_SCM_PRETEND_VERSION_FOR_PYSHORTCUTS = "1.9.7";
    };
    propagatedBuildInputs = [ py.charset-normalizer ];
  };

  # worlds/pokemon_emerald/data.py imports pkg_resources at module level, but
  # nixpkgs' setuptools (>=81) no longer ships pkg_resources. Ship 80.9.0 so
  # every bundled world loads (ModuleUpdate's own fallback pins >=75,<81).
  setuptools80 = py.buildPythonPackage {
    pname = "setuptools";
    version = "80.9.0";
    pyproject = true;
    src = fetchPypi {
      pname = "setuptools";
      version = "80.9.0";
      hash = "sha256-82tHQC7N52jb+vxG6OQge0NgxlTx87uER18KKGKPsZw=";
    };
    build-system = [ py.setuptools py.wheel ];
  };

  # worlds/soe/__init__.py imports pyevermizer at module level.
  pyevermizer = py.buildPythonPackage {
    pname = "pyevermizer";
    version = "0.50.1";
    pyproject = true;
    src = fetchPypi {
      pname = "pyevermizer";
      version = "0.50.1";
      hash = "sha256-zVbMom7ZZ1eQFU3XBAKtKKOB/DyQMb0C65sdrYwxc5g=";
    };
    build-system = [ py.setuptools py.wheel ];
  };

  # worlds/_sc2common pins protobuf==6.33.5 (nixpkgs has 7.x).
  protobuf = py.buildPythonPackage {
    pname = "protobuf";
    version = "6.33.5";
    pyproject = false;
    src = fetchPypi {
      pname = "protobuf";
      version = "6.33.5";
      hash = "sha256-bdysKggfi3uWQsCUBrxqQpASj85fRxzd0WWWC7kRnlw=";
    };
  };

  # worlds/alttp ROM patching (imported lazily by worlds/alttp/Rom.py).
  maseyaZ3pr = py.buildPythonPackage {
    pname = "maseya-z3pr";
    version = "1.0.0rc1";
    pyproject = false;
    src = fetchPypi {
      pname = "maseya-z3pr";
      version = "1.0.0rc1";
      hash = "sha256-wCj9syUrSuLIbwfsyZY2n+Oar+s7oxQBG/Y3Ilf4Z8U=";
    };
  };

  xxtea = py.buildPythonPackage {
    pname = "xxtea";
    version = "3.7.0";
    pyproject = true;
    src = fetchPypi {
      pname = "xxtea";
      version = "3.7.0";
      hash = "sha256-KLofMmRrDT60POd04qgG9TFfE9qatYcHXv0docNwoFI=";
    };
    build-system = [ py.setuptools py.wheel ];
  };

  # worlds/factorio client (imported lazily by worlds/factorio/Client.py).
  # fetchurl (not fetchPypi): the sdist filename is factorio_rcon_py-2.1.3
  # (underscores) while fetchPypi builds the URL from the hyphenated pname,
  # which 404s.
  factorioRconPy = py.buildPythonPackage {
    pname = "factorio-rcon-py";
    version = "2.1.3";
    pyproject = true;
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/23/24/ddb08445a3a00c4b106b81ee2b3b59061cd29ea8f4968ec33954adf1c46a/factorio_rcon_py-2.1.3.tar.gz";
      sha256 = "84bfc42d2adfcd01660bd403652c6453f6be2b474817e214e75206f02b1512c3";
    };
    build-system = [ py.setuptools py.wheel ];
  };

  # NOTE: dolphin-memory-engine (worlds/tww client) is intentionally NOT
  # installed. worlds/tww/__init__.py imports TWWClient (and thus
  # dolphin_memory_engine) only lazily inside launch_client(), so the TWW
  # world loads and generates fine without it. Building it would require a
  # cmake + cython + C++ toolchain plus setuptools-cmake-helper (not in
  # nixpkgs); it is only needed to run the TWW client against the Dolphin
  # emulator, which is not a free game.

  # asynckivy's runtime dependency (not in nixpkgs). 0.6.3 is the newest
  # release satisfying asynckivy 0.6.4's asyncgui>=0.6,<0.7 constraint.
  # The sdist declares the poetry-core backend; its only runtime dep
  # (exceptiongroup) is py<3.11-only, so the 3.13 runtime-deps check passes.
  asyncgui = py.buildPythonPackage {
    pname = "asyncgui";
    version = "0.6.3";
    pyproject = true;
    src = fetchPypi {
      pname = "asyncgui";
      version = "0.6.3";
      hash = "sha256-Bd5JwiIRKNNTDwEN+YSR81Uxg+yJCdIFoMAlC+5dbgw=";
    };
    build-system = [ py.poetry-core ];
  };

  # kivymd runtime dependency (not in nixpkgs). Its sdist declares the
  # poetry-core build backend (poetry.core.masonry.api); with the pypa hook's
  # --no-isolation that backend must be present in the build environment.
  # asyncgui is a hard runtime import (asynckivy/_*.py), so propagate it.
  asynckivy = py.buildPythonPackage {
    pname = "asynckivy";
    version = "0.6.4";
    pyproject = true;
    src = fetchPypi {
      pname = "asynckivy";
      version = "0.6.4";
      hash = "sha256-WMNIdqJCJGTznfEgtlnIsi4ESFLdf/lMW5y52thOkCs=";
    };
    build-system = [ py.poetry-core ];
    propagatedBuildInputs = [ asyncgui ];
  };

  # KivyMD's uix/fitimage imports materialshapes.kivy_widget, which imports
  # cairo (pycairo) at module level. Pure-python sdist, PEP517 setuptools
  # backend. pycairo is a hard runtime import, so propagate it.
  materialshapes = py.buildPythonPackage {
    pname = "materialshapes";
    version = "0.3";
    pyproject = true;
    src = fetchPypi {
      pname = "materialshapes";
      version = "0.3";
      hash = "sha256-FB1M6q9BIjeeuBR4Bdmofo4RvekLA1KcuuGhaJ3+aGg=";
    };
    build-system = [ py.setuptools py.wheel ];
    # The wheel's METADATA declares kivy/pycairo/pillow; the runtime deps
    # check requires all of them in propagatedBuildInputs.
    propagatedBuildInputs = [ kivy py.pycairo py.pillow ];
  };

  # requirements.txt pins KivyMD at this git rev (>=2.0.1.dev0); not on PyPI.
  # Runtime deps from setup.py install_requires (checked by
  # pythonRuntimeDepsCheckHook): kivy, pillow, materialyoucolor, asynckivy.
  # format = "setuptools": the pyproject.toml has no [build-system], so
  # pyproject=true (PEP517) would fail; pyproject=false maps to format="other"
  # which expects a custom buildPhase (none provided) and produces an empty
  # package. "setuptools" builds a wheel via setup.py and installs it.
  kivymd = py.buildPythonPackage {
    pname = "kivymd";
    version = "2.0.1.dev0";
    format = "setuptools";
    # Source from the flakeless `kivymd` input (see flake.nix);
    # `nix flake update kivymd` re-pins it.
    src = kivymdSrc;
    propagatedBuildInputs = [ kivy py.pillow py.materialyoucolor asynckivy ];
  };

  # worlds/zillion/__init__.py imports zilliandomizer at module level; pinned
  # at this git rev (0.9.1). use_scm_version=True needs a pretend version
  # because the source is a tarball without .git metadata.
  zilliandomizer = py.buildPythonPackage {
    pname = "zilliandomizer";
    version = "0.9.1";
    pyproject = true;
    # Source from the flakeless `zilliandomizer` input (see flake.nix);
    # `nix flake update zilliandomizer` re-pins it.
    src = zilliandomizerSrc;
    build-system = [ py.setuptools py.wheel py.setuptools-scm ];
    env = {
      SETUPTOOLS_SCM_PRETEND_VERSION = "0.9.1";
      SETUPTOOLS_SCM_PRETEND_VERSION_FOR_ZILLIANDOMIZER = "0.9.1";
    };
  };

  # python313.withPackages (ps: [ ... ]) builds a python3.13 environment whose
  # bin/python can import every package in the list. (buildEnv/withPackages live
  # on the interpreter, not on python313.pkgs; the list is a function of the
  # package set, and ps == py here.)
  env = python313.withPackages (ps: [
      # --- requirements.txt (core) ---
      py.colorama # 0.4.6
      py.pyyaml # 6.0.3
      py.jellyfish # 1.2.1
      py.jinja2 # 3.1.6
      py.schema # 0.7.8
      kivy # 2.3.1 (Launcher GUI; imported lazily inside run_gui; SDL3 build, see above)
      py.bsdiff4 # 1.2.6 (also worlds/tloz)
      py.platformdirs
      py.certifi
      py.orjson # worlds/factorio, gl, kdl3 import it at module level
      py.typing-extensions
      py.pathspec
      websockets # 13.1 (see above)
      pyshortcuts # Launcher.py
      kivymd # Launcher GUI

      # --- WebHostLib/requirements.txt (web UI + tracker + generator) ---
      py.flask
      py.werkzeug
      py.pony # upstream ponyorm 0.7.20; Archipelago's black-sliver fork only
      # relaxes a setup.py version guard for py3.13, so upstream works.
      py.waitress
      py.flask-caching
      py.flask-compress
      py.flask-limiter
      py.flask-cors
      py.bokeh # WebHostLib/stats.py
      py.markupsafe
      py.setproctitle
      py.mistune
      py.docutils
      py.psutil
      py.click # WebHostLib/cli

      # --- world requirements (server-side imports) ---
      # sc2 (+ _sc2common): aiohttp/loguru/mpyq/portpicker/nest-asyncio from
      # nixpkgs, protobuf pinned (see above).
      py.aiohttp
      py.loguru
      py.mpyq
      py.portpicker
      py.nest-asyncio
      protobuf
      # alttp (lazy): maseya-z3pr + xxtea
      maseyaZ3pr
      xxtea
      # factorio (client, lazy)
      factorioRconPy
      # soe + zillion (module-level imports, see above)
      pyevermizer
      zilliandomizer

      # --- kivymd runtime dependencies ---
      py.pillow
      py.materialyoucolor
      asynckivy
      # uix/fitimage (loaded via uix/list) imports materialshapes.kivy_widget,
      # which imports cairo (pycairo) at module level.
      materialshapes

      # --- pkg_resources (see setuptools80 above); last so it shadows the
      # newer setuptools that transitive packages might pull in ---
      setuptools80
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "archipelago";
  version = "0.6.8";
  src = repo;

  dontConfigure = true;
  dontBuild = true;

  # WebHost generates option templates and tutorial docs into
  # <install>/WebHostLib/static/generated at startup and serves them back from
  # the Flask static folder. The store install is read-only, so redirect that
  # generated tree to user_path (~/.local/share/Archipelago/WebHostLib/static/
  # generated) — the same fallback user_path() uses to load custom worlds when
  # the install is not writable. The reads in misc.py are patched to match.
  # (Image links inside tutorial docs still resolve against the static URL and
  # 404 for the generated docs; cosmetic, and the bundled/skeleton docs carry
  # no images.)
  postPatch = ''
    # copy_tutorials_files_to_static(): the base target (WebHost.py). The
    # per-file copyfile targets are absolute paths under it, so they follow.
    sed -i 's|base_target_path = Utils.local_path("WebHostLib", "static", "generated", "docs")|base_target_path = Utils.user_path("WebHostLib", "static", "generated", "docs")|' WebHost.py

    # options.create(): the option yaml templates (WebHostLib/options.py).
    sed -i 's|from Utils import local_path$|from Utils import local_path, user_path|; s|target_folder = local_path("WebHostLib", "static", "generated")|target_folder = user_path("WebHostLib", "static", "generated")|' WebHostLib/options.py

    # update_sprites_lttp() (WebHostLib/lttpsprites.py; user_path already
    # imported there).
    sed -i 's|output_dir = local_path("WebHostLib", "static", "generated")|output_dir = user_path("WebHostLib", "static", "generated")|' WebHostLib/lttpsprites.py

    # The generated-docs reads (WebHostLib/misc.py, two occurrences).
    sed -i 's|from Utils import title_sorted, utcnow|from Utils import title_sorted, utcnow, user_path|; s|os.path.join(app.static_folder, "generated", "docs", secure_game_name)|os.path.join(user_path("WebHostLib", "static", "generated"), "docs", secure_game_name)|g' WebHostLib/misc.py

    # Custom-world loading (worlds/__init__.py). WorldSource.load() does
    # importlib.import_module(f".{name}", "worlds"), which only resolves if the
    # world's directory is on the worlds package __path__. The bundled worlds
    # live in local_folder (already on __path__), but user worlds load from
    # user_folder — which upstream never adds to __path__. From a read-only
    # store install user_folder is ~/.local/share/Archipelago/worlds, so custom
    # worlds (including the bundled skeleton, seeded there by archipelago-init)
    # would fail with ModuleNotFoundError. Append it to __path__ so they load.
    sed -i '/^user_folder = user_path/a if user_folder:\n    __path__.append(user_folder)' worlds/__init__.py

    # user_path() one-time home copy (Utils.py). The manifest comparison uses
    # shallow=True (mtime + size). Nix strips all write bits when importing a
    # derivation into the store, so the copy2-based home copy is read-only and
    # the store manifest's mtime changes on every rebuild — the copytree would
    # therefore re-run on every start after a rebuild and crash overwriting
    # the read-only home files. Compare content instead: the manifest content
    # is identical across rebuilds, so the copytree runs once (and again only
    # if the manifest content actually changes, e.g. a version bump).
    sed -i 's|user_path("manifest.json"), shallow=True|user_path("manifest.json"), shallow=False|' Utils.py
  '';

  installPhase = ''
    mkdir -p $out/bin $out/lib/archipelago $out/share/archipelago/worlds

    # Source tree. Copy from the current directory, which is the unpacked
    # source root that postPatch modified — NOT $src, which still points at
    # the pristine (unpatched) store path. WebHost.py sets local_path to the
    # script directory; user_path() falls back to ~/.local/share/Archipelago
    # because the store is not writable, so custom worlds load from
    # ~/.local/share/Archipelago/worlds/.
    cp -r . $out/lib/archipelago/

    # kivy.core.audio was split into kivy.core.audio_input / kivy.core.audio_output
    # in the Kivy rev nixpkgs ships (2.3.1-unstable-2026-07-11); SoundLoader now
    # lives in audio_output. kvui.py still imports the old path, so the launcher
    # crashes with ModuleNotFoundError. Patch the import to the new location.
    sed -i 's/^from kivy\.core\.audio import SoundLoader$/from kivy.core.audio_output import SoundLoader/' \
      $out/lib/archipelago/kvui.py

    # user_path() populates the home dir from the source tree by copytree'ing
    # Players/, data/sprites/ and data/lua/ — a code path that only runs from
    # a read-only install (i.e. the store). Players/ is absent from a git
    # clone (untracked), so create it here; the other two ship with the
    # source. (Nix strips all write bits when importing into the store, so no
    # chmod in the build can make the home copies writable — archipelago-init
    # re-asserts write bits in the home dir at runtime instead.)
    mkdir -p $out/lib/archipelago/Players

    # manifest.json marks a "proper install": with it present (and copied to
    # the home dir) user_path() populates the home once instead of re-copying
    # the data tree on every start. The check is content-based (shallow=False,
    # see postPatch), so the two stay equal across rebuilds.
    cat > $out/lib/archipelago/manifest.json <<'EOF'
{
  "buildtime": "nix",
  "hashes": {},
  "version": [0, 6, 8]
}
EOF

    # Custom worlds (per-game subdirectories of games/ that contain an
    # archipelago.json), seeded into ~/.local/share/Archipelago/worlds/ by
    # the archipelago-init service (see module.nix). Non-world game folders
    # (seed profiles, patch-builder .nix) are not copied.
    for d in ${./games}/*/; do
      if [ -f "$d/archipelago.json" ]; then
        cp -r "$d" $out/share/archipelago/worlds/
      fi
    done

    # Entry-point wrappers. Each runs the python environment's interpreter
    # (python313.withPackages, see env above) on the corresponding upstream
    # script. SKIP_REQUIREMENTS_UPDATE=1 skips ModuleUpdate's pip
    # auto-install (everything is pre-installed in the environment).
    # (Positional parameters instead of shell parameter expansion: the
    # dollar-brace syntax is Nix string interpolation and cannot appear
    # in single-quoted strings, so the loop is written with a function
    # taking $1/$2.)
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
    # The launcher is the only Kivy GUI. This Kivy rev (2.3.1-unstable) has no
    # "gl" window provider — the available ones are sdl3, x11 and egl_rpi — so
    # forcing KIVY_WINDOW=gl makes Kivy abort with "Unable to find any valuable
    # Window provider". Force the sdl3 provider, which works on both Wayland
    # and X11.
    cat > "$out/bin/archipelago-launcher" <<EOF
#!/bin/sh
exec env SKIP_REQUIREMENTS_UPDATE=1 KIVY_WINDOW=sdl3 ${env}/bin/python $out/lib/archipelago/Launcher.py "\$@"
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
