{ pkgs, lib, ... }:

let
  users = import ./users.nix;

  # Pinned resurrect.wezterm fork (YedPool/Wezurrect), deployed as a symlink
  # into wezterm's plugin home. The dir name keeps "YedPool" so the dev.wezterm
  # helper can locate it; commit metadata is fixed for reproducibility.
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
      # $src is the repo root (unpackPhase strips the top-level dir); $out must
      # be the plugin root — wezterm loads <plugin home>/YedPool-Wezurrect/
      # plugin/init.lua — so a nested dir would break the plugin require.
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
    # For the resurrect plugin's optional age-based state encryption
    # (disabled; state is unencrypted — see wezterm.lua).
    pkgs.age
  ];

  # Symlinked into wezterm's plugin home so the checkout path stays stable
  # across store rebuilds; `require 'YedPool-Wezurrect'` resolves via
  # <plugin home>/YedPool-Wezurrect/plugin/init.lua.
  xdg.dataFile."wezterm/plugins/YedPool-Wezurrect".source = resurrect;

  # libgit2 ownership-checks each checkout by lstat'ing workdir/gitdir with a
  # trailing slash, resolving the symlink to the builder-owned store path and
  # failing; safe.directory only prefix-matches with a trailing "/*".
  programs.git.settings.safe.directory = [
    "${users.b.homeDirectory}/.local/share/wezterm/plugins/*"
    "${resurrect}"
    "${resurrect}/*"
  ];

  # wezterm's config search order is ~/.wezterm.lua, then
  # <config dir>/wezterm/wezterm.lua (an app subdirectory); a flat
  # ~/.config/wezterm.lua is never read, so deploy into the subdirectory.
  xdg.configFile."wezterm/wezterm.lua".source = ../dotfiles/wezterm.lua;

  # KRunner "cmd" alias. Plasma 6's KRunner services runner scores matches by
  # field weight (name 100 > genericName 50 > keywords 25). xterm, konsole and
  # wezterm all only match "cmd" via Keywords (weight 25), so they tie and xterm
  # wins. A dedicated entry whose Name is exactly "cmd" is a perfect name match
  # (weight 100), guaranteeing it ranks #1 for "cmd" and launches wezterm.
  xdg.desktopEntries."wezterm-cmd" = {
    name = "cmd";
    comment = "WezTerm terminal (cmd alias)";
    exec = "wezterm start";
    icon = "org.wezfurlong.wezterm";
    type = "Application";
    categories = [ "System" "TerminalEmulator" "Utility" ];
    settings = {
      GenericName = "WezTerm";
      Keywords = "cmd;command;terminal;shell";
      StartupWMClass = "org.wezfurlong.wezterm";
      TryExec = "wezterm";
    };
  };
}
