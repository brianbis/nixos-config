# Local override of the `dsh` package from the llm-agents.nix flake input.
#
# Why this exists: llm-agents.nix pins dsh to the npm `latest` dist-tag
# (0.1.1-rc.2 via packages/dsh/hashes.json) and its updater does not track the
# `alpha` tag. This builds 0.1.2-alpha.5 (the current deepseek-harness master,
# merged 2026-09-02) directly from the npm tarball, mirroring the upstream
# recipe (numtide/llm-agents.nix packages/dsh/package.nix) so the two converge
# when the alpha graduates. Delete this file (and repoint dshPatched in
# jails.nix at `agent "dsh"`) once llm-agents.nix ships >= 0.1.2.
#
# Differences from the upstream recipe:
#   - version/lockfile pinned to 0.1.2-alpha.5 (see dsh-package-lock.json).
#   - The tarball's package.json lists four devDependencies that were never
#     published to npm (the dsh-experimental-* packages); the lockfile omits
#     them, so srcWithLock strips them to keep package.json and the lockfile
#     in sync for `npm ci`. None of the shipped compositions reference them.
{ lib, bashInteractive, buildNpmPackage, fetchurl, jq, makeWrapper, nodejs, runCommand, versionCheckHook, versionCheckHomeHook }:

let
  version = "0.1.2-alpha.5";

  srcWithLock = runCommand "dsh-source" {
    nativeBuildInputs = [ jq ];
  } ''
    mkdir -p $out
    tar -xzf ${
      fetchurl {
        url = "https://registry.npmjs.org/@deepseek-ai/dsh/-/dsh-${version}.tgz";
        # SRI (base64) form: the npmDeps prefetcher parses fetchurl hashes as
        # base64 SRI, where 64 hex chars would decode to 48 bytes (≠ 32).
        hash = "sha256-xtRp4CJ8WbCu6AoZxKAy9EsmPi1OtdRHAXBO1a/BNxs=";
      }
    } -C $out --strip-components=1
    # Strip the unpublished devDependencies (see file header).
    jq 'del(.devDependencies["@deepseek-ai/dsh-experimental-tool-agent-team"],
            .devDependencies["@deepseek-ai/dsh-experimental-code-runtime-python"],
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
  npmDepsHash = "sha256-32pwWZJJqPsdeJ5DEFouYnb2hzJQBOc7AZxMsGzWf4U=";

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
      binaryBytecode
      fromSource
    ];
    mainProgram = "dsh";
    platforms = lib.platforms.all;
  };
}