# graphlore: a richer third-party MCP server (28 tools) that wraps a Graphify
# codebase knowledge graph (yasinyaman/graphlore). Adds a span engine (real
# start..end symbol ranges), semantic locate, impact/blast-radius, structural
# diff & freshness, and duplication scan on top of graphify's graph.
#
# Not on PyPI, so built here from the flakeless `graphlore` input (see
# flake.nix); `nix flake update graphlore` re-pins the source.
#
# Core dep is the mcp v2 SDK (>=2.1,<3.0). nixpkgs ships mcp 1.29.0 (a
# different major), so mcp 2.2.0 and its type package mcp-types 2.2.0 (absent
# from nixpkgs) are fetched as prebuilt wheels. Every OTHER entry in mcp 2.2.0's
# Requires-Dist is already satisfied by nixpkgs's python3.14 packages at a
# version meeting the floor (verified against the wheel's metadata), so those
# are referenced directly via `py.` — they track nixpkgs across `nix flake
# update` instead of colliding with it. (A hand-fetched duplicate of a package
# nixpkgs already ships trips pythonCatchConflictsPhase the moment the two
# versions line up.)
#
# The [semble] extra (semantic locate via model2vec/vicinity, a torch-scale
# dep) is NOT included; graphlore degrades gracefully without it. graphlore
# shells out to the `graphify` CLI (found on the jail PATH via commonPkgSpecs),
# so it does not depend on the graphifyy package.
{ lib
, python
, src
, fetchurl
}:

let
  py = python.pkgs;

  # A prebuilt wheel genuinely absent from (or a newer major than) nixpkgs:
  # fetch the exact wheel by URL and unpack it (no build). `deps` are the
  # wheel's runtime deps (declared so the pythonRuntimeDepsCheckHook passes and
  # the package is self-contained).
  pyWheel = { pname, version, hash, url, deps ? [ ] }: py.buildPythonPackage {
    inherit pname version;
    format = "wheel";
    src = fetchurl { inherit url hash; };
    doCheck = false;
    propagatedBuildInputs = deps;
  };

  # mcp-types 2.2.0 (absent from nixpkgs). Requires-Dist: pydantic>=2.12.0,
  # typing-extensions>=4.13.0 — both satisfied by nixpkgs python3.14.
  mcp-types = pyWheel {
    pname = "mcp-types";
    version = "2.2.0";
    hash = "sha256-6kdrc+6GcJq1q8lFI4XtNswFkH5YI1ViLilFlcmgTxM=";
    url = "https://files.pythonhosted.org/packages/8f/d7/6ffba5d8cd5dd9b8a19478875c50e04945314ba5074e84d749283f27f62d/mcp_types-2.2.0-py3-none-any.whl";
    deps = [ py.pydantic py."typing-extensions" ];
  };

  # mcp 2.2.0 (nixpkgs ships 1.29.0, a different major). Requires-Dist
  # (python >= 3.14), each satisfied by nixpkgs python3.14 at a version meeting
  # the floor; mcp-types is the only hand-fetched dep.
  mcp = pyWheel {
    pname = "mcp";
    version = "2.2.0";
    hash = "sha256-vemCWJRzoGCuFF40BumlMz/lOMlyKbqEH1p/kr4AT4E=";
    url = "https://files.pythonhosted.org/packages/1b/ff/8e7eade68b8a28f7da0ed1085544341b51f9c935dbf6b95c76b7edfea6a0/mcp-2.2.0-py3-none-any.whl";
    deps = [
      py.anyio # >=4.10    (nixpkgs 4.14.2)
      py.httpx2 # >=2.5.0   (nixpkgs 2.9.1; brings httpcore2)
      py.jsonschema # >=4.20.0  (nixpkgs 4.26.0)
      mcp-types # ==2.2.0   (not in nixpkgs)
      py.opentelemetry-api # >=1.28.0  (nixpkgs 1.43.0)
      py.pydantic # >=2.12.0  (nixpkgs 2.13.4)
      py.pyjwt
      py.cryptography # >=2.10.1 [crypto] (nixpkgs 2.13.0 / 50.0.0)
      py."python-multipart" # >=0.0.9   (nixpkgs 0.0.32)
      py."sse-starlette" # >=3.0.0   (nixpkgs 3.2.0)
      py.starlette # >=0.48.0  (nixpkgs 1.3.1)
      py."typing-extensions" # >=4.13.0  (nixpkgs 4.16.0)
      py."typing-inspection" # >=0.4.1   (nixpkgs 0.4.3)
      py.uvicorn # >=0.31.1  (nixpkgs 0.51.0)
    ];
  };
in
py.buildPythonApplication (finalAttrs: {
  pname = "graphlore";
  version = "0.2.0";
  pyproject = true;

  # Source from the flakeless `graphlore` input (see flake.nix).
  src = src;

  # PEP 517 build backend (the source declares `hatchling`).
  nativeBuildInputs = [ py.hatchling ];

  propagatedBuildInputs = [
    # mcp v2 SDK + its dep tree (propagates mcp-types and the nixpkgs deps above)
    mcp
    # [treesitter] extra: multi-language span engine
    py.tree-sitter
    py."tree-sitter-language-pack"
    # [tiktoken] extra: exact token counting
    py.tiktoken
    # [watch] extra: opt-in filesystem watcher
    py.watchdog
  ];

  doCheck = false;

  pythonImportsCheck = [ "graphlore" ];

  meta = {
    description = "MCP server exposing a Graphify codebase knowledge graph as 28 tools (semantic locate, impact/blast-radius, span engine)";
    homepage = "https://github.com/yasinyaman/graphlore";
    license = lib.licenses.mit;
    mainProgram = "graphlore";
    maintainers = [ ];
  };
})
