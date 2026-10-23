{ lib, pkgs, src, commit, version }:

let
  pnpm = pkgs.pnpm_11;
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "dsh";
  inherit version;
  src = src;

  nativeBuildInputs = [
    pkgs.nodejs
    pnpm
    pkgs.pnpmConfigHook
    pkgs.stdenv.cc
  ];

  pnpmDeps = pkgs.fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    inherit pnpm;
    fetcherVersion = 4;

    hash = "sha256-C9Aw9AS4r7zubaEuT6mLXQ+AhhMVlTxPZRKTpzRUkcU=";
  };

  env.DSH_CLIENT_COMMIT_HASH = commit;
  env.DSH_CLIENT_VERSION = version;
  env.DSH_TELEMETRY_DISABLED = "1";
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
