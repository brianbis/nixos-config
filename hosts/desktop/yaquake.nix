{ config, pkgs, lib, ... }:

let
  yakuakeToggle = pkgs.writeShellScriptBin "yakuake-toggle" ''
    ${pkgs.qt6Packages.qttools}/bin/qdbus org.kde.yakuake /yakuake/sessions org.kde.yakuake.toggleWindow >/dev/null 2>&1 || true
  '';
in
{
  environment.systemPackages = [
    pkgs.yakuake
    yakuakeToggle
  ];

  programs.bash.interactiveShellInit = ''
    if [[ $- == *i* ]]; then
      __yakuake_escape_toggle() {
        if [[ -z "$READLINE_LINE" && -z "$READLINE_POINT" ]]; then
          ${yakuakeToggle}/bin/yakuake-toggle
        else
          READLINE_LINE=$'\e'"$READLINE_LINE"
          READLINE_POINT=$((READLINE_POINT + 1))
        fi
      }

      bind -x '"\e":__yakuake_escape_toggle'
    fi
  '';

  environment.etc."xdg/autostart/yakuake.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Yakuake
    Exec=${pkgs.yakuake}/bin/yakuake
    X-KDE-autostart-after=panel
    X-GNOME-Autostart-enabled=true
  '';

  environment.etc."yakuake/yakuake.conf".text = ''
    [Shortcuts]
    toggle-window=none
  '';

  systemd.user.services.yakuake = {
    description = "Yakuake drop-down terminal";
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.yakuake}/bin/yakuake";
      Restart = "on-failure";
    };
  };
}