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
# srcWithLock strips dev-only experimental devDependencies (the
# dsh-experimental-* packages) from the packed tarball's package.json to keep
# the installed tree minimal and in sync with the lockfile for `npm ci`.
# At 0.1.6-alpha.2 the strip is a no-op: those packages are no longer
# devDependencies (dsh-experimental-agent-team-profile and
# dsh-experimental-agent-team-web-profile are runtime dependencies), so the
# lockfile covers them like any other dependency. (At 0.1.2-alpha.5 they were
# also unpublished; by 0.1.6-alpha.1 they are published, but were still
# dev-only and stripped.)
{ lib, bashInteractive, buildNpmPackage, jq, makeWrapper, nodejs, runCommand, versionCheckHook, versionCheckHomeHook, src, version }:

let
  # src is the @deepseek-ai/dsh tarball built from source (dsh-source.nix).
  srcWithLock = runCommand "dsh-tarball-with-lock"
    {
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

  # npm ci OOMs at node's default 4 GiB heap on this dependency tree
  # (0.1.7-alpha.2, "Ineffective mark-compacts near heap limit"); the host
  # has 62 GiB, so give npm's node process 8 GiB.
  NODE_OPTIONS = "--max-old-space-size=16384";

  npmDepsFetcherVersion = 2;
  # Sub-pin of the npm closure (registry resolution of the tarball's
  # package.json against dsh-package-lock.json). Re-pin when the lockfile
  # changes: set to "", build, copy the `got: sha256-…` value back.
  npmDepsHash = "sha256-SBnnIbpEWxbjiLIZclPmGFFqLWPVAk4e9tv1SE3NurA=";

  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  postInstall = ''
    # /bin/bash does not exist on NixOS (issue #8086)
    substituteInPlace \
      $out/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-terminal-bash/lib/index.js \
      --replace-fail '"/bin/bash"' '"${lib.getExe bashInteractive}"'

    # The account login shell is not always a usable terminal shell: service
    # and agent users commonly have nologin (and on NixOS its store path can
    # be garbage-collected), which made terminalEnvironment() report a path
    # that resolveExecutable() rejects with "is not an executable file",
    # breaking every default-shell terminal spawn. Only report the candidate
    # when it is an existing executable file; otherwise omit defaultShell so
    # the consumer (dsh-api-terminal-controller) picks the platform fallback
    # (/bin/sh on POSIX), per the documented terminalEnvironment contract.
    substituteInPlace \
      $out/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-subprocess-local/lib/index.js \
      --replace-fail \
      'const defaultShell = platform === "windows" ? process.env.ComSpec || void 0 : process.env.SHELL || userInfo().shell || void 0;' \
      'let defaultShell = platform === "windows" ? process.env.ComSpec || void 0 : process.env.SHELL || userInfo().shell || void 0; if (defaultShell !== void 0) try { if (!(await stat(defaultShell)).isFile()) defaultShell = void 0; else await access(defaultShell, constants.X_OK); } catch { defaultShell = void 0; }'

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
