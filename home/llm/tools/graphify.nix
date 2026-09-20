# graphifyy: codebase -> queryable knowledge graph (Graphify-Labs/graphify).
#
# A Claude Code skill + CLI (pip `graphifyy`) that reads code/docs/papers/images,
# builds a knowledge graph (tree-sitter AST + LLM extraction + Leiden communities),
# and ships a built-in `graphify-mcp` stdio MCP server. Not in nixpkgs, so built
# here from the flakeless `graphify` input (see flake.nix); `nix flake update
# graphify` re-pins the source.
#
# Core deps + five grammars come from nixpkgs. The other 20 tree-sitter language
# grammars are not in this nixpkgs pin, so they are fetched as prebuilt abi3
# manylinux wheels (stable ABI -> they run on the nixpkgs Python 3.14). graphify
# degrades gracefully per-language, but we ship all 24 for complete coverage.
{ lib
, python
, src
, fetchurl
}:

let
  py = python.pkgs;

  # A prebuilt wheel not in nixpkgs: fetch the exact manylinux/py3 wheel by URL
  # (fetchPypi guesses a `py2.py3-none-any` filename that 404s for these) and
  # unpack it (no build). abi3 / py3 wheels run on the nixpkgs Python 3.14.
  pyWheel = { pname, version, hash, url }: py.buildPythonPackage {
    inherit pname version;
    format = "wheel";
    src = fetchurl { inherit url hash; };
    doCheck = false;
  };
