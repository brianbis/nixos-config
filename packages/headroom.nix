# headroom-ai: context compression layer for AI agents (chopratejas/headroom).
#
# Not present in nixpkgs or the llm-agents flake, so it is built here from
# source. It is a maturin (Rust core + Python) package, so this derivation
# compiles the pyo3 cdylib (crates/headroom-py) and packages the Python CLI.
#
# Two hashes must be filled in on the first build. Nix will fail once per
# placeholder with `got: sha256-<real>`; paste each into the right field and
# re-run `just switch`:
#   * src.hash        (fetchFromGitHub source archive)
#   * cargoDeps.hash  (vendored cargo dependencies of the Rust core)
#
# Follows the nixpkgs maturin build pattern (see e.g. `ast-grep-py`). If the
# maturin layout differs in practice, adjust `buildAndTestSubdir` /
# `cargoRoot`. Dependencies mirror pyproject.toml's [proxy,code] extras, which
# are enough for `headroom wrap` / `headroom proxy` (no torch).
{
  lib,
  rustPlatform,
  cargo,
  rustc,
  python,
  fetchFromGitHub,
  ast-grep-cli
}:

python.pkgs.buildPythonApplication (finalAttrs: {
  pname = "headroom-ai";
  version = "0.34.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "chopratejas";
    repo = "headroom";
    rev = "v${finalAttrs.version}";
    hash = "sha256-Pz/3R3xogTyREJ1yz/Kxj6OrtJbT9kwmWt5CaFQhrRE=";
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) src;
    name = "${finalAttrs.pname}-${finalAttrs.version}";
    hash = "sha256-NOflRqKu4fFYA06rZUoFlr8xPi750/AdD8vnFTtf6Tk=";
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
    maintainers = with lib.maintainers; [ ];
  };
})
