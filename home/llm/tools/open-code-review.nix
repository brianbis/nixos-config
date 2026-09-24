# open-code-review: Alibaba's AI-powered code review CLI
# (alibaba/open-code-review), invoked as `ocr`.
#
# Reads git diffs, sends changed files to a configurable LLM service (OpenAI-
# and Anthropic-compatible endpoints) through an agent with tool access, and
# produces structured review comments with line-level precision, plus built-in
# deterministic rulesets (NPE, thread-safety, XSS, SQL injection).
#
# Not in nixpkgs (checked nixpkgs master, NUR's full package index, and the
# NixOS wiki), so it is built here with buildGoModule from the pinned v1.12.8
# release tag. Unlike the sibling tools, this one is self-contained (no
# flakeless input): the pin is a release tag, not a branch, so re-pinning is a
# version bump here, not `nix flake update <name>`:
#   1. bump `version`, `rev`, and the fetchFromGitHub `hash` (the NAR hash of
#      the unpacked tag tree — `nix hash path` on the extracted tarball, per
#      the fetchFromGitHub note in AGENTS.md);
#   2. if go.mod/go.sum changed, re-fetch `vendorHash` (rebuild and copy the
#      "got: sha256-…" value out of the go-modules hash mismatch).
{ buildGoModule
, fetchFromGitHub
, go_1_26
, lib
}:

let
  version = "1.12.8";
in
buildGoModule {
  pname = "open-code-review";
  inherit version;

  src = fetchFromGitHub {
    owner = "alibaba";
    repo = "open-code-review";
    rev = "v1.12.8";
    hash = "sha256-EuX3wT3gIz3tsYtAlC8eZm7TgImCAt2Bjr+qS0epHCI=";
  };

  # go.mod requires go >= 1.25.5; go_1_26 (1.26.7) is the only Go in this
  # nixpkgs pin and matches the Go the upstream release workflow builds with
  # (golang:1.26.x).
  go = go_1_26;

  # Pure Go: the upstream release workflow builds with CGO_ENABLED=0, and no
  # dependency in the module graph imports "C". No C toolchain needed.
  env.CGO_ENABLED = 0;

  # Build exactly what the upstream release workflow builds
  # (go build ./cmd/opencodereview). This also sidesteps the builder's
  # find-based package discovery, which would otherwise trip over pages/ —
  # the docs site is a separate Go module (pages/go.mod) — and would attempt
  # scripts/ (whose only .go file is `//go:build ignore`).
  subPackages = [ "cmd/opencodereview" ];

  # The upstream release injects version info via ldflags (see
  # .github/workflows/release.yml). BuildDate is deliberately left unset:
  # upstream sets it to the build time, which would be impure here; `ocr
  # version` simply shows an empty build date. `-buildid=` (reproducibility)
  # is appended by buildGoModule itself.
  ldflags = [
    "-s"
    "-w"
    "-X" "main.Version=${version}"
    "-X" "main.GitCommit=5c7b383"
  ];

  # The source ships no vendor/ directory, so buildGoModule's go-modules
  # derivation runs `go mod vendor` (fetched from the Go module proxy) and
  # verifies the result against this hash. If go.mod/go.sum change on a
  # re-pin, rebuild and copy the "got: sha256-…" value from the hash-mismatch
  # error into vendorHash.
  vendorHash = "sha256-f5Ty22wicf1J8+RKnHYcEO7flWn9gkWQODlfunn23EA=";

  # doCheck is false to keep the build lean; the upstream CI (go test -race
  # with a 90% coverage floor) exercises the tests, mirroring the
  # knife/difftastic doCheck = false precedent.
  doCheck = false;

  # The Go main package (cmd/opencodereview) installs as `opencodereview`, but
  # the canonical command is `ocr` (the npm bin name and what upstream's
  # install.sh installs).
  postInstall = ''
    mv "$out/bin/opencodereview" "$out/bin/ocr"
  '';

  meta = {
    description = "AI-powered code review CLI: reads git diffs, reviews them with a configurable LLM agent, and produces line-level comments";
    homepage = "https://github.com/alibaba/open-code-review";
    license = lib.licenses.asl20;
    platforms = lib.platforms.all;
    mainProgram = "ocr";
    maintainers = [ ];
  };
}
