# open-code-review (alibaba): AI code review CLI, invoked as `ocr`. Reads git
# diffs, reviews changed files via a configurable LLM agent (OpenAI/Anthropic
# compatible), emits line-level comments + built-in rulesets (NPE, thread-
# safety, XSS, SQLi). Not in nixpkgs/NUR, so built here with buildGoModule
# from the pinned v1.12.8 tag. Re-pin (a version bump here, not `nix flake
# update`): bump version/rev + fetchFromGitHub hash (NAR of the unpacked tag
# tree), and vendorHash if go.mod/go.sum changed (copy "got: sha256-…").
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

  # go.mod needs go >= 1.25.5; go_1_26 matches the upstream release workflow.
  go = go_1_26;

  # Pure Go (upstream builds with CGO_ENABLED=0; no dep imports "C").
  env.CGO_ENABLED = 0;

  # Build exactly what the upstream release workflow builds; sidesteps the
  # builder's find-based discovery, which trips over pages/ (a separate Go
  # module) and scripts/ (a `//go:build ignore` file).
  subPackages = [ "cmd/opencodereview" ];

  # Version info mirrors the upstream release workflow's ldflags. BuildDate is
  # left unset (upstream uses build time, which would be impure). buildGoModule
  # appends `-buildid=` itself.
  ldflags = [
    "-s"
    "-w"
    "-X" "main.Version=${version}"
    "-X" "main.GitCommit=5c7b383"
  ];

  # No vendor/ in source, so buildGoModule runs `go mod vendor` and verifies
  # the result against this hash (see the re-pin note at the top).
  vendorHash = "sha256-f5Ty22wicf1J8+RKnHYcEO7flWn9gkWQODlfunn23EA=";

  # doCheck = false to keep the build lean (upstream CI covers it).
  doCheck = false;

  # The Go main package installs as `opencodereview`; the canonical command is `ocr`.
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
