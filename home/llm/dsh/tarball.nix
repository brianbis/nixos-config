# Build the @deepseek-ai/dsh npm tarball from the upstream source tree (the
# flakeless `dsh` flake input), replicating the upstream release pipeline
# (.github/workflows/release.yml at the pinned commit) on the stock nixpkgs
# pnpm machinery (see "pnpm" in the nixpkgs JS manual,
# doc/languages-frameworks/javascript.section.md):
#
#   1. pnpmDeps = fetchPnpmDeps { ... } — the workspace's pnpm store as one
#      fixed-output derivation: an online `pnpm install` from the source's
#      own pnpm-lock.yaml (pinned by the flake input's rev) downloads and
#      integrity-verifies every registry tarball, then bundles the store
#      (files/ + a reproducible v11 index.db SQL dump) into pnpm-store.tar.zst.
#      The whole pnpm side is pinned by its single `hash`.
#   2. pnpmConfigHook — in postConfigure, expands that store into the build
#      sandbox and runs `pnpm install --offline --ignore-scripts
#      --frozen-lockfile` (no --filter: the whole workspace, exactly like
#      CI), then patchShebangs node_modules.
#   3. build:official — build:lib (tsc -b + tsdown, host and client faces) +
#      build:web (vite) + the client build record.
#   4. pnpm --dir apps/cli pack — the same tarball the release workflow
#      publishes to npm (files: ["lib/*.js"] + package.json + README/LICENSE).
#
# The official client build profile requires DSH_CLIENT_COMMIT_HASH and
# DSH_CLIENT_VERSION in the environment (scripts/client-build-environment.ts
# throws without them); both are supplied from the pinned input (commit) and
# the root package.json (version) — the same values the corresponding
# dsh-vX.Y.Z tag build embeds. The source tree is not a git worktree; that is
# fine: repositoryCommitHash prefers the environment variable, and
# repositoryGitDirty returns undefined outside a worktree (no
# DSH_CLIENT_GIT_DIRTY is emitted). DSH_TELEMETRY_DISABLED matches the release
# workflow's env.
#
# pnpm version note: the repo pins packageManager pnpm@11.7.0; the nixpkgs
# pnpm (11.x) differs, but pnpmConfigHook exports pnpm_config_pm_on_fail=ignore
# (and pnpm_config_trust_lockfile=true), so the mismatch and the lockfile
# supply-chain re-verification are non-fatal. The lockfile (lockfileVersion
# 9.0) is read by pnpm 11. fetcherVersion = 4 (the reproducible v11 store
# dump) is the only fetcher this nixpkgs pin supports with pnpm 11.
#
# Moving the dsh rev (via `just dsh-repin`) changes the source's
# pnpm-lock.yaml and therefore this store pin: set `hash = ""`, build the
# dsh-tarball package, and paste the "output: sha256-…" value nix reports on
# the failed fetch.
{ lib, pkgs, src, commit, version }:

let
  pnpm = pkgs.pnpm_11; # the repo pins packageManager pnpm@11.x (see header)
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "dsh";
  inherit version;
  src = src;

  nativeBuildInputs = [
    pkgs.nodejs # 24.x — satisfies engines.node "^22.19.0 || >=24.0.0"
    pnpm # required by pnpmConfigHook; also on PATH for `pnpm run`
    pkgs.pnpmConfigHook # offline frozen workspace install from pnpmDeps
    # build:official's first stage (added after 0.1.2-alpha.5) runs
    # `build:native-system --host-addon-only`, which compiles the flock
    # Node-API addon (native/system/.../flock.c) with `cc` against the node
    # headers of the running node. stdenvNoCC ships no compiler, so provide
    # one. Only `cc` is needed: the host-addon-only filter skips the
    # static-musl landlock-run (musl-gcc) and the musl flock variant. pkgs.cc
    # is not a top-level attr in this nixpkgs pin; stdenv.cc is the default C
    # compiler (gcc-wrapper).
    pkgs.stdenv.cc
  ];

  # The pnpm store pin (see header). Regenerated per dsh rev: set to "",
  # build, and paste the "output: sha256-…" nix reports.
  pnpmDeps = pkgs.fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;
    # Store pin for the pinned rev (477b4f4, dsh 0.1.7-rc.2); `just dsh-repin`
    # refreshes it (set "", build, paste the reported "got: sha256-…").
    hash = "sha256-rDV6HxYwnPROBOP7/JY/cZ7kqmxv0zxOncjJghIvvM4=";
  };

  # Required by the official client build profile (see header).
  env.DSH_CLIENT_COMMIT_HASH = commit;
  env.DSH_CLIENT_VERSION = version;
  env.DSH_TELEMETRY_DISABLED = "1";

  # The offline workspace install already happened in postConfigure
  # (pnpmConfigHook); the product build needs nothing else first.
  buildPhase = ''
    runHook preBuild
    pnpm run build:official
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    pnpm --dir apps/cli pack --pack-destination $TMPDIR/dsh-pack
    mkdir -p $out
    mv "$TMPDIR/dsh-pack/deepseek-ai-dsh-${version}.tgz" $out/
    runHook postInstall
  '';

  passthru = {
    inherit commit pnpm;
    inherit (finalAttrs) pnpmDeps;
  };
})