# Build the @deepseek-ai/dsh npm tarball from the upstream source tree (the
# flakeless `dsh` flake input), replicating the upstream release pipeline
# (.github/workflows/release.yml at the pinned commit):
#
#   1. pnpm install --frozen-lockfile
#        The workspace closure comes from the source's own pnpm-lock.yaml
#        (pinned by the flake input's rev): one fetchurl fixed-output
#        derivation per registry tarball, each verified against its sha256
#        from deps-sha256.json (cross-checked against the lock's sha512
#        integrity by update-deps.py). assemble-pnpm-store.py expands the
#        tarballs into a pnpm v11 store (files/ + index.db), which
#        `pnpm install --offline --ignore-scripts --frozen-lockfile` then
#        consumes (no --filter, i.e. the whole workspace, exactly like CI).
#   2. pnpm run build:official
#        build:lib (tsc -b + tsdown, host and client faces) + build:web
#        (vite) + the client build record. Runs fully offline.
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
# DSH_CLIENT_GIT_DIRTY is emitted). DSH_TELEMETRY_DISABLED matches the release
# workflow's env.
#
# pnpm version note: the repo pins packageManager pnpm@11.7.0; the nixpkgs
# pnpm (11.x) differs, but pnpm 11 sets pnpm_config_pm_on_fail=ignore for the
# version mismatch, so it is non-fatal. The lockfile (lockfileVersion 9.0) is
# read by pnpm 11.
#
# Re-pin flow: `just dsh-repin` (= `nix flake update dsh` + update-deps.py)
# moves the source (and its pnpm-lock.yaml) and refreshes deps-sha256.json +
# pnpm-lock.json. No hashes to copy back — this file carries none.
{ lib, pkgs, src, commit, version }:

let
  # The pnpm lock is committed as JSON (this Nix has no builtins.fromYAML).
  # _meta.pnpmLockYamlSha256 stamps the source pnpm-lock.yaml it was converted
  # from, so a flake update without `just dsh-repin` fails loudly instead of
  # building against a stale lock.
  lock = builtins.fromJSON (builtins.readFile ./pnpm-lock.json);
  sha256 = builtins.fromJSON (builtins.readFile ./deps-sha256.json);

  linuxApplicable = e:
    (! (lib.hasAttr "os" e) || lib.elem "linux" e.os)
    && (! (lib.hasAttr "cpu" e) || lib.elem "x64" e.cpu);

  # The pnpm store index is keyed by pnpm's packageId: the base `packages`
  # key (name@version) with peer suffixes stripped. pnpm looks the store up by
  # this base id (its tryGetPackageId), so keying by the base package is
  # correct. For direct-tarball deps (name@<url>) the assembler re-keys to the
  # bare URL to match pnpm's lookup. The resolution (integrity/tarball) lives
  # on the base `packages` entry. Registry entries, filtered to linux-x64 (all
  # platform variants are listed; os/cpu live on the base entry). Keys are
  # name@version (scoped names start with @) or name@<url> for direct-tarball
  # deps.
  entries =
    lib.filter (b:
      let e = lock.packages.${b};
      in e ? resolution && e.resolution ? integrity && linuxApplicable e)
      (lib.attrNames lock.packages);

  # name@version key -> (name, version); url deps -> (name, url).
  splitKey = k:
    let parts = lib.splitString "@" k;
    in {
      name = lib.concatStringsSep "@" (lib.init parts);
      version = lib.last parts;
    };

  urlOf = b:
    let
      e = lock.packages.${b};
      nv = splitKey b;
      base = lib.last (lib.splitString "/" nv.name);
    in
      e.resolution.tarball
      or "https://registry.npmjs.org/${nv.name}/-/${base}-${nv.version}.tgz";

  # One fetchurl per unique tarball URL (fixed-output; the sha256 comes
  # from deps-sha256.json).
  urls = lib.unique (lib.map urlOf entries);
  tarballs = lib.listToAttrs (lib.map (u: {
    name = u;
    value = pkgs.fetchurl {
      url = u;
      sha256 = sha256.${u}
        or (throw "deps-sha256.json is missing ${u} — run home/llm/dsh/update-deps.py");
    };
  }) urls);

  # The pnpm v11 store, assembled from the fetched tarballs (see
  # assemble-pnpm-store.py for the layout and index.db format). The entries
  # JSON is a store path (writeText): inlining it as an env var would exceed
  # MAX_ARG_STRLEN (1400+ entries).
  storeEntries = pkgs.writeText "dsh-${version}-store-entries.json"
    (lib.toJSON (lib.map (b: {
      key = b;
      url = urlOf b;
      integrity = lock.packages.${b}.resolution.integrity;
      tarball = "${tarballs.${urlOf b}}";
    }) entries));

  pnpmStore = pkgs.runCommand "dsh-${version}-pnpm-store"
    {
      nativeBuildInputs = [ pkgs.python3 ];
    } ''
    OUT=$out \
    ENTRIES_FILE=${storeEntries} \
    ${lib.getExe pkgs.python3} ${./assemble-pnpm-store.py}
  '';
in
assert lock._meta.pnpmLockYamlSha256
    == builtins.hashFile "sha256" (src + "/pnpm-lock.yaml")
  || throw
    "stale home/llm/dsh/pnpm-lock.json: the dsh source moved without a re-pin; run `just dsh-repin`";
pkgs.stdenvNoCC.mkDerivation {
  pname = "dsh";
  inherit version;
  src = src;

  nativeBuildInputs = [
    pkgs.nodejs # 24.x — satisfies engines.node "^22.19.0 || >=24.0.0"
    pkgs.pnpm_11 # the repo pins packageManager pnpm@11.7.0 (see header)
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

  # Required by the official client build profile (see header).
  env.DSH_CLIENT_COMMIT_HASH = commit;
  env.DSH_CLIENT_VERSION = version;
  env.DSH_TELEMETRY_DISABLED = "1";

  buildPhase = ''
    runHook preBuild
    # Offline workspace install from the assembled store (the lockfile is
    # frozen; patchedDependencies are applied from the source's patches/).
    # pnpm_config_pm_on_fail=ignore: the repo pins packageManager pnpm@11.7.0,
    # the build runs pnpm 11.27.0; without it pnpm tries to resolve its own
    # core package (@pnpm/exe) for the pinned version, which fails offline
    # (same env pnpmConfigHook sets). Exported for the whole phase so `pnpm
    # run build:official` (and any nested pnpm calls it spawns) skip the
    # packageManager version check too.
    # pnpm_config_trust_lockfile=true: skip pnpm 11's supply-chain policy
    # re-verification of the lockfile, which fetches per-package registry
    # metadata and fails offline (ERR_PNPM_NO_OFFLINE_META). The lockfile is
    # the pinned source's own (flake.lock rev) and every tarball is
    # integrity-verified by update-deps.py + fetchurl.
    export pnpm_config_pm_on_fail=ignore
    export pnpm_config_trust_lockfile=true
    # pnpm's v11 store (v11/files + v11/index.db) is a read-only Nix store
    # path, but `pnpm install` opens index.db read-write (it records
    # side-effects / updates the package_index), which fails with "attempt to
    # write a readonly database". Copy it to a writable dir and use that; the
    # store files are 0444/0555, so chmod the copy too.
    cp -r ${pnpmStore} "$TMPDIR/pnpm-store"
    chmod -R u+w "$TMPDIR/pnpm-store"
    pnpm install --offline --ignore-scripts --frozen-lockfile \
      --store-dir "$TMPDIR/pnpm-store"
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
    inherit commit pnpmStore;
  };
}
