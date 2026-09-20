{ config, ... }:

{
  home.file."dotfiles".source = config.lib.file.mkOutOfStoreSymlink "/etc/nixos/dotfiles";
  xdg.configFile."Code/User/settings.json".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/vscode-settings.json";

  # OLED palette for GTK3 apps (tether-gtk included). GTK3 loads
  # ~/.config/gtk-3.0/gtk.css after the active theme, so the @define-color
  # overrides in the stylesheet replace the theme's palette tokens everywhere.
  #
  # Written directly instead of via the gtk module: `gtk.enable` also takes
  # over ~/.gtkrc-2.0 and gtk-3.0/settings.ini, which already exist as system
  # files — home-manager then fails the switch trying to back them up over a
  # stale .bak. Only the css file is wanted here.
  xdg.configFile."gtk-3.0/gtk.css".text = builtins.readFile ../dotfiles/gtk-oled.css;

  # GTK3 apps (tether included) read ~/.config/gtk-3.0/settings.ini for
  # GtkSettings. A stale file (left behind after a removed tool) forced
  # gtk-application-prefer-dark-theme=false, overriding the dark OLED CSS and
  # whiting out Tether. Take it over with the dark variant, preserving the
  # Breeze settings it carried. force = true: a stale settings.ini..bak would
  # otherwise block the backup.
  xdg.configFile."gtk-3.0/settings.ini" = {
    force = true;
    source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/gtk3-settings.ini";
  };

  # GTK4 apps (tether included) read ~/.config/gtk-4.0/gtk.css, NOT the
  # gtk-3.0 file above — so the GTK3 palette never reached them and Tether
  # rendered white. Same OLED palette, managed the same way.
  xdg.configFile."gtk-4.0/gtk.css".text = builtins.readFile ../dotfiles/gtk4-oled.css;

  # Tether picks dark/light from the xdg-desktop-portal color-scheme, but no
  # portal is running here, so it falls back to the GtkSettings default (light).
  # Force the dark Adwaita variant directly. force = true: a stale
  # settings.ini..bak from a prior run would otherwise block the backup.
  xdg.configFile."gtk-4.0/settings.ini" = {
    force = true;
    text = ''
      [Settings]
      gtk-application-prefer-dark-theme=true
    '';
  };
}
