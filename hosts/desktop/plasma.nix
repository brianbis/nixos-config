{
  services.xserver.enable = true;

  services.displayManager.sddm.enable = true;

  # Plasma is the daily driver and the default session.
  services.desktopManager.plasma6.enable = true;
  services.displayManager.defaultSession = "plasma";

  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.printing.enable = true;
}
