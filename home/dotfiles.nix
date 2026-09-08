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
}
