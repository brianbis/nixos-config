# headroom-ai: context compression layer for AI agents (chopratejas/headroom).
#
# Not in nixpkgs or the llm-agents flake, so built here from source. It is a
# maturin (Rust core + Python) package: this derivation compiles the pyo3 cdylib
# (crates/headroom-py) and packages the Python CLI.
{ lib
, rustPlatform
, cargo
, rustc
, python
, src
, ast-grep-cli
}:

python.pkgs.buildPythonApplication (finalAttrs: {
  pname = "headroom-ai";
  # Tracks the pinned source's own [project] version — 0.41.0 at headroom@1be699f6
  # (flake.lock). A stale value here is invisible until the wheel actually
  # builds; re-pin it with the input, as in home/llm/tools/graphify.nix.
  version = "0.41.0";
  pyproject = true;

  # Source from the flakeless `headroom` input (see flake.nix);
  # `nix flake update headroom` re-pins it.
  src = src;

  # Vendored cargo deps from the source's Cargo.lock; re-resolves
  # automatically when the input is updated.
  cargoDeps = rustPlatform.importCargoLock {
    lockFile = src + "/Cargo.lock";
  };

  nativeBuildInputs = [
    rustPlatform.maturinBuildHook
    rustPlatform.cargoSetupHook
    cargo
    rustc
  ];

  # Core + [proxy] + [code] extras from pyproject.toml (torch-free).
  # NB: use the generic `python` param, NOT `python3`. Inside python3.pkgs the
  # `python3` name is an alias that throws (see pkgs/top-level/python-aliases.nix).
  propagatedBuildInputs = with python.pkgs; [
    tiktoken
    pydantic
    litellm
    click
    rich
    opentelemetry-api
    pyyaml
    tomlkit
    # 0.41.0 floors filelock>=4.2.1 (upstream CVE fix); this nixpkgs pin only
    # has 3.32.4, so the python3 override in overlay.nix shadows filelock with
    # the 4.2.4 PyPI wheel for everything built on this set (including this
    # closure's torch/huggingface-hub copies).
    filelock

    # [proxy]
    fastapi
    uvicorn
    orjson
    httpx
    h2
    truststore
    openai
    mcp
    magika
    zstandard
    websockets
    onnxruntime
    transformers
    watchdog
    sqlite-vec

    # [code]
    tree-sitter
    tree-sitter-language-pack
    ast-grep-py
    ast-grep-cli
  ];

  doCheck = false;

  pythonImportsCheck = [ "headroom" ];

  meta = {
    description = "Context optimization layer for LLM applications (compress everything an AI agent reads)";
    homepage = "https://github.com/chopratejas/headroom";
    license = lib.licenses.asl20;
    mainProgram = "headroom";
    maintainers = [ ];
  };
})
