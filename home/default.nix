{ pkgs, noctalia, ... }:

{
  imports = [
    ./packages.nix
    ./plasma.nix
    ./niri.nix
    ./hyprland.nix
    ./firefox
    ./sts.nix
    ./llm
    noctalia.homeModules.default
  ];

  # ── Desktop: Plasma default, Niri + Hyprland for testing ─────────────────
  # The full niri config (binds, window rules) is enabled in ./niri.nix, and
  # the Hyprland config in ./hyprland.nix. Plasma is the SDDM default session
  # (see hosts/desktop/plasma.nix); both tiling compositors remain selectable
  # from the login screen.

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
