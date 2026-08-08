# Niri compositor configuration (written directly as config.kdl because the
# pinned home-manager predates the `wayland.windowManager.niri` home module).
# The niri binary + session come from `programs.niri.enable` in
# hosts/desktop/plasma.nix; SDDM launches `niri-session`, and niri starts the
# Noctalia shell via `spawn-at-startup` below.
#
# This mirrors niri's shipped default-config.kdl (so every key/action here is
# known-valid) with three intentional changes:
#   * spawn-at-startup launches Noctalia instead of waybar,
#   * Mod+T opens `foot` instead of alacritty,
#   * extra window-rules + a Bluetooth binding are appended.
{
  xdg.configFile."niri/config.kdl".text = ''
    input {
        keyboard {
            xkb {
                layout "us"
                variant ""
            }
        }
        touchpad {
            natural-scroll
        }
    }

    layout {
        gaps 16
        center-focused-column "never"
        default-column-width { proportion 0.5 }
        focus-ring {
            width 4
            active-color "#7fc8ff"
            inactive-color "#505050"
        }
        border {
            width 2
            active-color "#ffc87f"
            inactive-color "#505050"
        }
        struts {}
    }

    // Noctalia is the desktop shell (bars, launcher, notifications, etc.).
    // Launch it here so it starts only once the compositor + its Wayland
    // socket are ready.
    spawn-at-startup "noctalia"

    binds {
        Mod+Shift+Slash hotkey-overlay-title="Show a list of important hotkeys" { show-hotkey-overlay; }
        Mod+T hotkey-overlay-title="Open a Terminal: foot" { spawn "foot"; }

        Mod+O repeat=false { toggle-overview; }
        Mod+Q repeat=false { close-window; }
        Mod+Shift+E { quit; }

        Mod+Left  { focus-column-left; }
        Mod+Down  { focus-window-down; }
        Mod+Up    { focus-window-up; }
        Mod+Right { focus-column-right; }
        Mod+H     { focus-column-left; }
        Mod+J     { focus-window-down; }
        Mod+K     { focus-window-up; }
        Mod+L     { focus-column-right; }

        Mod+Ctrl+Left  { move-column-left; }
        Mod+Ctrl+Down  { move-window-down; }
        Mod+Ctrl+Up    { move-window-up; }
        Mod+Ctrl+Right { move-column-right; }
        Mod+Ctrl+H     { move-column-left; }
        Mod+Ctrl+J     { move-window-down; }
        Mod+Ctrl+K     { move-window-up; }
        Mod+Ctrl+L     { move-column-right; }

        Mod+Home { focus-column-first; }
        Mod+End  { focus-column-last; }
        Mod+Ctrl+Home { move-column-to-first; }
        Mod+Ctrl+End  { move-column-to-last; }

        Mod+Shift+Left  { focus-monitor-left; }
        Mod+Shift+Down  { focus-monitor-down; }
        Mod+Shift+Up    { focus-monitor-up; }
        Mod+Shift+Right { focus-monitor-right; }

        Mod+Page_Down      { focus-workspace-down; }
        Mod+Page_Up        { focus-workspace-up; }
        Mod+U              { focus-workspace-down; }
        Mod+I              { focus-workspace-up; }
        Mod+Ctrl+Page_Down { move-column-to-workspace-down; }
        Mod+Ctrl+Page_Up   { move-column-to-workspace-up; }

        Mod+1 { focus-workspace 1; }
        Mod+2 { focus-workspace 2; }
        Mod+3 { focus-workspace 3; }
        Mod+4 { focus-workspace 4; }
        Mod+5 { focus-workspace 5; }
        Mod+6 { focus-workspace 6; }
        Mod+7 { focus-workspace 7; }
        Mod+8 { focus-workspace 8; }
        Mod+9 { focus-workspace 9; }
        Mod+Ctrl+1 { move-column-to-workspace 1; }
        Mod+Ctrl+2 { move-column-to-workspace 2; }
        Mod+Ctrl+3 { move-column-to-workspace 3; }
        Mod+Ctrl+4 { move-column-to-workspace 4; }
        Mod+Ctrl+5 { move-column-to-workspace 5; }
        Mod+Ctrl+6 { move-column-to-workspace 6; }
        Mod+Ctrl+7 { move-column-to-workspace 7; }
        Mod+Ctrl+8 { move-column-to-workspace 8; }
        Mod+Ctrl+9 { move-column-to-workspace 9; }

        Mod+BracketLeft  { consume-or-expel-window-left; }
        Mod+BracketRight { consume-or-expel-window-right; }

        Mod+R { switch-preset-column-width; }
        Mod+Shift+R { switch-preset-column-width-back; }
        Mod+Ctrl+Shift+R { switch-preset-window-height; }
        Mod+Ctrl+R { reset-window-height; }

        XF86AudioRaiseVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05+"; }
        XF86AudioLowerVolume allow-when-locked=true { spawn-sh "wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05-"; }
        XF86AudioMute        allow-when-locked=true { spawn-sh "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; }

        XF86MonBrightnessUp   allow-when-locked=true { spawn-sh "brightnessctl set +10%"; }
        XF86MonBrightnessDown allow-when-locked=true { spawn-sh "brightnessctl set 10%-"; }

        // Bluetooth headphones (ported from the KDE global shortcut Ctrl+Shift+C).
        Ctrl+Shift+C hotkey-overlay-title="Connect Bluetooth Headphones" { spawn-sh "bt-connect-headphones 10 3"; }
    }

    // Send the old KDE window-rules apps to dedicated workspaces.
    window-rule {
        match app-id="discord"
        open-on-workspace "apps"
    }
    window-rule {
        match app-id="obsidian"
        open-on-workspace "apps"
    }
    window-rule {
        match app-id="firefox"
        open-on-workspace "web"
    }
    window-rule {
        match app-id="code"
        open-on-workspace "dev"
    }
  '';
}
