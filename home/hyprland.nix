# Hyprland compositor configuration, written as the Lua config that replaced
# hyprlang in Hyprland 0.55+ (the old hyprland.conf format is removed in
# 0.57). The hyprland binary and SDDM session entry come from
# `programs.hyprland.enable` in hosts/desktop/plasma.nix.
#
# This mirrors the niri keybindings where sensible (Mod = SUPER), so muscle
# memory carries over between the two tiling compositors. No shell/bar is
# started here: Hyprland is a testbed, Plasma remains the daily driver.
{
  xdg.configFile."hypr/hyprland.lua".text = ''
    -- ── Environment ─────────────────────────────────────────────────────────
    hl.env("XCURSOR_SIZE", "24")

    -- NVIDIA
    hl.env("GBM_BACKEND", "nvidia-drm")
    hl.env("WLR_NO_HARDWARE_CURSORS", "1")
    hl.env("LIBVA_DRIVER_NAME", "nvidia")

    -- Auto-detect monitors
    hl.monitor({ output = "", mode = "preferred", position = "auto", scale = 1 })

    -- Start the session environment
    hl.on("hyprland.start", function()
        hl.exec_cmd("dbus-update-activation-environment --systemd --all")
        hl.exec_cmd("systemctl --user import-environment")
    end)

    -- ── General ─────────────────────────────────────────────────────────────
    hl.config({
        general = {
            gaps_in      = 8,
            gaps_out     = 16,
            border_size  = 2,
            col = {
                active_border   = "rgba(7fc8ffff)",
                inactive_border = "rgba(505050ff)",
            },
            layout = "dwindle",
        },
        decoration = {
            rounding = 8,
        },
        animations = {
            enabled = true,
        },
        dwindle = {
            preserve_split = true,
        },
        input = {
            kb_layout   = "us",
            follow_mouse = 1,
            touchpad = {
                natural_scroll = true,
            },
        },
        misc = {
            disable_hyprland_logo = true,
        },
    })

    -- Animations
    hl.curve("easeOutCubic", { type = "bezier", points = { { 0.33, 1 }, { 0.68, 1 } } })
    hl.animation({ leaf = "windows",    enabled = true, speed = 4, bezier = "easeOutCubic" })
    hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "easeOutCubic" })

    -- ── Keybinds (Mod = SUPER) ──────────────────────────────────────────────
    hl.bind("SUPER + T", hl.dsp.exec_cmd("foot"))
    hl.bind("SUPER + D", hl.dsp.exec_cmd("fuzzel"))
    hl.bind("SUPER + Q", hl.dsp.window.close())
    hl.bind("SUPER + SHIFT + E", hl.dsp.exit())

    hl.bind("SUPER + H", hl.dsp.focus({ direction = "left" }))
    hl.bind("SUPER + J", hl.dsp.focus({ direction = "down" }))
    hl.bind("SUPER + K", hl.dsp.focus({ direction = "up" }))
    hl.bind("SUPER + L", hl.dsp.focus({ direction = "right" }))
    hl.bind("SUPER + LEFT",  hl.dsp.focus({ direction = "left" }))
    hl.bind("SUPER + DOWN",  hl.dsp.focus({ direction = "down" }))
    hl.bind("SUPER + UP",    hl.dsp.focus({ direction = "up" }))
    hl.bind("SUPER + RIGHT", hl.dsp.focus({ direction = "right" }))

    hl.bind("SUPER + CTRL + H", hl.dsp.window.move({ direction = "left" }))
    hl.bind("SUPER + CTRL + J", hl.dsp.window.move({ direction = "down" }))
    hl.bind("SUPER + CTRL + K", hl.dsp.window.move({ direction = "up" }))
    hl.bind("SUPER + CTRL + L", hl.dsp.window.move({ direction = "right" }))
    hl.bind("SUPER + CTRL + LEFT",  hl.dsp.window.move({ direction = "left" }))
    hl.bind("SUPER + CTRL + DOWN",  hl.dsp.window.move({ direction = "down" }))
    hl.bind("SUPER + CTRL + UP",    hl.dsp.window.move({ direction = "up" }))
    hl.bind("SUPER + CTRL + RIGHT", hl.dsp.window.move({ direction = "right" }))

    for i = 1, 9 do
        hl.bind("SUPER + " .. i, hl.dsp.focus({ workspace = i }))
        hl.bind("SUPER + CTRL + " .. i, hl.dsp.window.move({ workspace = i }))
    end

    hl.bind("SUPER + F", hl.dsp.window.fullscreen({ action = "toggle" }))
    hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))

    hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05+"), { locked = true, repeating = true })
    hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.05-"), { locked = true, repeating = true })
    hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"), { locked = true })
    hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd("brightnessctl set +10%"), { locked = true, repeating = true })
    hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("brightnessctl set 10%-"), { locked = true, repeating = true })

    hl.bind("SUPER + mouse:272", hl.dsp.window.drag(),   { mouse = true })
    hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })

    -- ── Window rules: same app → workspace mapping as niri ──────────────────
    hl.window_rule({
        name      = "discord-workspace",
        match     = { class = "^(discord)$" },
        workspace = "2 silent",
    })
    hl.window_rule({
        name      = "obsidian-workspace",
        match     = { class = "^(obsidian)$" },
        workspace = "2 silent",
    })
    hl.window_rule({
        name      = "firefox-workspace",
        match     = { class = "^(firefox)$" },
        workspace = "3 silent",
    })
    hl.window_rule({
        name      = "code-workspace",
        match     = { class = "^(code)$" },
        workspace = "4 silent",
    })
  '';
}
