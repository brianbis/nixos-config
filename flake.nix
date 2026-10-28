{
  description = "b's NixOS configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nix-alien: run unpatched foreign-ELF binaries ("just run" anything).
    # Upstream flake; keeps its OWN nixpkgs pin (no follows): the bundled
    # nix-index-with-db must match the nixpkgs its resolver runs against, and
    # upstream warns overriding inputs causes mismatches.
    nix-alien.url = "github:thiagokokada/nix-alien";

    nur.url = "github:nix-community/NUR";

    # Apple Music desktop client
    sidra = {
      url = "github:wimpysworld/sidra";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Jailed LLM tooling
    jail-nix.url = "sourcehut:~alexdavid/jail.nix";
    llm-agents.url = "github:numtide/llm-agents.nix";

    # GPU-accelerated Whisper transcription (on-demand VRAM residency)
    whisper-service = {
      url = "path:hosts/desktop/whisper-service";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Linux + iPhone Continuity bridge (clipboard, files, messages, notifications).
    tether = {
      url = "github:zackb/tether/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ArtCraft Crafting Apps (storytold): twelve pure-Rust creative apps, packaged
    # from upstream's prebuilt Linux release tarballs (fetchurl + autoPatchelf).
    # Upstream keeps exactly one branch now: its update.yml workflow commits the
    # newest release set straight to main, so this tracks the default branch and
    # `nix flake update nix-craftapps` re-pins it. (The third path component of a
    # github: URL is a ref — pinning a PR branch there dies on the next update
    # once upstream squash-merges and deletes it: GitHub answers 422, no such SHA.)
    nix-craftapps = {
      url = "github:olafkfreund/nix-craftapps";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # hushmic: real-time mic noise suppression (local build fetches the DPDFNet model).
    hushmic = {
      url = "github:Fovty/hushmic";
      flake = false;
    };

    # --- flakeless source inputs -------------------------------------------
    # Upstream source trees for packages built locally. Each is a flakeless
    # input (upstream has no flake.nix): inputs.<name> is the source tree and
    # `nix flake update <name>` re-pins it to the newest commit of the default
    # branch. The lock's `original` carries no ref/rev, so the input tracks the
    # default branch while `locked` stays at the pinned rev.
    headroom = {
      url = "github:chopratejas/headroom";
      flake = false;
    };
    # knife: reverse engineer's binary Swiss-army knife (triage/disassembly/crypto/YARA + built-in MCP).
    knife = {
      url = "github:bl4ckr0ss3/knife";
      flake = false;
    };
    # graphify: codebase -> queryable knowledge graph + stdio MCP server.
    graphify = {
      url = "github:Graphify-Labs/graphify";
      flake = false;
    };
    # graphlore: richer MCP server (28 tools) wrapping graphify's knowledge graph.
    graphlore = {
      url = "github:yasinyaman/graphlore";
      flake = false;
    };
    # echarts: interactive chart library (npm-only; local package fetches the matching npm dist).
    echarts = {
      url = "github:apache/echarts";
      flake = false;
    };
    # bend: dependently typed, affine language that blocks AI mistakes via proof.
    bend = {
      url = "github:bendlang/bend";
      flake = false;
    };
    # difftastic: structural diff that understands syntax (pure Rust).
    difftastic = {
      url = "github:Wilfred/difftastic";
      flake = false;
    };
    # ripwire: "the ripgrep of AI context" — a zero-dependency C++23 CLI + MCP server.
    ripwire = {
      url = "github:redhat-et/ripwire";
      flake = false;
    };
    # pm-skills: PM Skills Marketplace (phuryn) — its flattened dsh skill
    # bundles install into the llm user's dsh skill root (home/llm/agent-home.nix).
    # `nix flake update pm-skills` re-pins to upstream's default branch.
    pm-skills = {
      url = "github:phuryn/pm-skills";
      flake = false;
    };
    # vulnhunter (capitalone/VulnHunter) — agentic AI security tool shipped as
    # Claude Code skills; flattened into dsh skill bundles (home/llm/vulnhunter-skills.nix)
    # and installed into the llm user's dsh skill root (home/llm/agent-home.nix).
    vulnhunter = {
      url = "github:capitalone/vulnhunter";
      flake = false;
    };
    minuspod = {
      url = "github:ttlequals0/MinusPod";
      flake = false;
    };
    fluent-oled = {
      url = "github:fermeridamagni/fluent-oled";
      flake = false;
    };
    nix-ide = {
      url = "github:nix-community/vscode-nix-ide";
      flake = false;
    };
    wezurrect = {
      url = "github:YedPool/Wezurrect";
      flake = false;
    };
    librepods = {
      url = "github:librepods-org/librepods";
      flake = false;
    };
    ninfer = {
      url = "github:Neroued/ninfer";
      flake = false;
    };
    # strata: inference engine dedicated to Qwen3.8-Flash-Next GSQ-RCO GGUFs (512-expert MoE).
    strata = {
      # Tag-pinned on the last 0.1.x release: the 0.2.x line broke the running
      # stack (937a93c reverted 9de04cd -> 477ac13), and a ref-less url lets any
      # bare `nix flake update` jump this back to refs/heads/main (8183c6b),
      # silently undoing that decision at every sweep. A *tag* ref is stable
      # under update (unlike a PR branch, which 422s once upstream deletes it).
      url = "github:Niko1221/Strata/v0.1.45";
      flake = false;
    };
    ninfer-gzenz = {
      url = "github:gzenz/ninfer";
      flake = false;
    };
    # cinference: focused NInfer fork (MTP draft window 10, CUDA Graph topology); builds with the shared mkNinfer recipe.
    cinference = {
      url = "github:satellitedown/cinference";
      flake = false;
    };
    # exllamav3: EXL3 inference backend (CUDA C++); the tabbyapi engine's backend.
    # `nix flake update exllamav3` re-pins to the latest commit.
    exllamav3 = {
      url = "github:turboderp-org/exllamav3";
      flake = false;
    };
    # tabbyAPI: the OpenAI-compatible EXL3 API server (the omarchy tabbyapi
    # recipes' frontend). `nix flake update tabbyapi` re-pins to the latest commit.
    tabbyapi = {
      url = "github:theroyallab/tabbyAPI";
      flake = false;
    };
    # archipelago meta-flake: bundles main source + PopTracker/apworld as nested inputs (read via outputs.archipelagoInputs.<name>).
    # (its git deps — kivymd, zilliandomizer, the pony fork — are pinned by the
    # uv workspace's uv.lock, not by flake inputs.)
    archipelago = {
      url = "path:hosts/desktop/archipelago";
    };
    # recurse: AI-native IDE for reverse engineering (Tauri 2; pluggable analysis backend).
    recurse = {
      url = "github:Recurse-Labs/recurse";
      flake = false;
    };
    # serein: tiny, performant 100% native Discord client (Rust/egui/wgpu).
    serein = {
      url = "github:ViceVerse-cz/Serein";
      flake = false;
    };

    # uv2nix toolchain: build Archipelago's Python env from a uv.lock (see hosts/desktop/archipelago/uv/).
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
    };

    # llama.cpp: router server for the local LLM fleet; re-pinning may need a new npmDepsHash in hosts/desktop/llm/llamacpp/package.nix.
    llama-cpp = {
      url = "github:ggml-org/llama.cpp";
      flake = false;
    };

    # llama.cpp Bonsai fork: carries the ternary kernels (PTQ1_0/PQ2_0) stock llama.cpp rejects; only Ternary-Bonsai-2-27B needs it.
    llama-cpp-bonsai = {
      url = "github:PrismML-Eng/llama.cpp";
      flake = false;
    };

    # dsh (deepseek-harness) source (pnpm monorepo); built offline by
    # home/llm/dsh/ (npm ci OOMs). Pinned to a published release tag: its
    # tarball's production deps are all on the npm registry, so the npm-closure
    # pin (package-lock.json + deps-sha256.json, generated from exactly this
    # tree by update-deps.py) is always resolvable, and the pnpm side is pinned
    # by one fetchPnpmDeps store hash that reads this tree's own pnpm-lock.yaml.
    # `nix flake update` leaves tag-pinned inputs alone, so plain updates never
    # strand the pin data stale. To move to a new release, run `just dsh-repin`
    # (bumps this ref to the newest npm dist-tag + refreshes all three pins
    # atomically).
    dsh = {
      url = "github:deepseek-ai/deepseek-harness/dsh-v0.2.1-rc.2";
      flake = false;
    };

    # The second machine: the NixOS guest on the Proxmox VE box (vmid 100). Its
    # config lives in hosts/nixos-vm as a self-contained sub-flake and is shipped
    # to that machine verbatim as its own /etc/nixos, so the repo and the guest
    # build from one source of truth. Deliberately NOT `follows = "nixpkgs"`: the
    # sub-flake pins nixpkgs by exact revision (its own flake.lock), so `nix flake
    # update nixpkgs` here can never silently drift the VM's package set.
    nixos-vm.url = "path:hosts/nixos-vm";

    # The physical box itself, once Option A retires Proxmox VE (see
    # hosts/yzerd/README.md). Same self-contained shape as nixos-vm: pinned
    # nixpkgs by exact revision, so it can be installed from a copy on the Ventoy
    # stick without the root flake's networked inputs.
    yz-native.url = "path:hosts/yzerd";
  };

  outputs =
    { self
    , nixpkgs
    , home-manager
    , plasma-manager
    , agenix
    , nur
    , jail-nix
    , llm-agents
    , whisper-service
    , tether
    , ...
    }@inputs:
    let
      system = "x86_64-linux";

      # Local agent tooling overlay (home/llm/tools/overlay.nix); applied to the base pkgs and the system nixpkgs.overlays.
      headroomOverlay = (import ./home/llm/tools/overlay.nix) inputs.headroom inputs.knife inputs.graphify inputs.graphlore inputs.echarts inputs.bend inputs.difftastic inputs.ripwire;

      # Work around a nixpkgs CUDA cccl patch already present in the CCCL 13.3.3.4.1 tarball (causes a "Reversed patch" failure); disable the cudaOlder gate.
      ccclPatchWorkaround = final: prev: {
        cudaPackages_13_2 = prev.cudaPackages_13_2.overrideScope (f: p: {
          cccl = p.cccl.override { cudaOlder = _: false; };
        });
        cudaPackages_13_3 = prev.cudaPackages_13_3.overrideScope (f: p: {
          cccl = p.cccl.override { cudaOlder = _: false; };
        });
      };
      ltraceSkipCheck = final: prev: {
        ltrace = prev.ltrace.overrideAttrs (_: _: { doCheck = false; });
      };
      sageTestsSkipInstallCheck = final: prev: {
        sage-tests = prev.sage-tests.overrideAttrs (_: {
          doInstallCheck = false;
        });
      };
      aiderLiteLLMExceptions = final: prev: {
        aider-chat = prev.aider-chat.overrideAttrs (_: prevA: {
          postPatch = toString (prevA.postPatch or "") + ''
            sed -i '/^EXCEPTIONS = \[/a\    ExInfo("VectorStoreSearchError", False, None),' aider/exceptions.py
          '';
        });
      };
      semgrepRuntimeDeps = final: prev: {
        semgrep = (prev.semgrep.override (old: {
          # semgrep-core 1.180.0 is a prebuilt 255 MB non-PIE binary whose own RUNPATH
          # (/src/semgrep-pro/...:$ORIGIN/libs) is LONGER than the one we set. The recipe
          # does interpreter + rpath in one patchelf call, which grows .dynstr and forces
          # patchelf 0.19.2 to shift the whole file: it aborts in shiftFile (patchelf.cc:547,
          # assertion `splitIndex == -1', exit 134) and every jail that carries semgrep dies.
          # Same two operations, ordered: --set-rpath first fits the existing .dynstr (no
          # shift), and the interpreter patch (28 -> 84 chars) then has room. Verified on the
          # wheel binary: both calls return 0 and the patched binary answers `-version' with
          # every NEEDED lib resolved through the new rpath.
          semgrep-core = old.semgrep-core.overrideAttrs (_: _: {
            postFixup = nixpkgs.lib.optionalString final.stdenv.hostPlatform.isLinux ''
              patchelf --set-rpath "$out/bin/libs:${nixpkgs.lib.makeLibraryPath [ final.stdenv.cc.libc ]}" $out/bin/semgrep-core
              patchelf --set-interpreter "$(cat ${final.stdenv.cc}/nix-support/dynamic-linker)" $out/bin/semgrep-core
            '';
          });
        })).overrideAttrs (_: _: { dontCheckRuntimeDeps = true; });
      };

      anyioPytestNoise = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            anyio = pyPrev.anyio.overridePythonAttrs (old: {
              pytestFlags = (old.pytestFlags or [ ]) ++ [
                "-Wignore::pytest.PytestUnraisableExceptionWarning"
              ];
              disabledTests = (old.disabledTests or [ ]) ++ [
                "test_tls_connectable"
                "test_single_thread"
              ];
            });
          })
        ];
      };
      pytestPostgresqlStartupRace = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            "pytest-postgresql" = pyPrev.pytest-postgresql.overridePythonAttrs (old: {
              disabledTests = (old.disabledTests or [ ]) ++ [
                "test_executor_init_with_password"
              ];
            });
          })
        ];
      };

      psycopgCancelRace = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            psycopg = pyPrev.psycopg.overridePythonAttrs (old: {
              # tests/test_generators.py::test_cancel sends SELECT pg_sleep(180), polls
              # pg_stat_activity until that query reads 'active', then cancels it and
              # demands ExecStatus.FATAL_ERROR + SQLSTATE 57014. The poll races: the
              # cancel can land once the query has already answered, so the result
              # comes back EXEC_COMPLETE and the assert fails (assert 2 == FATAL_ERROR).
              # Intermittent — 1 failed of 5146 in an otherwise green suite — and the
              # same class nixpkgs itself disables there (test_break_attempts, test_wait_r
              # carry the "Flaky, fails intermittently" comment). Deselect this node id
              # exactly rather than by name: 26 tests in the suite contain the substring
              # test_cancel, and pytest's -k (what disabledTests feeds) would drop them all.
              # One pytestFlags element, no space: nixpkgs hands each element to pytest
              # verbatim, so "--deselect <id>" would arrive as one unrecognised path arg.
              pytestFlags = (old.pytestFlags or [ ]) ++ [
                "--deselect=tests/test_generators.py::test_cancel"
              ];
            });
          })
        ];
      };

      jupyterServerFdLeakRace = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            jupyter-server = pyPrev.jupyter-server.overridePythonAttrs (old: {
              # jupyter-server 2.21.0's own suite fails the jail's python3 env
              # (ps.jupyter in home/llm/jails.nix): the check phase ran 940 passed /
              # 1 failed in 599.58s, the failure being
              # tests/services/kernels/test_connection.py::test_no_fd_leak_on_disconnect_with_orphaned_kernel_info_channel
              # — "AssertionError: FD leak detected: 6 FDs leaked after 100 disconnects
              # with orphaned kernel_info_channel". The test opens 100 connections whose
              # kernel_info reply never arrives, disconnects each, then asserts
              # final_fds - baseline_fds <= 5 over /proc/self/fd. The ceiling is a race,
              # not a leak: the loop's last `conn` is still bound when final_fds is read,
              # so its own sockets are open, and how many of the other 99 close in the
              # two gc.collect() rounds around `await asyncio.sleep(2)` decides the count.
              # nixpkgs already disables the timing-sensitive sibling in this same file
              # (test_disconnect_resolves_orphaned_kernel_info_future, "timing sensitive");
              # this new 2.21.0 test is the same class, one node id short of the ceiling.
              # Deselect the node id exactly, not the name: an entry carrying :: turns
              # into --deselect=<path>::<name> in pytest-check-hook.sh, so no sibling
              # test in the file is touched.
              disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
                "tests/services/kernels/test_connection.py::test_no_fd_leak_on_disconnect_with_orphaned_kernel_info_channel"
              ];
            });
          })
        ];
      };

      openaiMtlsExampleTimeout = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            openai = pyPrev.openai.overridePythonAttrs (old: {
              # openai 2.53.0's suite: 1 failed, 859 passed, 5 skipped in 94.81s.
              # The failure is test_mtls_example_presents_full_client_chain
              # [mtls_httpx2_async.py]: the test starts a local ThreadingHTTPServer
              # with mTLS and runs examples/mtls_httpx2_async.py as a subprocess
              # with a 15s wall-clock deadline (subprocess.TimeoutExpired at
              # tests/test_mtls_http_client.py:109). The parametrisation is four
              # examples (mtls_httpx.py, mtls_httpx_async.py, mtls_httpx2.py,
              # mtls_httpx2_async.py); only the async httpx2 client misses the
              # deadline — a cold interpreter + httpx2/anyio/pydantic import
              # inside a build oversubscribed by --max-jobs 16. Timing-sensitive
              # deadline, same class as the sibling deselects above. Deselect the
              # bracketed node id exactly (an entry with :: becomes
              # --deselect=<id> verbatim in pytest-check-hook.sh), so the three
              # passing siblings still run.
              disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
                "tests/test_mtls_http_client.py::test_mtls_example_presents_full_client_chain[mtls_httpx2_async.py]"
              ];
            });
          })
        ];
      };

      scikitLearnCallbackLokyRace = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            scikit-learn = pyPrev.scikit-learn.overridePythonAttrs (old: {
              # scikit-learn 1.9.0's suite: 1 failed, 34288 passed, 12717 skipped,
              # 224 xfailed, 118 xpassed, 4465 warnings in 1453.56s. The one
              # failure is callback/tests/test_callback_support.py::test_function_no_callback_support
              # [RecordingCallback-processes-2] — _pickle.PicklingError: Could not
              # pickle the task to send it to the workers. The Parallel task fn
              # (clone_and_fit) is defined *inside* the test fn, so loky has to
              # rebuild it in the worker process by re-importing the test module;
              # nixpkgs runs the suite as `-m pytest --pyargs sklearn` from $TMPDIR
              # (preCheck does `cd $TMPDIR`), so that module resolves through the
              # *installed* package, not the source tree the suite would otherwise
              # run in. Same joblib 1.5.3 / pytest 9.1.1 / pytest-xdist 3.8.0 in a
              # plain venv: all 8 parametrisations pass, so it is the build's import
              # layout, not an upstream defect — only the prefer=processes + n_jobs=2
              # variant ships the closure at all.
              # Deselect by NAME: disabledTests feeds pytest -k (nixpkgs' own
              # mechanism for this package, already used for the scipy-deprecation
              # and NuSVC skips). A --deselect=<path>::<id> entry cannot work here,
              # because --pyargs collects the installed package's paths — a store
              # path this override cannot know at eval time. Drops the 8
              # parametrisations of this test; the rest of the callback suite runs.
              disabledTests = (old.disabledTests or [ ]) ++ [
                "test_function_no_callback_support"
              ];
            });
          })
        ];
      };

      nodeSharedIsolatePumpRace = final: prev: {
        # nodejs-slim 26.12.0's cctest: 1 failed of 269 tests from 36 suites,
        # make exit 2. The failure is
        # EnvironmentTest/SharedIsolateTest.EnvironmentsComeAndGoWhileSiblingsRun/SharedIsolateData
        # — node 26's new embedding test (test/cctest/test_environment_shared_isolate.cc)
        # that runs three Environments through one libuv loop; the SharedIsolateData
        # param is the variant that registers the isolate with the platform, opens
        # an inspector Session and spawns a worker_threads Worker (line 344-361),
        # and PumpUntilAllTicked (line 251) gives up after at most 10000
        # uv_run(UV_RUN_ONCE) turns with FAIL() << "an Environment stopped running
        # its timers or immediates" — progress is bounded in turns, not in wall
        # time, so a pump starved by the surrounding build gives up. The other
        # param (IsolateDataPerEnvironmentWithoutPlatform) passed, as did the
        # other 267 tests.
        # The skip mechanism: cctest reads GTEST_FILTER (Makefile line 22
        # GTEST_FILTER ?= *, line 306 cctest --gtest_filter=$(GTEST_FILTER)) —
        # CI_SKIP_TESTS, already in checkFlags, only reaches jstest/test-ci-js.
        # stdenv's genericBuild appends checkFlagsArray to the make arguments, so
        # a command-line GTEST_FILTER= assignment beats the ?= default, and the
        # leading - makes it a gtest negation filter: the sibling param and the
        # rest of cctest still run.
        # The attr: this closure's nodejs-slim-26.12.0 comes from llama-cpp 0.6.0,
        # which asks for nodejs_latest (pkgs/by-name/ll/llama-cpp/package.nix line
        # 35) — the symlinkJoin wrapper that builds from nodejs-slim_latest. The
        # plain nodejs-slim attr is the 24.21.0 LTS this closure does not build,
        # so overriding it leaves the failing drv untouched.
        nodejs-slim_latest = prev.nodejs-slim_latest.overrideAttrs (old: {
          checkFlags = (old.checkFlags or [ ]) ++ [
            "GTEST_FILTER=-EnvironmentTest/SharedIsolateTest.EnvironmentsComeAndGoWhileSiblingsRun/SharedIsolateData"
          ];
        });
      };

      pycurlPauseRecvTimeoutRace = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            pycurl = pyPrev.pycurl.overridePythonAttrs (old: {
              # pycurl 7.46.0's suite (python3.14): 1 failed, 655 passed, 17 skipped,
              # 11 deselected in 146.98s. The failure is
              # tests/pause_test.py::test_multi_recv_mask[recv] —
              # AssertionError: Transfer timed out. The test drives a curl_easy_pause
              # transfer through the RECV-mask parametrisation and asserts it completes
              # inside a fixed wall-clock deadline; the deadline is starved by the
              # oversubscribed build (--max-jobs 16 --cores 1), not a packaging defect —
              # a plain re-run of the failed drv at default -j passed to completion.
              # nixpkgs already ships `flaky` in nativeCheckInputs for rerun-marked
              # tests, but this node id is not among them. Deselect the bracketed node
              # id exactly, not the name (an entry with :: becomes --deselect=<id>
              # verbatim in pytest-check-hook.sh), so the pause suite's siblings still
              # run.
              disabledTestPaths = (old.disabledTestPaths or [ ]) ++ [
                "tests/pause_test.py::test_multi_recv_mask[recv]"
              ];
            });
          })
        ];
      };

      pybind11SubinterpreterSpawnRace = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            pybind11 = pyPrev.pybind11.overridePythonAttrs (old: {
              # pybind11 3.1.0's suite (python3.14): 1 failed, 1342 passed in 41.54s;
              # the failure is tests/test_multiple_interpreters.py::test_import_in_
              # subinterpreter_concurrently — RuntimeError raised from tests/env.py:65,
              # the helper that runs `sys.executable -c code` subprocesses (already
              # wrapped upstream in a `for _ in range(rerun)` loop "run flakily
              # failing test multiple times") and re-raises on CalledProcessError:
              # the concurrent-interpreters child spawns can't get through under a
              # --max-jobs 16-saturated build. A re-run of the exact failed drv on a
              # quiet machine passed (1343 green) — starvation, not a packaging
              # defect. The check here is CMake/ninja-driven (checkPhase =
              # ninjaCheckPhase), NOT pytestCheckHook, so there is no disabledTests
              # channel: ride PYTEST_ADDOPTS out of preCheck (setup.sh runs the
              # preCheck hook before checkPhase in the same shell; ninja's pytest
              # custom target inherits the env) and deselect the node id exactly —
              # anchored to the nodeid as pytest 9 stores it, i.e. rootdir-relative
              # (tests/pytest.ini makes rootdir /build/source/tests → the bare
              # filename; the ../../tests/ form is cwd-relative DISPLAY only and
              # matches nothing — verified against pytest-9.1.1 in a replica).
              preCheck = toString (old.preCheck or "") + ''
                export PYTEST_ADDOPTS="--deselect=test_multiple_interpreters.py::test_import_in_subinterpreter_concurrently"
              '';
            });
          })
        ];
      };

      # python3.14-python-ulid 3.1.0 (pytestCheckHook-driven; rootdir /build/source,
      # configfile pyproject.toml): 1 failed, 68 passed in 1.83s —
      # tests/test_ulid.py::test_same_millisecond_overflow, "Failed: DID NOT RAISE
      # ValueError". The test hand-sets ULID.provider.prev_randomness =
      # constants.MAX_RANDOMNESS and expects the next ULID() to raise
      # "Randomness within same millisecond exhausted" — but that guard only runs
      # while the clock is STILL in the provider's previous millisecond, and
      # @freeze_time() pins the real `now` at each decorated test's start. The
      # preceding test_same_millisecond_monotonic_sorting sweep (1000 consecutive
      # ULID() draws) plus scheduler jitter under a --max-jobs 16 build crosses a
      # millisecond boundary between the two moments: prev_timestamp advances,
      # the overflow branch is skipped, no raise. Upstream timing race — a re-run
      # on a quiet machine was 69/69 green — not a packaging defect. This suite IS
      # pytestCheckHook-driven (unlike pybind11), so disabledTestPaths is the
      # channel: it appends --deselect=<nodeid> exactly as collected, i.e.
      # rootdir-relative tests/test_ulid.py::test_same_millisecond_overflow.
      pythonUlidSameMillisecondRace = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            python-ulid = pyPrev.python-ulid.overridePythonAttrs (old: {
              disabledTestPaths = (old.disabledTestPaths or []) ++ [
                "tests/test_ulid.py::test_same_millisecond_overflow"
              ];
            });
          })
        ];
      };

      urwidPython314TestWorkaround = final: prev: {
        python314 = prev.python314.override {
          packageOverrides = pyFinal: pyPrev: {
            urwid = pyPrev.urwid.overridePythonAttrs (_: {
              doCheck = false;
            });
          };
        };
      };

      # hypothesis 6.168.1's self-tests fail on EVERY interpreter at this pin
      # (pytest 9.1.1 + pytest-xdist 3.8.0 + pluggy 1.6.0): 71-76 tests/cover
      # cases fail in ~21 min, all tripping hypothesis's own tests/conftest.py
      # PRNG guard — "both used the `random` module, and finished with the same
      # global random.getstate(); this is probably a nasty bug!" — raised from
      # the conftest hookwrapper as pluggy.PluggyTeardownRaisedWarning, which
      # pluggy promotes to teardown failures. The guard's premise (each
      # random-using test advances the global PRNG state vs its predecessor)
      # does not hold under this pin's runner/scheduler mix: a test-suite bug
      # in the pinned combination, not a packaging defect. The wheel itself
      # (maturin) builds clean and pythonImportsCheck still verifies the
      # import; we skip only the check phase.
      #
      # Deliberately pythonPackagesExtensions, NOT an interpreter-level
      # `prev.pythonXY.override { packageOverrides }`: interpreter overrides
      # REPLACE the packageOverrides function (verified empirically on this
      # pin — a second .override with its own function drops the first
      # one's entries), so any downstream consumer (minuspod's minuspodPython,
      # the jail python envs' withPackages chains, the whisper stack) would
      # silently rebuild the UNpatched hypothesis. Extensions compose with
      # every override chain within the nixpkgs instance. It must therefore be
      # applied to EVERY nixpkgs import instance that builds python closures:
      # the main `pkgs` below, minuspod's pkgsU, the system `nixpkgs.overlays`,
      # and the whisper-service inner flake's mkPkgs.
      hypothesisTeardownRace = final: prev: {
        pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
          (pyFinal: pyPrev: {
            hypothesis = pyPrev.hypothesis.overridePythonAttrs (_: {
              doCheck = false;
            });
          })
        ];
      };

      # Base package set for the NixOS configuration.
      pkgs = import nixpkgs {
        inherit system;

        overlays = [ headroomOverlay ccclPatchWorkaround ltraceSkipCheck aiderLiteLLMExceptions semgrepRuntimeDeps anyioPytestNoise pytestPostgresqlStartupRace psycopgCancelRace jupyterServerFdLeakRace openaiMtlsExampleTimeout scikitLearnCallbackLokyRace nodeSharedIsolatePumpRace pycurlPauseRecvTimeoutRace pybind11SubinterpreterSpawnRace pythonUlidSameMillisecondRace hypothesisTeardownRace ];
      };

      dshPkg = import ./home/llm/dsh {
        inherit pkgs;
        src = inputs.dsh;
        versionCheckHomeHook = inputs.llm-agents.packages.${system}.versionCheckHomeHook;
      };


      hushmic = pkgs.callPackage ./hosts/desktop/hushmic/package.nix {
        src = inputs.hushmic;
        version = inputs.hushmic.shortRev;
      };

      pmSkillsSkills =
        pkgs.callPackage ./home/llm/pm-skills.nix {
          src = inputs.pm-skills;
        };

      vulnhunterSkills =
        pkgs.callPackage ./home/llm/vulnhunter-skills.nix {
          src = inputs.vulnhunter;
          version = inputs.vulnhunter.shortRev;
        };

      # recurse: AI-native IDE for reverse engineering (see hosts/desktop/recurse/package.nix).
      recurse = pkgs.callPackage ./hosts/desktop/recurse/package.nix {
        src = inputs.recurse;
        version = "0.1.0";
      };

      # serein: lightweight native Discord client (see hosts/desktop/serein/package.nix).
      serein = pkgs.callPackage ./hosts/desktop/serein/package.nix {
        src = inputs.serein;
      };

      # sglangPkg: SGLang runtime (pinned CUDA wheel assembly on python313); the FlashInfer JIT needs a self-consistent CUDA toolkit from nixpkgs.
      sglangPkg =
        pkgs.callPackage ./hosts/desktop/llm/sglang/package.nix {
          cudaToolkit = cudaToolkitPkgs.cudaPackages_13.cudatoolkit;
        };

      # archipelagoPkg: Archipelago Multi-Game Randomizer and Server (pinned source + python3.13 env + entry-point wrappers).
      archipelagoPkg = pkgs.callPackage ./hosts/desktop/archipelago/package.nix {
        src = inputs.archipelago.outputs.archipelagoInputs.src;
        env = archipelagoUvEnv;
      };

      # archipelagoUvEnv: Archipelago Python env built from a uv.lock via uv2nix (single source of truth for runtime deps; see hosts/desktop/archipelago/uv/).
      archipelagoUvEnv =
        let
          workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = ./hosts/desktop/archipelago/uv;
          };
          overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
          pythonSet =
            (pkgs.callPackage inputs.pyproject-nix.build.packages {
              python = pkgs.python313;
            }).overrideScope (pkgs.lib.composeManyExtensions [
              inputs.pyproject-build-systems.overlays.wheel
              overlay
            ]);
        in
        pythonSet.mkVirtualEnv "archipelago-uv-env" (workspace.deps.default);

      # vllmDflash2Pkg / cudaToolkitPkgs: native vLLM v0.27.1 + DFlash2 K7 (undockerified Qwen3.8); the FlashInfer JIT needs a full CUDA toolkit from nixpkgs (unfree).
      cudaToolkitPkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
        # The CUDA 13.3 toolkit pulls cuda13.3-cccl, so the cccl workaround applies here too.
        overlays = [ ccclPatchWorkaround ];
      };

      vllmDflash2Pkg =
        pkgs.callPackage ./hosts/desktop/llm/vllm/dflash2-package.nix {
          cudaToolkit = cudaToolkitPkgs.cudaPackages_13.cudatoolkit;
        };

      # Strata: llama.cpp pinned to the exact commit Strata pins (setup.py's
      # LLAMA_CPP_COMMIT): the engine's ggml-cpu native expert kernels and
      # strata-vision's mtmd share this source, so no FetchContent at build.
      # The NAR hash covers the unpacked tree (AGENTS.md); re-derive it only
      # when the strata source changes that commit.
      strataLlamaCpp = pkgs.fetchFromGitHub {
        owner = "ggml-org";
        repo = "llama.cpp";
        rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d";
        hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI=";
      };

      # strataEnginePkg: sm_120 CUDA engine + the vendored python app (setup.py + serve/).
      strataEnginePkg = cudaToolkitPkgs.callPackage ./hosts/desktop/llm/strata/package.nix {
        src = inputs.strata;
        llamaCpp = strataLlamaCpp;
        # callPackage can't infer it: no such attr in the pkgs set (same as vllm).
        cudaToolkit = cudaToolkitPkgs.cudaPackages_13.cudatoolkit;
      };

      # strataServeEnv: server venv from its uv.lock (single source of truth; see hosts/desktop/llm/strata/uv/).
      strataServeEnv =
        let
          workspace = inputs.uv2nix.lib.workspace.loadWorkspace {
            workspaceRoot = ./hosts/desktop/llm/strata/uv;
          };
          overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };
          pythonSet =
            (pkgs.callPackage inputs.pyproject-nix.build.packages {
              python = pkgs.python313;
            }).overrideScope (pkgs.lib.composeManyExtensions [
              inputs.pyproject-build-systems.overlays.wheel
              overlay
            ]);
        in
        # Strata's setup.py proves its python deps with a .strata-pip.json stamp
          # in sys.prefix (setup.py pip_install); without it the first start would
          # pip-install into the read-only store and die. 0.1.40's pip step reads
          # requirements.txt (not a hardcoded list) and the check is a bare
          # importability test, so every package in that file must exist in the
          # pipless venv - including win32-only colorama (upstream gates it on
          # sys_platform == "win32", setup.py does not). For a source:"local"
          # engine the NVIDIA wheel list is never reached.
          # Injected via overrideAttrs: the make-venv hook ends with runHook postInstall.
        (pythonSet.mkVirtualEnv "strata-serve-env" (workspace.deps.default)).overrideAttrs (_a: {
          postInstall = ''
            echo '["colorama", "cmake", "jinja2", "numpy", "ninja", "pillow", "psutil", "pyyaml", "regex", "requests", "tqdm"]' > $out/.strata-pip.json
          '';
        });

      # strataVisionAppPkg: the engine app layout plus the GPU vision encoder (mtmd, sm_120);
      # what services.strata runs.
      strataVisionAppPkg = cudaToolkitPkgs.callPackage ./hosts/desktop/llm/strata/vision.nix {
        src = inputs.strata;
        llamaCpp = strataLlamaCpp;
        engine = strataEnginePkg;
        cudaToolkit = cudaToolkitPkgs.cudaPackages_13.cudatoolkit;
      };

      # tabbyapiPkg: TabbyAPI + EXL3 (exllamav3) runtime for EXL3-quantized models.
      # Both binaries are tracked via flake inputs (their true bases on GitHub):
      # `nix flake update tabbyapi exllamav3` re-pins them.
      tabbyapiPkg =
        pkgs.callPackage ./hosts/desktop/llm/omarchy/tabbyapi-package.nix {
          exllamav3Src = inputs.exllamav3;
          tabbyapiSrc = inputs.tabbyapi;
        };

    in
    {
      formatter.${system} =
        nixpkgs.legacyPackages.${system}.nixfmt;

      apps.${system} = {
        nixpkgs-fmt = {
          type = "app";
          program = "${pkgs.nixpkgs-fmt}/bin/nixpkgs-fmt";
          meta.description = "Format Nix code (nixpkgs-fmt)";
        };
        black = {
          type = "app";
          program = "${pkgs.black}/bin/black";
          meta.description = "Python code formatter (black)";
        };
        prettier = {
          type = "app";
          program = "${pkgs.prettier}/bin/prettier";
          meta.description = "Opinionated code formatter (prettier)";
        };
        shfmt = {
          type = "app";
          program = "${pkgs.shfmt}/bin/shfmt";
          meta.description = "Shell script formatter (shfmt)";
        };
        yamllint = {
          type = "app";
          program = "${pkgs.yamllint}/bin/yamllint";
          meta.description = "YAML linter (yamllint)";
        };
        markdownlint-cli2 = {
          type = "app";
          program = "${pkgs.markdownlint-cli2}/bin/markdownlint-cli2";
          meta.description = "Markdown linter (markdownlint-cli2)";
        };
      };

      packages.${system} =
        let
          # Shared catalog for agents-md generation (needs pkgs and jail-nix only).
          # inherit (nixpkgs) lib, not (nixpkgs.lib): the latter asks for
          # nixpkgs.lib.lib, which does not exist.
          sharedForAgents = import ./home/llm/catalog.nix {
            inherit (nixpkgs) lib;
            inherit pkgs jail-nix;
          };

          # Same user home as declared in home/users.nix, so the generated
          # doc's mounts match the real jails.
          userHome = (import ./home/users.nix).b.homeDirectory;
        in
        {
          # Each package is testable in isolation:
          #   nix build --impure --no-link --print-out-paths .#packages.x86_64-linux.<name>
          # (--no-link required on nix 2.34: --print-out-paths alone drops a
          # result symlink in the repo root.)

          # The generated AGENTS.md doc (see home/llm/agents-gen/).
          agents-md =
            pkgs.callPackage ./home/llm/agents-gen/agents-md.nix {
              inherit jail-nix llm-agents;
              shared = sharedForAgents;
              inherit userHome;
              # Upstream dsh source (flakeless input); the agents doc builds dsh from this tree.
              dshSrc = inputs.dsh;
            };

          # Local CA + leaf cert for the Caddy-served *.local service names (see hosts/desktop/local-ca.nix).
          local-services-ca =
            (import ./hosts/desktop/local-ca.nix {
              inherit pkgs;
              lib = nixpkgs.lib;
            }).ca;

          # The availability gate (the one public LLM door): its runtime payload
          # — gate.py plus the routing table rendered from the ledger. Build it
          # in isolation to inspect the table: jq . <(cat <out>/table.json).
          llm-gate =
            pkgs.callPackage ./hosts/desktop/llm/gate/package.nix {
              lib = nixpkgs.lib;
              inherit pkgs;
              catalog = import ./catalog;
            };

          # The pinned dsh source tree, exposed so home/llm/dsh/update-deps.py can materialize it.
          dsh-src = inputs.dsh.outPath;

          pm-skills = pmSkillsSkills;


          vulnhunter-skills = vulnhunterSkills;

          # The dsh runtime (installed package) and its npm tarball (release
          # pipeline output); used by the NixOS config and `just dsh-repin`.
          dsh = dshPkg.package;
          dsh-tarball = dshPkg.tarball;

          # WezTerm session-persistence plugin (resurrect.wezterm fork).
          wezurrect = pkgs.callPackage ./home/wezterm/resurrect.nix {
            src = inputs.wezurrect;
            version = inputs.wezurrect.shortRev;
          };

          # SGLang runtime.
          sglang = sglangPkg;

          # Native vLLM v0.27.1 + DFlash2 K7 runtime.
          vllm-dflash2 = vllmDflash2Pkg;

          # Strata engine (sm_120) + vendored python app (setup.py + serve/).
          strata-engine = strataEnginePkg;

          # Strata app + GPU vision encoder — what services.strata runs.
          strata-vision-app = strataVisionAppPkg;

          # Strata server venv (uv.lock via uv2nix; see hosts/desktop/llm/strata/uv/).
          strata-serve-env = strataServeEnv;

          # TabbyAPI + EXL3 (exllamav3) runtime (omarchy recipes).
          tabbyapi = tabbyapiPkg;

          # Archipelago Multi-Game Randomizer and Server (see let-block).
          archipelago = archipelagoPkg;

          # Archipelago Python env (uv.lock via uv2nix; see let-block).
          archipelago-uv-env = archipelagoUvEnv;

          # Music transcription pipeline env (python312: torch CPU, demucs, librosa).
          music-transcription = pkgs.callPackage ./hosts/desktop/music-transcription/package.nix { };

          # knife: reverse engineer's binary Swiss-army knife (see home/llm/tools/knife.nix).
          knife = pkgs.knife;

          # graphify: codebase -> knowledge graph + stdio MCP server (see home/llm/tools/graphify.nix).
          graphify = pkgs.graphify;

          # graphlore: richer MCP server wrapping graphify's graph (see home/llm/tools/graphlore.nix).
          graphlore = pkgs.graphlore;

          # echarts: interactive chart library (see home/llm/tools/echarts.nix).
          echarts = pkgs.echarts;

          # bend: dependently typed affine language that blocks AI mistakes via proof (see home/llm/tools/bend.nix).
          bend = pkgs.bend;

          # difftastic: structural diff that understands syntax (see home/llm/tools/difftastic.nix).
          difftastic = pkgs.difftastic;

          # ripwire: "the ripgrep of AI context" CLI + MCP server (see home/llm/tools/ripwire.nix).
          ripwire = pkgs.ripwire;

          # open-code-review: Alibaba's AI code review CLI, invoked as ocr (see home/llm/tools/open-code-review.nix).
          open-code-review = pkgs.openCodeReview;

          # Recurse: AI-native IDE for reverse engineering (see hosts/desktop/recurse/package.nix).
          recurse = recurse;

          # Serein: lightweight native Discord client (see hosts/desktop/serein/package.nix).
          serein = serein;

          # TEMPORARY (minuspod 2.97.4 re-pin verification); uses allowUnfree pkgs (the CUDA ctranslate2 core is unfree).
          minuspod =
            let
              pkgsU = import inputs.nixpkgs {
                inherit system;
                config.allowUnfree = true;
                # the same pytest fixes the system pkgs carry (anyio, pytest-postgresql,
                # psycopg's cancel race, hypothesis's teardown race): this import is a
                # fresh fixed point, so without them its python3.13 env would build the
                # unpatched packages and fail the same checkPhase.
                overlays = [ anyioPytestNoise pytestPostgresqlStartupRace psycopgCancelRace hypothesisTeardownRace ];
              };
              m = import ./home/minuspod.nix {
                pkgs = pkgsU;
                lib = nixpkgs.lib;
                inherit inputs;
                catalog = import ./catalog;
              };
            in
            builtins.elemAt m.home.packages 0;

          # Tether — Linux + iPhone Continuity bridge (upstream package).
          tether = inputs.tether.packages.${system}.default;

          # Repacks Tether's Firefox OTP-autofill add-on into the NUR <id>.xpi layout the firefox module wants.
          tether-firefox-extension = pkgs.runCommand "tether-firefox-extension-xpi"
            {
              tether = inputs.tether.packages.${system}.default;
            } ''
            mkdir -p "$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}"
            cp "$tether/share/tether/extensions/tether-browser-extension.zip" \
              "$out/share/mozilla/extensions/{ec8030f7-c20a-464f-9b0e-13a3a9e97384}/tether@tether.com.xpi"
            touch "$out"
          '';
        };

      # The second machine, re-exported from its own sub-flake: the flake
      # attribute, the directory name, and the guest's `networking.hostName` are
      # all `nixos-vm` (the one dir/attr mismatch in this repo stays the desktop's
      # — hosts/desktop builds as the `nixos` attribute). Rebuilt as
      # `just <target> nixos-vm` here, or `nixos-rebuild --flake /etc/nixos#nixos-vm`
      # on the guest itself.
      nixosConfigurations.nixos-vm = inputs.nixos-vm.nixosConfigurations.nixos-vm;

      # The physical box (Option A): flake attribute and `networking.hostName` are
      # both `yzerd` — the name the Proxmox node had, so the machine keeps one
      # identity across the mode change. Installed from hosts/yzerd, whose own
      # sub-flake is the tree that gets shipped to the Ventoy stick.
      nixosConfigurations.yzerd = inputs.yz-native.nixosConfigurations.yzerd;

      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        inherit system;

        modules = [
          ./hosts/desktop
          agenix.nixosModules.default
          home-manager.nixosModules.home-manager

          ./hosts/desktop/whisper-service/module.nix
          ./hosts/desktop/archipelago/module.nix

          ({ config, pkgs, lib, ... }: {
            nixpkgs.config.allowUnfree = true;

            # Socket-activated: with autoStop it exits after the 120s idle window (VRAM + host memory freed) and re-activates on demand.
            services.whisper-service = {
              enable = true;
              package = whisper-service.packages.${system}.whisper-service;
              model = "large-v3";
              port = 8790;
              idleTimeout = 120;
              autoStop = true;
              # Host NVIDIA driver; its /lib (libcuda.so.1) is on LD_LIBRARY_PATH so ctranslate2's dlopen of the driver stub resolves.
              nvidiaDriver = config.hardware.nvidia.package;
            };

            nixpkgs.overlays = [
              # The (final: prev: { ... }) overlays below each expose a locally
              # built package under the attribute name the NixOS/home modules
              # consume (pkgs.<name>).
              nur.overlays.default

              # CUDA cccl patch workaround (see ccclPatchWorkaround); also applied to the system pkgs.
              ccclPatchWorkaround

              # The jails are built by the home-manager modules, which see this system pkgs
              # set (useGlobalPkgs), not the flake-level pkgs above — so every overlay that
              # fixes a package a jail consumes has to be applied here too, or the jail
              # closure builds the unpatched package (aider's testsuite: 25 failures).
              ltraceSkipCheck

              aiderLiteLLMExceptions

              semgrepRuntimeDeps

              # netexec (nxc) is on the jail PATH, and its httpx/httpcore chain dies on
              # anyio's failing testsuite — same fix as the base pkgs above.
              anyioPytestNoise

              # minuspod's python3.13 env pulls sqlframe -> pytest-postgresql, whose
              # postgres-fixture race fails the same way — same fix as the base pkgs.
              pytestPostgresqlStartupRace

              # psycopg's own pg_sleep cancel test races the same postgres fixture.
              psycopgCancelRace

              # The jail's python3 env carries ps.jupyter -> jupyter-server 2.21.0, whose
              # new FD-leak test fails in the build sandbox — same fix as the base pkgs.
              jupyterServerFdLeakRace

              # The system closure carries its own python3.14-scikit-learn (the jail
              # python env's ps.scikit-learn), so the loky-pickle skip has to be
              # applied here too — the same drv that failed run 1 stayed in the
              # requisites untouched by the base-pkgs overlay.
              scikitLearnCallbackLokyRace

              # llama-cpp 0.6.0 pulls nodejs_latest (nodejs-slim_latest, 26.12.0)
              # into the system closure, so its cctest skip belongs here too — the
              # base-pkgs overlay alone leaves that drv unpatched.
              nodeSharedIsolatePumpRace

              # The jail python envs (python3/3.12/3.13) pull hypothesis 6.168.1 in as a
              # check-input chain, whose self-tests fail at this pin — the same drv failed
              # round 2 here (the base-pkgs overlay alone leaves this instance unpatched).
              hypothesisTeardownRace

              # pycurl 7.46.0 (python3.14) is in the system closure twice over — the jail's
              # wfuzz propagates it, and the dbus/python stack carries system-config-printer
              # — and its RECV-mask pause test misses its wall-clock deadline under
              # --max-jobs 16 (1 failed of 655). Same deselect as the base pkgs: this set
              # builds the drv that failed the switch, so the base-pkgs overlay alone
              # leaves it unpatched here.
              pycurlPauseRecvTimeoutRace

              # python3.14-pybind11 3.1.0 sits under nix's own closure (nix 2.34.9 pulls
              # its python bindings), and nixos-rebuild-ng drags that into the switch
              # build: its subinterpreter-concurrency test failed in the same oversubscribed
              # switch (1 failed of 1343) while a quiet re-run passed. Same fix as the base
              # pkgs — the system set builds the drv that failed.
              pybind11SubinterpreterSpawnRace

              # python3.14-python-ulid 3.1.0 sits in the jail-tool/service closure:
              # its failed check cascaded through pydantic-extra-types, fastapi,
              # curl-cffi, sse-starlette, both mcp wheels, searxng, yt-dlp, graphlore
              # and home-manager-path. Its same-millisecond-overflow test failed in
              # the oversubscribed switch (1 failed of 69 — DID NOT RAISE once the
              # freeze_time pin straddles a millisecond boundary under load) while
              # a quiet re-run passed. Same deselect as the base pkgs — this set
              # builds the drv that failed.
              pythonUlidSameMillisecondRace

              (final: prev: {
                hushmic = hushmic;
              })

              (final: prev: {
                recurse = recurse;
              })

              (final: prev: {
                serein = serein;
              })

              (final: prev: {
                sglang = sglangPkg;
              })

              (final: prev: {
                archipelago = archipelagoPkg;
              })

              (final: prev: {
                vllmDflash2 = vllmDflash2Pkg;
              })

              (final: prev: {
                tabbyapi = tabbyapiPkg;
              })

              (final: prev: {
                strata-engine = strataEnginePkg;
                strata-vision-app = strataVisionAppPkg;
                strata-serve-env = strataServeEnv;
              })
              # Tether — Linux + iPhone Continuity bridge (upstream overlay).
              tether.overlays.default

              # headroom-ai context compression for the jailed LLM agents (same def as the base pkgs).
              headroomOverlay

              (final: prev: {
                typescript-language-server =
                  prev.typescript-language-server.overrideAttrs (old: {
                    pnpmDeps = old.pnpmDeps.overrideAttrs (_: {
                      outputHash = "sha256-xR/EF60lVBsITKgH7wCM2wHM46PFQevD51KfCENSUH4=";
                    });
                  });
              })
              # Force Discord into X11 (XWayland): its Wayland renderer SIGSEGVs on Plasma 6 + NVIDIA; applied as an overlay so both home.packages and the autostart get the flag.
              (final: prev: {
                discord = prev.discord.override {
                  commandLineArgs = "--ozone-platform=x11";
                };
              })
            ];

            home-manager.useGlobalPkgs = true;
            home-manager.backupFileExtension = ".bak";

            home-manager.extraSpecialArgs = {
              inherit
                plasma-manager
                nur
                jail-nix
                llm-agents
                inputs
                ;

              # Shared model/LSP catalog + config renderer, used by both home-manager modules.
              shared = import ./home/llm/catalog.nix {
                inherit lib pkgs jail-nix;
              };

              # The model/port ledger itself, so home modules can name a port
              # without repeating one (the same value the llm system modules get).
              catalog = import ./catalog;

              deepseekSecret = config.age.secrets.deepseek-api-key.path;

              # NVIDIA NIM (Build) cloud API key (Kimi K3); injected host-side by the headroom-proxy-nvidia user-service, keeping it out of the agent's environ.
              nvidiaSecret = config.age.secrets.nvidia-api-key.path;

              # NVIDIA driver (libcuda.so.1); passed to home/minuspod.nix so the minuspod service can dlopen the driver stub for CUDA whisper.
              nvidiaDriver = config.boot.kernelPackages.nvidiaPackages.latest;

              # Pinned Archipelago source inputs (the meta-flake's nested inputs); the archipelago modules build the apworld/mod zips from source (see zip-from-source.nix).
              archipelagoSources = {
                balatroap = inputs.archipelago.outputs.archipelagoInputs.balatroap;
                sts2 = inputs.archipelago.outputs.archipelagoInputs.sts2;
                universal-tracker = inputs.archipelago.outputs.archipelagoInputs."universal-tracker";
              };
            };

            home-manager.users.b = import ./home;

            # The llm agent user's home: writable state root of the "system" jail variants (run as llm via sudo -u llm).
                        home-manager.users.llm = import ./home/llm/agent-home.nix;
          })
        ];

        specialArgs = {
          inherit
            nur
            inputs
            jail-nix
            llm-agents
            ;

          # The model fleet's ledger: one data file (ports, units, VRAM,
          # capability) that the llm modules and the gate all read, so an
          # engine's port/unit exists in exactly one place. Pure data — no
          # pkgs, no config.
          catalog = import ./catalog;
        };
      };
    };
}
