{ pkgs, lib, src, version }:

# Pinned resurrect.wezterm fork (YedPool/Wezurrect), deployed as a symlink
# into wezterm's plugin home. The dev.wezterm helper the plugin used to fetch
# from GitHub at config-load time is stubbed out (resurrect-dev-stub.patch)
# so no runtime network access is needed. No git metadata is created in $out
# (nothing at runtime needs it: wezterm's local plugin require never touches
# git), so the output is byte-identical across rebuilds and the store path
# is stable.
pkgs.stdenvNoCC.mkDerivation {
  pname = "YedPool-Wezurrect";
  # Source + version from the flakeless `wezurrect` input (see flake.nix);
  # `nix flake update wezurrect` re-pins it.
  inherit version src;

  # stdenvNoCC does not add patch by default; the default patchPhase runs
  # `patch -p1` for each entry in patches.
  nativeBuildInputs = [ pkgs.gnupatch ];

  patches = [ ./resurrect-dev-stub.patch ];

  dontBuild = true;

  installPhase = ''
    mkdir -p $out
    # $src is the repo root (unpackPhase strips the top-level dir); $out must
    # be the plugin root — wezterm loads <plugin home>/YedPool-Wezurrect/
    # plugin/init.lua — so a nested dir would break the plugin require.
    cp -r . $out/
  '';

  meta = {
    description = "WezTerm session persistence plugin (resurrect.wezterm fork), with the dev.wezterm network fetch stubbed out";
    homepage = "https://github.com/YedPool/Wezurrect";
    license = lib.licenses.mit;
  };
}