{ pkgs, lib, ... }:

let
  users = import ./users.nix;

  # Pinned copy of the resurrect.wezterm fork (YedPool/Wezurrect).
  #
  # Deployed as a symlink into wezterm's plugin home (see below). wezterm's
  # plugin.list() opens every checkout with libgit2 and requires a remote, so
  # the store path must be a git repo with an origin. The directory name must
  # keep "YedPool" so the plugin's dev.wezterm helper can locate it among the
  # installed plugins. Commit metadata is fixed so the output stays
  # reproducible.
  resurrect = pkgs.stdenvNoCC.mkDerivation {
    pname = "YedPool-Wezurrect";
    version = "7e2d093e";

    src = pkgs.fetchFromGitHub {
      owner = "YedPool";
      repo = "Wezurrect";
      rev = "7e2d093e49d896cc7db19fa9e3e582ecbdfd7f06";
      hash = "sha256-XDKe6whKaronWdnKcxnJK2fLJ8Ao8e3fg65rVBo5QGA=";
    };

    nativeBuildInputs = [ pkgs.gitMinimal ];
    dontBuild = true;

    installPhase = ''
      mkdir -p $out
      # $src is the repo root (stdenv's unpackPhase strips the archive's
      # top-level dir); $out must be the plugin root because wezterm loads
      # <plugin home>/YedPool-Wezurrect/plugin/init.lua, so a nested
      # top-level dir would break the plugin require.
      cp -r . $out/
      export GIT_AUTHOR_DATE="2026-08-17T16:44:08Z"
      export GIT_COMMITTER_DATE="2026-08-17T16:44:08Z"
      git -C $out init -q
      git -C $out add -A
      git -C $out -c user.name="nix" -c user.email="nix@localhost" \
        commit -qm "Wezurrect pinned at 7e2d093e"
      # plugin.list() needs a remote to report the checkout's origin.
      git -C $out remote add origin https://github.com/YedPool/Wezurrect.git
    '';

    meta = {
      description = "WezTerm session persistence plugin (resurrect.wezterm fork)";
      homepage = "https://github.com/YedPool/Wezurrect";
      license = lib.licenses.mit;
    };
  };
in
{
  home.packages = [
    pkgs.wezterm
    # Shelled out to by the plugin for encrypting/decrypting state files.
    pkgs.age
  ];

  # wezterm's plugin home is ~/.local/share/wezterm/plugins; `require
  # 'YedPool-Wezurrect'` in the config resolves via
  # <plugin home>/YedPool-Wezurrect/plugin/init.lua. The symlink keeps the
  # checkout path stable across store rebuilds.
  xdg.dataFile."wezterm/plugins/YedPool-Wezurrect".source = resurrect;

  # libgit2 (wezterm's plugin loader) ownership-checks each checkout by
  # lstat'ing workdir/gitdir with a trailing slash, which resolves the
  # symlink above to the builder-owned store path and fails; it then
  # consults safe.directory, where only a trailing "/*" is a prefix match.
  programs.git.settings.safe.directory = [
    "${users.b.homeDirectory}/.local/share/wezterm/plugins/*"
    "${resurrect}"
    "${resurrect}/*"
  ];

  # wezterm's config search order is ~/.wezterm.lua, then
  # <config dir>/wezterm/wezterm.lua (an app subdirectory); a flat
  # ~/.config/wezterm.lua is never read, so deploy into the subdirectory.
  xdg.configFile."wezterm/wezterm.lua".source = ../dotfiles/wezterm.lua;
}