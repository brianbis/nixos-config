# Local tooling overlay for the jailed LLM agents.
#
# Single source of truth for the locally-built agent tools. flake.nix applies it
# at two sites from this one definition:
#   - the base `pkgs` (so pkgs.headroom / pkgs.knife / pkgs.graphify /
#     pkgs.graphlore exist for every consumer of this flake's pkgs, including
#     the agents-md build)
#   - the NixOS system's nixpkgs.overlays
#
# Takes the headroom, knife, graphify, graphlore, echarts, bend, difftastic
# and ripwire source trees (all flakeless inputs, threaded in from flake.nix)
# so `nix flake update <name>` re-pins each. open-code-review is the
# exception: it is pinned to a release tag inside ./open-code-review.nix
# (fetchFromGitHub), so it takes no source argument.
headroomSrc: knifeSrc: graphifySrc: graphloreSrc: echartsSrc: bendSrc: difftasticSrc: ripwireSrc: final: prev: {
  python3 = prev.python3.override {
    packageOverrides = pyfinal: pyprev: {
      ast-grep-cli =
        pyfinal.callPackage ./ast-grep-cli.nix {
          ast-grep = prev.ast-grep;
        };

      # filelock 4.2.4 (PyPI wheel): this nixpkgs pin ships only 3.32.4, but
      # headroom 0.41.0 declares `filelock>=4.2.1` (an upstream CVE floor — see
      # the comment in its pyproject). Every package built on this python set
      # resolves filelock through this override, so the filelock consumers in
      # headroom's closure (torch, huggingface-hub, ...) re-derive against
      # 4.2.4 instead of 3.32.4 in one sweep. 4.x is a back-compatible
      # superset for the names they import (FileLock/BaseFileLock/SoftFileLock/
      # Timeout); without this, headroom fails pythonRuntimeDepsCheckHook with
      # "filelock>=4.2.1 not satisfied by version 3.32.4". Pure py3-none-any
      # wheel, so no abi3/manylinux concerns.
      filelock = pyfinal.buildPythonPackage {
        pname = "filelock";
        version = "4.2.4";
        format = "wheel";
        src = prev.fetchurl {
          url = "https://files.pythonhosted.org/packages/e0/1b/5e74289a1878e666bb4b65fe5805a04cafcac2aa5f519ef1ead67ef91c56/filelock-4.2.4-py3-none-any.whl";
          hash = "sha256-MBJBQ4xXk275P0JDqU8lWQIiaL/PmzdamnLrD424NY4=";
        };
        doCheck = false;
      };

      # virtualenv 21.6.1 declares `filelock>=3.24.2,<4` in its wheel metadata —
      # an upper bound that predates the 4.2.4 this set carries (which headroom's
      # >=4.2.1 CVE floor forces). One venv cannot satisfy both, and virtualenv
      # only uses `from filelock import FileLock, Timeout`
      # (src/virtualenv/util/lock.py:13; both exist in 4.2.4 with the same
      # overridable surface its _CountedFileLock subclass relies on), so the <4
      # cap is upstream lag, not a safety floor. Skip its metadata check only —
      # house idiom: flake.nix's semgrepRuntimeDeps does the same.
      virtualenv = pyprev.virtualenv.overrideAttrs (final: prev: {
        dontCheckRuntimeDeps = true;
        # Its own unit suite (pytest + time-machine) creates real venvs per
        # test and is slow under the pinned test-mix; the wheel unpacks clean
        # and pythonImportsCheck covers the import. Skip the suite too.
        doCheck = false;
      });
    };
  };

  # hypothesis's doCheck work-around lives in flake.nix's `hypothesisTeardownRace`
  # extension overlay, NOT here: an interpreter-level
  # `override { packageOverrides }` would replace the packageOverrides function
  # and downstream consumers would rebuild the unpatched hypothesis.

  headroom =
    final.python3.pkgs.callPackage ./headroom.nix {
      python = final.python3;
      src = headroomSrc;
    };

  # knife: reverse engineer's binary Swiss-army knife (pure Rust) with a
  # built-in stdio MCP server; the crate is `reknife` but installs as `knife`.
  knife = final.callPackage ./knife.nix { src = knifeSrc; };

  # graphify: codebase -> knowledge graph (Graphify-Labs/graphify). A Claude
  # Code skill + CLI (pip `graphifyy`) that ships a built-in `graphify-mcp`
  # stdio MCP server. Built from the flakeless `graphify` input
  # (see ./graphify.nix).
  graphify =
    final.python3.pkgs.callPackage ./graphify.nix {
      python = final.python3;
      src = graphifySrc;
      fetchurl = final.fetchurl;
    };

  # graphlore: richer third-party MCP server (28 tools) that wraps graphify's
  # knowledge graph (span engine, semantic locate, impact/blast-radius).
  # Built on python314 explicitly: mcp 2.2.0's floors (anyio>=4.10,
  # starlette>=0.48.0, pydantic>=2.12.0) are only met by the python3.14
  # package set, and pinning the interpreter keeps the isolated build identical
  # to the system build (whose `python3` alias resolves to 3.14).
  # (see ./graphlore.nix).
  graphlore =
    final.python314.pkgs.callPackage ./graphlore.nix {
      python = final.python314;
      src = graphloreSrc;
      fetchurl = final.fetchurl;
    };

  # echarts: interactive chart library (Apache-2.0), npm-only in this pin.
  # ./echarts.nix reads the version from the flakeless `echarts` input, fetches
  # the matching pre-built npm dist, and bundles a CLI rendering an ECharts
  # option (JSON) to self-contained HTML — the simple-HTML counterpart to
  # vega-cli. `nix flake update echarts` re-pins the source.
  echarts = final.callPackage ./echarts.nix { src = echartsSrc; };

  # bend: dependently typed affine language (bendlang/bend); the TypeScript
  # compiler/interpreter/checker runs under bun, and `bend <f> -o` emits C
  # compiled by clang. Built from the flakeless `bend` input.
  bend = final.callPackage ./bend.nix { src = bendSrc; };

  # difftastic: syntax-aware structural diff (Wilfred/difftastic); pure Rust
  # (tree-sitter + four vendored C parsers), built from the flakeless input.
  difftastic = final.callPackage ./difftastic.nix { src = difftasticSrc; };

  # openCodeReview: Alibaba's AI code review CLI, invoked as `ocr`
  # (alibaba/open-code-review). Not in nixpkgs; built with buildGoModule from
  # the pinned v1.12.8 release tag (self-contained fetchFromGitHub).
  openCodeReview = final.callPackage ./open-code-review.nix { };

  # ripwire: "the ripgrep of AI context" (redhat-et/ripwire) — a zero-dependency
  # C++23 CLI + MCP server giving coding agents a ranked, deterministic repo
  # map (signatures, blast radius, tests-to-run, quality deltas).
  ripwire = final.callPackage ./ripwire.nix { src = ripwireSrc; };
}
