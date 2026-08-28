{ config, pkgs, ... }:

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

  # Win+R handler: focus the existing wezterm window if one is open,
  # otherwise launch a new instance.
  #
  # Focusing uses KWin's D-Bus scripting API (the run-or-raise mechanism
  # kwinctrl uses): load a JS script, run it (which sets the active window),
  # then stop it. The JS mirrors kwinctrl's proven approach — setActiveWindow
  # / setActiveClient are NOT global KWin functions, so a local helper sets
  # the workspace.activeWindow / activeClient property instead.
  weztermFocusJs = pkgs.writeText "wezterm-focus.js" ''
    function focusWindow(c) {
      c.minimized = false;
      if (c.fullScreen) c.fullScreen = false;
      if (workspace.activeClient !== undefined) workspace.activeClient = c;
      else workspace.activeWindow = c;
    }
    var cs = workspace.clientList ? workspace.clientList() : workspace.windowList();
    for (var i = 0; i < cs.length; i++) {
      var rc = String(cs[i].resourceClass).toLowerCase();
      if (rc.indexOf('wezterm') >= 0) {
        focusWindow(cs[i]);
        break;
      }
    }
  '';

  weztermFocusScript = pkgs.writeShellScriptBin "wezterm-focus" ''
    # Launch if no wezterm process is running at all.
    if ! { pgrep -x wezterm > /dev/null 2>&1 || pgrep -x wezterm-gui > /dev/null 2>&1; }; then
      exec wezterm start
    fi

    # Load the JS script → returns an i32 script ID.
    id=$(busctl --user call org.kde.KWin /Scripting org.kde.kwin.Scripting \
      loadScript ss "${weztermFocusJs}" "wezterm-focus" | awk '/^i /{print $2}')

    [ -n "$id" ] || exit 0

    # Run then unload.
    busctl --user call org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script run
    busctl --user call org.kde.KWin "/Scripting/Script$id" org.kde.kwin.Script stop
  '';
in
{
  home.packages = [
    pkgs.kdotool # query/close the active window (Wayland-native)
    altF4Script # also usable directly from a shell for testing
    weztermFocusScript # Win+R: focus or launch wezterm
  ];

  xdg.dataFile."applications/bt-connect-headphones.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Connect Bluetooth Headphones
    NoDisplay=true
    StartupNotify=false
    Exec=bt-connect-headphones
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

  # Hidden launcher so Plasma registers it in kglobalaccelsrc (Win+R).
  # NoDisplay=true keeps it out of menus; X-KDE-GlobalAccel-CommandShortcut=true
  # tells Plasma to allow binding a global shortcut to this entry.
  xdg.dataFile."applications/wezterm-launch.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=WezTerm Terminal
    NoDisplay=true
    StartupNotify=false
    Exec=${weztermFocusScript}/bin/wezterm-focus
    Icon=org.gnome.Terminal
    Categories=System;TerminalEmulator;
    X-KDE-GlobalAccel-CommandShortcut=true
  '';

  programs.plasma = {
    enable = true;

    resetFilesExclude = [ "kwinrulesrc" ];

    shortcuts = {
      "services/org.kde.krunner.desktop" = {
        "_launch" = [ "Meta" "Alt+Space" ];
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
      # Win+R → focus or launch wezterm (replaces the old yakuake binding).
      "services/wezterm-launch.desktop" = {
        "_launch" = "Meta+R";
      };
    };

    configFile = {
      kdeglobals = {
        General = {
          ColorScheme = "BreezeDark";
        };

        "Colors:View" = {
          BackgroundNormal = "0,0,0";
          BackgroundAlternate = "0,0,0";
        };

        "Colors:Window" = {
          BackgroundNormal = "0,0,0";
          BackgroundAlternate = "0,0,0";
        };
      };
      konsolerc = {
        "Desktop Entry" = {
          DefaultProfile = "OLED.profile";
        };
      };
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
    };

    window-rules = [
      {
        description = "Discord - middle quarter";
        match.window-class = { value = "discord"; type = "substring"; };
        apply = {
          position = { value = "1280,0"; apply = "remember"; };
          size = { value = "1280,1440"; apply = "remember"; };
          desktop = { value = "1"; apply = "remember"; };
          screen = { value = "0"; apply = "remember"; };
        };
      }
      {
        description = "Obsidian - middle quarter";
        match.window-class = { value = "obsidian"; type = "substring"; };
        apply = {
          position = { value = "1280,0"; apply = "remember"; };
          size = { value = "1280,1440"; apply = "remember"; };
          desktop = { value = "1"; apply = "remember"; };
          screen = { value = "0"; apply = "remember"; };
        };
      }
      {
        description = "Firefox - right half";
        match.window-class = { value = "firefox"; type = "substring"; };
        apply = {
          position = { value = "2560,0"; apply = "remember"; };
          size = { value = "2560,1440"; apply = "remember"; };
          desktop = { value = "1"; apply = "remember"; };
          screen = { value = "0"; apply = "remember"; };
        };
      }
      {
        description = "VS Code - left quarter half lower";
        match.window-class = { value = "code"; type = "substring"; };
        apply = {
          position = { value = "0,720"; apply = "remember"; };
          size = { value = "1280,720"; apply = "remember"; };
          desktop = { value = "1"; apply = "remember"; };
          screen = { value = "0"; apply = "remember"; };
        };
      }
    ];
  };

  # Default terminal handler for x-terminal-emulator (right-click → open with,
  # xdg-open). The Nix wezterm package installs org.wezfurlong.wezterm.desktop,
  # so the MIME default must reference that exact filename.
  xdg.mimeApps.defaultApplications = {
    "x-terminal-emulator" = "org.wezfurlong.wezterm.desktop";
  };
}