in
py.buildPythonApplication (finalAttrs: {
  pname = "graphifyy";
  version = "0.9.63";
  pyproject = true;

  # Source from the flakeless `graphify` input (see flake.nix).
  src = src;

  # PEP 517 build backend (the source declares `setuptools.build_meta`).
  nativeBuildInputs = [ py.setuptools ];

  propagatedBuildInputs = with py; [
    # core
    networkx
    numpy
    rapidfuzz
    tree-sitter
    # [mcp] extra (the `graphify-mcp` stdio server)
    mcp
    starlette

    # [openai] extra (the openai / OpenAI-compatible backend: local servers such
    # as llama.cpp, vLLM, and the socket-activated NInfer serve). graphify's
    # openai backend imports `openai` and uses `tiktoken` for token counting;
    # without them the backend errors with "the 'openai' package is required
    # for this backend but is not installed". The jail wrapper (home/llm/jails.nix
    # graphifyNinfer) points this backend at the local NInfer endpoint, so the
    # extra must be present for `graphify extract` semantic extraction to work.
    openai
    tiktoken

    # grammars available in nixpkgs
    tree-sitter-python
    tree-sitter-javascript
    tree-sitter-rust
    tree-sitter-c-sharp
    tree-sitter-json

    # grammars fetched as prebuilt abi3 wheels (not in this nixpkgs pin)
    (pyWheel { pname = "tree-sitter-typescript"; version = "0.23.2"; hash = "sha256-6W02uFvKzeuP9cJhjXVZPvEuuvG06s40d+K9squxdSw="; url = "https://files.pythonhosted.org/packages/49/d1/a71c36da6e2b8a4ed5e2970819b86ef13ba77ac40d9e333cb17df6a2c5db/tree_sitter_typescript-0.23.2-cp39-abi3-manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-go"; version = "0.25.0"; hash = "sha256-BLOzy0r/GOdOKNSbcWxvJMtx3f3WZ2iYfibk0PqBL3Q="; url = "https://files.pythonhosted.org/packages/86/fb/b30d63a08044115d8b8bd196c6c2ab4325fb8db5757249a4ef0563966e2e/tree_sitter_go-0.25.0-cp310-abi3-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-java"; version = "0.23.5"; hash = "sha256-NwsgS5UAuEf20MWtWEBFgxzuaemj5Nh4U1055KfkxPE="; url = "https://files.pythonhosted.org/packages/29/09/e0d08f5c212062fd046db35c1015a2621c2631bc8b4aae5740d7adb276ad/tree_sitter_java-0.23.5-cp39-abi3-manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-groovy"; version = "0.1.2"; hash = "sha256-npOOnCzV/bCP0bKNfWIdFeqVmhekvAt3gz4HqU/n0mM="; url = "https://files.pythonhosted.org/packages/c6/b7/451ac5e158f2418fea7eb0744254dd27238359c070420d69d711aaf06356/tree_sitter_groovy-0.1.2-cp39-abi3-manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-c"; version = "0.24.2"; hash = "sha256-UEHvZ+tozmvIuwsfjvOlWFzlI9rgx+7BCasGJ911rt4="; url = "https://files.pythonhosted.org/packages/e9/8c/0dfb88d726f8821d1c4c36042f092be974a800afd734307a595b8604190c/tree_sitter_c-0.24.2-cp310-abi3-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-cpp"; version = "0.23.4"; hash = "sha256-dz0sr8CLvA+Zhof6M/QvN4waNxzbWChwxNE6uwYJJwY="; url = "https://files.pythonhosted.org/packages/6a/4d/23e390234d2acd351f5563b1079c515d7c1fe13ddb7392cee543be74dda3/tree_sitter_cpp-0.23.4-cp39-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-ruby"; version = "0.23.1"; hash = "sha256-97zZOXK0yigDhW1P4PvQQSP/KcRZK7ufEqJ1KL0lI0E="; url = "https://files.pythonhosted.org/packages/23/dd/1171b5dd25da10f768732a20fb62d2e3ae66e3b42329351f2ce5bf723abb/tree_sitter_ruby-0.23.1-cp39-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-kotlin"; version = "1.1.0"; hash = "sha256-mpKv4ktjTPkUxYEq8PXFMYSxwYvfbuVQXIOvrIH2v2w="; url = "https://files.pythonhosted.org/packages/65/bd/0f3aac45eb88b6b3173ac9c23bc41d8865943cbbe1caaafc001cd1b73c90/tree_sitter_kotlin-1.1.0-cp39-abi3-manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-scala"; version = "0.26.2"; hash = "sha256-DmjlXFD6fn8oZs58pZDfjfZAfdeoXkhOnyDpdMvG2PI="; url = "https://files.pythonhosted.org/packages/9d/55/9eb4b71083ab492a6ce0d52380f8d3b431aa7dcbd42cdbffbcd744aa3d42/tree_sitter_scala-0.26.2-cp39-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-php"; version = "0.24.1"; hash = "sha256-ehQEow8pckmKzgQLAClzi42sRdChKTLMuLYF65S6++Q="; url = "https://files.pythonhosted.org/packages/9a/c6/fd863a7a779d0ab67688939eba0e08bff7b1ffe731288d3d3610df21217b/tree_sitter_php-0.24.1-cp310-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-swift"; version = "0.7.3"; hash = "sha256-84/utPc1DIsw1Weg3Ai/HuqmfCQbaIjXKkWosaSqcYc="; url = "https://files.pythonhosted.org/packages/e1/9a/55f6cc9aad9079facf166d616472fd8e05007cbee9c62b749e153bf0521d/tree_sitter_swift-0.7.3-cp38-abi3-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-lua"; version = "0.5.0"; hash = "sha256-XsRIyFT+oyQUoESRR9ZIvFut33oDVwCMSr4yads1Nwo="; url = "https://files.pythonhosted.org/packages/45/2b/1edfd9bef9a1cc11047cd87ca9c60707b8425080cfc0498a7d3bc762d783/tree_sitter_lua-0.5.0-cp310-abi3-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-zig"; version = "1.1.2"; hash = "sha256-6SRQncrFpgVNo1fj1rzzfqgphO4dKjdlaXU9MvYeqLs="; url = "https://files.pythonhosted.org/packages/78/02/275523eb05108d83e154f52c7255763bac8b588ae14163563e19479322a7/tree_sitter_zig-1.1.2-cp39-abi3-manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-powershell"; version = "0.26.4"; hash = "sha256-VlCOSseq0eOyby75a40rYLFJxO+gwjdC6R6AmhHbc+4="; url = "https://files.pythonhosted.org/packages/de/ff/5bba5fef4b3808ade114512ebf44e0c192050cc825cdcf42fa2043e5abd0/tree_sitter_powershell-0.26.4-cp310-abi3-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-elixir"; version = "0.3.5"; hash = "sha256-6/40kaPQCsULEqO/yrscVk84Ce2KCVCZ/of0nWs5h+Y="; url = "https://files.pythonhosted.org/packages/31/35/78c94e164542ad08098b83cb7e046261f3ab2edade96e29727dd209bfa35/tree_sitter_elixir-0.3.5-cp39-abi3-manylinux1_x86_64.manylinux_2_28_x86_64.manylinux_2_5_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-objc"; version = "3.0.2"; hash = "sha256-5xKCrJwJapZr8vpqTs2+pL0DfT4B6kqpu8ZNmkwAIvY="; url = "https://files.pythonhosted.org/packages/60/cd/a153a4268b9b405a69ee3e427f19fc570a3c63d4b4d7766bee5a7ba28744/tree_sitter_objc-3.0.2-cp39-abi3-manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-julia"; version = "0.23.1"; hash = "sha256-fU9q6TgZj8C+m26nYxOt4k/NuJvgGnkeDMkMiPrldD0="; url = "https://files.pythonhosted.org/packages/0b/4c/09534d31ab95c3da2284f538bb134bf6fe064770c0bf6fe4fb6f2b028d9e/tree_sitter_julia-0.23.1-cp39-abi3-manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-verilog"; version = "1.0.3"; hash = "sha256-dH3X1LyV+zibw3Il+C0W8MQFSYVumiRL4/+de/5itzA="; url = "https://files.pythonhosted.org/packages/2a/c1/8782535dbb6ea1f3556eb2bc473f5f131339739278775171fc42b0a57536/tree_sitter_verilog-1.0.3-cp39-abi3-manylinux_2_5_x86_64.manylinux1_x86_64.manylinux_2_17_x86_64.manylinux2014_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-fortran"; version = "0.6.0"; hash = "sha256-rEgAtKvBsl5uerSj8uridMWxkQe+sY06RzwPZ1CcdIY="; url = "https://files.pythonhosted.org/packages/57/86/0923f061e36f229d99660a8f53f8e3b57da459e08512c09e256de820c472/tree_sitter_fortran-0.6.0-cp39-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl"; })
    (pyWheel { pname = "tree-sitter-bash"; version = "0.25.1"; hash = "sha256-P0hMS7h5bN56h8o1HmEW8JZT7awOs8bSOFZjWd0osRc="; url = "https://files.pythonhosted.org/packages/d7/22/9f70bc3d3b942ab9fc0f89c1dc9e087519a3a94f64ae6b7377aae3a7a0f0/tree_sitter_bash-0.25.1-cp310-abi3-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl"; })
  ];

  doCheck = false;

  pythonImportsCheck = [ "graphify" ];

  meta = {
    description = "Codebase -> knowledge graph (tree-sitter AST + LLM); ships a `graphify-mcp` stdio MCP server";
    homepage = "https://github.com/Graphify-Labs/graphify";
    license = lib.licenses.asl20;
    mainProgram = "graphify";
    mainPrograms = [ "graphify" "graphify-mcp" ];
    maintainers = [ ];
  };
})
