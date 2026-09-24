# Build the @deepseek-ai/dsh npm tarball from the upstream source tree (the
# flakeless `dsh` flake input), replicating the upstream release pipeline
# (.github/workflows/release.yml at the pinned commit):
#
#   1. pnpm install --frozen-lockfile
#        via pkgs.fetchPnpmDeps — a fixed-output derivation (the only
#        network step; FODs are exempt from the build sandbox's network
#        block). It packages the resulting pnpm store as a reproducible
#        pnpm-store.tar.zst.
#   2. pnpm run build:official
#        build:lib (tsc -b + tsdown, host and client faces) + build:web
#        (vite) + the client build record. Runs fully offline: the
#        pnpmConfigHook unpacks the fetched store at postConfigure and
#        runs `pnpm install --offline --ignore-scripts --frozen-lockfile`
#        (no --filter, i.e. the whole workspace, exactly like CI).
#   3. pnpm --dir apps/cli pack
#        the same tarball the release workflow publishes to npm
#        (files: ["lib/*.js"] + package.json + README/LICENSE).
#
# The official client build profile requires DSH_CLIENT_COMMIT_HASH and
# DSH_CLIENT_VERSION in the environment (scripts/client-build-environment.ts
# throws without them); both are supplied from the pinned input (commit) and
# the root package.json (version) — the same values the corresponding
# dsh-vX.Y.Z tag build embeds. The source tree is not a git worktree; that is
# fine: repositoryCommitHash prefers the environment variable, and
# repositoryGitDirty returns undefined outside a worktree (no
# DSH_CLIENT_GIT_DIRTY is emitted). DSH_TELEMETRY_DISABLED matches the
# release workflow's env.
#
# pnpm version note: the repo pins packageManager pnpm@11.7.0; the nixpkgs
# pnpm (11.x) differs, but both the fetcher and the config hook set
# pnpm_config_pm_on_fail=ignore for pnpm 11, so the mismatch is non-fatal.
# The lockfile (lockfileVersion 9.0) is read by pnpm 11.
{ pkgs, src, commit, version }:

let
  pnpmDeps = pkgs.fetchPnpmDeps {
    inherit src;
    pname = "dsh";
    fetcherVersion = 4;
    # Pin the pnpm that builds the store. nixpkgs' default `pnpm` moved from
    # 11.x to 12.x; pnpm 12 normalizes the root-relative `link:` overrides in
    # pnpm-workspace.yaml differently and fails the --frozen-lockfile check
    # against this pnpm-11 (lockfileVersion 9.0) lockfile. The repo pins
    # packageManager pnpm@11.7.0, so build with pnpm 11.
    pnpm = pkgs.pnpm_11;
    # Recursive hash of the reproducible pnpm-store.tar.zst (fetcherVersion 4,
    # pnpm 11.27.0, lockfileVersion 9.0 at the pinned commit). Sub-pin of the
    # npm closure: re-pin when `nix flake update dsh` moves the lockfile
    # (set to "", build, copy the `got: sha256-…` value back).
    hash = "sha256-i5XoYAHernnWFi3iAMrTUPJ5CQB4yx8XeSaChMotGyI=";
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "dsh";
  inherit version;
  src = src;

  nativeBuildInputs = [
    pkgs.nodejs # 24.x — satisfies engines.node "^22.19.0 || >=24.0.0"
    pkgs.pnpm_11 # match the fetchPnpmDeps pnpm (see pnpmDeps above)
    pkgs.pnpmConfigHook
    # build:official's first stage (added after 0.1.2-alpha.5) runs
    # `build:native-system --host-addon-only`, which compiles the flock
    # Node-API addon (native/system/.../flock.c) with `cc` against the node
    # headers of the running node. stdenvNoCC ships no compiler, so provide
    # one. Only `cc` is needed: the host-addon-only filter skips the
    # static-musl landlock-run (musl-gcc) and the musl flock variant.
    # pkgs.cc is not a top-level attr in this nixpkgs pin; stdenv.cc is the
    # default C compiler (gcc-wrapper).
    pkgs.stdenv.cc
  ];

  # Consumed by pnpmConfigHook (see header).
  pnpmDeps = pnpmDeps;

  # Required by the official client build profile (see header).
  env.DSH_CLIENT_COMMIT_HASH = commit;
  env.DSH_CLIENT_VERSION = version;
  env.DSH_TELEMETRY_DISABLED = "1";

  # No dontConfigure: pnpmConfigHook runs at postConfigure (a dontConfigure
  # would skip the whole configure phase, hooks included). The default
  # configure body is a no-op for a JS tree (no ./configure).
  buildPhase = ''
    runHook preBuild
    pnpm run build:official
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    pnpm --dir apps/cli pack --pack-destination $TMPDIR/dsh-pack
    mv "$TMPDIR/dsh-pack/deepseek-ai-dsh-${version}.tgz" $out
    runHook postInstall
  '';

  passthru = {
    inherit commit pnpmDeps;
  };
}
