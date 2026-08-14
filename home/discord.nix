{ pkgs, ... }:

{
  xdg.configFile."autostart/discord.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Discord
    Exec=${pkgs.discord}/bin/discord --start-minimized
    Hidden=false
    NoDisplay=false
  '';
}
