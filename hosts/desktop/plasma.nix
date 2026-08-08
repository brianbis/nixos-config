{
  services.xserver.enable = true;

  services.displayManager.sddm.enable = true;

  # Keep Plasma installed as a login-screen fallback: if a future niri
  # config fails to parse, pick the Plasma session from SDDM instead of
  # fighting a bare desktop. Niri remains the default session.
  services.desktopManager.plasma6.enable = true;

  # Niri scrollable-tiling Wayland compositor. The system module wires up the
  # SDDM login session, xdg-desktop-portal, and gnome-keyring. Its runtime
  # config (binds, window rules) is written from home/niri.nix. Noctalia (the
  # shell/bar/launcher/etc.) runs on top of it via the `programs.noctalia`
  # home-manager module.
  programs.niri.enable = true;
  services.displayManager.defaultSession = "niri";

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.printing.enable = true;
}
