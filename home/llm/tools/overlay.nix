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
    };
  };

  headroom =
    final.python3.pkgs.callPackage ./headroom.nix {
      python = final.python3;
      src = headroomSrc;
    };

  # knife: reverse engineer's binary Swiss-army knife (pure Rust) that ships a
  # built-in stdio MCP server (`knife mcp`). The crate is `reknife` but installs
  # as `knife` (see ./knife.nix).
  knife = final.callPackage ./knife.nix { src = knifeSrc; };

  # graphify: codebase -> knowledge graph (Graphify-Labs/graphify). A Claude Code
  # skill + CLI (pip `graphifyy`) that ships a built-in `graphify-mcp` stdio MCP
  # server. Built from the flakeless `graphify` input (see ./graphify.nix).
  graphify =
    final.python3.pkgs.callPackage ./graphify.nix {
      python = final.python3;
      src = graphifySrc;
      fetchurl = final.fetchurl;
    };

  # graphlore: richer third-party MCP server (28 tools) that wraps graphify's
  # knowledge graph (span engine, semantic locate, impact/blast-radius). Built
  # from the flakeless `graphlore` input (see ./graphlore.nix).
  # graphlore: richer third-party MCP server (28 tools) that wraps graphify's
  # graph (see ./graphlore.nix). Built on python314 explicitly: mcp 2.2.0's
  # floors (anyio>=4.10, starlette>=0.48.0, pydantic>=2.12.0) are only met by
  # the python3.14 package set, and pinning the interpreter keeps the isolated
  # build identical to the system build (whose `python3` alias resolves to
  # 3.14).
  graphlore =
    final.python314.pkgs.callPackage ./graphlore.nix {
      python = final.python314;
      src = graphloreSrc;
      fetchurl = final.fetchurl;
    };

  # echarts: rich interactive chart library (Apache-2.0). npm-only (not a ready
  # nixpkgs attr in this pin), so ./echarts.nix reads the version from the
  # flakeless `echarts` source input and fetches the matching pre-built npm
  # dist, then bundles a CLI that renders an ECharts option (JSON) to a
  # self-contained HTML file — the "simple HTML, refreshable from datasets"
  # chart counterpart to vega-cli. `nix flake update echarts` re-pins the source.
  echarts = final.callPackage ./echarts.nix { src = echartsSrc; };

  # bend: dependently typed affine language (bendlang/bend). TypeScript
  # compiler/interpreter/checker run by bun; `bend <f> -o` emits C compiled
  # by clang. Built from the flakeless `bend` input (see ./bend.nix);
  # `nix flake update bend` re-pins the source.
  bend = final.callPackage ./bend.nix { src = bendSrc; };

  # difftastic: a structural diff that understands syntax (Wilfred/difftastic).
  # Pure Rust (tree-sitter + four vendored C parsers); built from the flakeless
  # `difftastic` input (see ./difftastic.nix); `nix flake update difftastic`
  # re-pins the source.
  difftastic = final.callPackage ./difftastic.nix { src = difftasticSrc; };

  # open-code-review: Alibaba's AI code review CLI, invoked as `ocr`
  # (alibaba/open-code-review). Not in nixpkgs, so ./open-code-review.nix
  # builds it with buildGoModule from the pinned v1.12.8 release tag
  # (self-contained fetchFromGitHub; see the file for the re-pin notes).
  openCodeReview = final.callPackage ./open-code-review.nix { };

  # ripwire: "the ripgrep of AI context" (redhat-et/ripwire): a
  # zero-dependency C++23 CLI + MCP server that gives coding agents a ranked,
  # deterministic map of a repo (signatures, blast radius, tests-to-run,
  # quality deltas). Built from the flakeless `ripwire` input (see
  # ./ripwire.nix); `nix flake update ripwire` re-pins the source.
  ripwire = final.callPackage ./ripwire.nix { src = ripwireSrc; };
}
