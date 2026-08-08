{
  services.xserver.enable = true;

  services.displayManager.sddm.enable = true;
  # Niri scrollable-tiling Wayland compositor. The system module wires up the
  # SDDM login session, xdg-desktop-portal, and gnome-keyring. Its runtime
  # config (binds, window rules) is written from home/niri.nix. Noctalia (the
  # shell/bar/launcher/etc.) runs on top of it via the `programs.noctalia`
  # home-manager module.
  programs.niri.enable = true;

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.printing.enable = true;
}
