{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "set-monitor-layout" ''
      ${kdePackages.libkscreen}/bin/kscreen-doctor \
        output.44c78251-554f-4915-a414-1116103ffca5.mode.4 \
        output.44c78251-554f-4915-a414-1116103ffca5.position.0,0 \
        output.9fe3d83c-3001-4598-95a0-ba1fadab3b15.mode.30 \
        output.9fe3d83c-3001-4598-95a0-ba1fadab3b15.position.5120,0
    '')
  ];

  environment.etc."xdg/autostart/set-monitor-layout.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Set monitor layout
    Exec=set-monitor-layout
    X-KDE-autostart-after=panel
  '';
}