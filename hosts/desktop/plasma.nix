{
  services.xserver.enable = true;

  services.displayManager.sddm.enable = true;

  # Plasma is the daily driver and the default session. Niri and Hyprland stay
  # installed as selectable SDDM sessions for testing the tiling compositors.
  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = "plasma";

  # Niri scrollable-tiling Wayland compositor. The system module wires up the
  # SDDM login session, xdg-desktop-portal, and gnome-keyring. Its runtime
  # config (binds, window rules) is written from home/niri.nix. Noctalia (the
  # shell/bar/launcher/etc.) runs on top of it via the `programs.noctalia`
  # home-manager module.
  #programs.niri.enable = true;

  # Hyprland dynamic-tiling Wayland compositor, alternative to niri. The
  # system module adds the SDDM session + xdg-desktop-portal; its runtime
  # config (binds, window rules) is written from home/hyprland.nix.
  #programs.hyprland.enable = true;

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.printing.enable = true;
}
