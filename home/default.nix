{ pkgs, noctalia, ... }:

{
  imports = [
    ./packages.nix
    ./niri.nix
    ./firefox
    ./sts.nix
    ./llm
    noctalia.homeModules.default
  ];

  # ── Desktop: Niri compositor + Noctalia shell ─────────────────────────────
  # The full niri config (binds, window rules) is enabled in ./niri.nix.

  # Noctalia provides the shell layer (bars, launcher, notifications, lock
  # screen, wallpaper, session actions) on top of Niri. Its home module manages
  # the package + config; Noctalia is launched by niri's `spawn-at-startup` in
  # ./niri.nix (systemd.enable is off to avoid double-launching it).
  programs.noctalia = {
    enable = true;
    systemd.enable = false;
  };

  # Discord Autostart
  xdg.configFile."autostart/discord.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Discord
    Exec=${pkgs.discord}/bin/discord --start-minimized
    Hidden=false
    NoDisplay=false
  '';

  home.username = "b";
  home.homeDirectory = "/home/b";

  home.stateVersion = "26.05";
}
