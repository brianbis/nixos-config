{ pkgs, lib, ... }:

let
  # Pinned resurrect.wezterm fork (YedPool/Wezurrect). The derivation stubs
  # out the dev.wezterm network fetch and creates no git metadata in the
  # output, so the store path is stable across rebuilds.
  resurrect = pkgs.callPackage ./wezterm/resurrect.nix { };
in
{
  home.packages = [
    pkgs.wezterm
  ];

  # Symlinked into wezterm's plugin home so the checkout path stays stable
  # across store rebuilds; `require 'YedPool-Wezurrect'` resolves via
  # <plugin home>/YedPool-Wezurrect/plugin/init.lua (wezterm adds
  # <DATA_DIR>/plugins/?/plugin/init.lua to package.path unconditionally, so
  # no git repo is needed for local plugin loading).
  xdg.dataFile."wezterm/plugins/YedPool-Wezurrect".source = resurrect;

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