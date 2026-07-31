# /etc/nixos/home/plasma.nix
{ pkgs, ... }:

let
  altF4Script = pkgs.writeShellScriptBin "alt-f4-close-or-shutdown" ''
    win="$(${pkgs.kdotool}/bin/kdotool getactivewindow 2>/dev/null)"

    if [ -n "$win" ]; then
      class="$(${pkgs.kdotool}/bin/kdotool getwindowclassname "$win" 2>/dev/null)"

      if [ "$class" != "plasmashell" ]; then
        ${pkgs.kdotool}/bin/kdotool windowclose "$win"
        exit 0
      fi
    fi

    # No normal application focused: open KDE logout/shutdown dialog
    busctl --user call org.kde.kglobalaccel /component/ksmserver \
      org.kde.kglobalaccel.Component invokeShortcut s "Log Out"
  '';
in
{
  home.packages = [
    pkgs.kdotool   # query/close the active window (Wayland-native)
    altF4Script    # also usable directly from a shell for testing
  ];

  xdg.dataFile."applications/bt-connect-headphones.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Connect Bluetooth Headphones
    NoDisplay=true
    StartupNotify=false
    Exec=bt-connect-headphones 10 3
    X-KDE-GlobalAccel-CommandShortcut=true
  '';

  xdg.dataFile."applications/alt-f4-close-or-shutdown.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Close window or show shutdown dialog
    NoDisplay=true
    StartupNotify=false
    Exec=${altF4Script}/bin/alt-f4-close-or-shutdown
    X-KDE-GlobalAccel-CommandShortcut=true
  '';

  programs.plasma = {
    enable = true;

    resetFilesExclude = [ "kwinrulesrc" ];

    shortcuts = {
      "services/org.kde.krunner.desktop" = {
        "_launch" = [ "Meta" "Alt+Space" ];
      };
      yakuake = {
        "toggle-window-state" = "Meta+R";
      };
      "services/org.kde.spectacle.desktop" = {
        "RecordRegion" = "none";
      };

      "plasmashell" = {
        "activate application launcher" = "none";
      };

      "kwin" = {
        "Window Close" = "none";
      };

      # Same proven pattern as the krunner entry above, applied to our
      # own command .desktop files, instead of hand-writing
      # kglobalshortcutsrc via configFile.
      "services/bt-connect-headphones.desktop" = {
        "_launch" = "Ctrl+Shift+C";
      };
      "services/alt-f4-close-or-shutdown.desktop" = {
        "_launch" = "Alt+F4";
      };
    };

    configFile = {
      kwinrc = {
        Windows = {
          FocusStealingPreventionLevel = 0;
        };
      };

      ksmserverrc = {
        General = {
          loginMode = "restorePreviousLogout";
        };
      };

      # Square off window corners. Best-known match for Breeze's
      # corner-radius setting — if it doesn't visibly change anything,
      # nudge the slider once in System Settings > Colors & Themes >
      # Window Decorations, then `cat ~/.config/breezerc` to confirm
      # the real key and I'll adjust this.
      breezerc = {
        Windeco = {
          CornerRadius = 0;
        };
      };
    };

    window-rules = [
      {
        description = "Discord - middle quarter";
        match.window-class = { value = "discord"; type = "substring"; };
        apply = {
          position = { value = "1280,0";      apply = "remember"; };
          size     = { value = "1280,1440"; apply = "remember"; };
          desktop  = { value = "1";         apply = "remember"; };
          screen   = { value = "0";         apply = "remember"; };
        };
      }
      {
        description = "Obsidian - middle quarter";
        match.window-class = { value = "obsidian"; type = "substring"; };
        apply = {
          position = { value = "1280,0";      apply = "remember"; };
          size     = { value = "1280,1440"; apply = "remember"; };
          desktop  = { value = "1";         apply = "remember"; };
          screen   = { value = "0";         apply = "remember"; };
        };
      }
      {
        description = "Firefox - right half";
        match.window-class = { value = "firefox"; type = "substring"; };
        apply = {
          position = { value = "2560,0";    apply = "remember"; };
          size     = { value = "2560,1440"; apply = "remember"; };
          desktop  = { value = "1";         apply = "remember"; };
          screen   = { value = "0";         apply = "remember"; };
        };
      }
      {
        description = "VS Code - left quarter half lower";
        match.window-class = { value = "code"; type = "substring"; };
        apply = {
          position = { value = "0,720";     apply = "remember"; };
          size     = { value = "1280,720"; apply = "remember"; };
          desktop  = { value = "1";       apply = "remember"; };
          screen   = { value = "0";       apply = "remember"; };
        };
      }
    ];
  };
}