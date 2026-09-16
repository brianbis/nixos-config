# Local build of the `dsh` package from upstream source (the flakeless `dsh`
# flake input), replacing the llm-agents.nix flake input's `dsh`, which pins
# the npm `latest` dist-tag (0.1.1-rc.2 via packages/dsh/hashes.json) and
# does not track the `alpha` tag.
#
# The tarball is built from source by ./dsh-source.nix (replicating the
# upstream release pipeline); this file then runs the usual buildNpmPackage
# recipe on it, mirroring the upstream recipe (numtide/llm-agents.nix
# packages/dsh/package.nix) so the two converge when the alpha graduates.
# `nix flake update dsh` re-pins the source; the version follows the pinned
# tree's root package.json (see jails.nix).
#
# The packed tarball's package.json lists four devDependencies for
# experimental features (the dsh-experimental-* packages). They are
# dev-only — the CLI's runtime loads its `dependencies`, and none of the
# shipped compositions reference the experimental ones — so srcWithLock
# strips them to keep the installed tree minimal and in sync with the
# lockfile for `npm ci`. (At 0.1.2-alpha.5 they were also unpublished;
# by 0.1.6-alpha.1 they are published, but still stripped: dev-only.)
{ lib, bashInteractive, buildNpmPackage, jq, makeWrapper, nodejs, runCommand, versionCheckHook, versionCheckHomeHook, src, version }:

let
  # src is the @deepseek-ai/dsh tarball built from source (dsh-source.nix).
  srcWithLock = runCommand "dsh-tarball-with-lock" {
    nativeBuildInputs = [ jq ];
  } ''
    mkdir -p $out
    tar -xzf ${src} -C $out --strip-components=1
    # Strip the dev-only experimental devDependencies (see file header).
    jq 'del(.devDependencies["@deepseek-ai/dsh-experimental-tool-agent-team"],
            .devDependencies["@deepseek-ai/dsh-experimental-ptc-runtime-python"],
            .devDependencies["@deepseek-ai/dsh-experimental-agent-team-profile"],
            .devDependencies["@deepseek-ai/dsh-experimental-agent-team"])' \
      $out/package.json > $out/package.json.tmp && mv $out/package.json.tmp $out/package.json
    cp ${./dsh-package-lock.json} $out/package-lock.json
  '';
in
buildNpmPackage {
  pname = "dsh";
  inherit version;
  src = srcWithLock;

  npmDepsFetcherVersion = 2;
  # Sub-pin of the npm closure (registry resolution of the tarball's
  # package.json against dsh-package-lock.json). Re-pin when the lockfile
  # changes: set to "", build, copy the `got: sha256-…` value back.
  npmDepsHash = "sha256-iFpn65sj3NKWY0HsH5f8mJhzxhV8quJYShb0jeeKGh8=";

  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    # /bin/bash does not exist on NixOS (issue #8086)
    substituteInPlace \
      $out/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-terminal-bash/lib/index.js \
      --replace-fail '"/bin/bash"' '"${lib.getExe bashInteractive}"'

    rm $out/bin/dsh
    makeWrapper ${lib.getExe nodejs} $out/bin/dsh \
      --argv0 dsh \
      --add-flags "--expose-internals" \
      --add-flags "$out/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    versionCheckHook
    versionCheckHomeHook
  ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "Open-source agent harness developed by DeepSeek AI";
    homepage = "https://github.com/deepseek-ai/deepseek-harness";
    changelog = "https://github.com/deepseek-ai/deepseek-harness/releases";
    downloadPage = "https://www.npmjs.com/package/@deepseek-ai/dsh";
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [
      fromSource
    ];
    mainProgram = "dsh";
    platforms = lib.platforms.all;
  };
}
