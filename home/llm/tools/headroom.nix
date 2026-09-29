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
  version = "0.34.0";
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
