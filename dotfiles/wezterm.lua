-- Pure-black OLED palette and 500000-line scrollback match the konsole OLED
-- profile (dotfiles/konsole/OLED.colorscheme); keep them in sync.
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Session persistence via resurrect.wezterm (YedPool/Wezurrect fork), pinned
-- in the Nix store and symlinked into wezterm's plugin home. State JSONs
-- (incl. scrollback) are unencrypted; /home/b is 0700 so only b can read them.
local resurrect = require 'YedPool-Wezurrect'

resurrect.state_manager.change_state_save_dir(
    os.getenv('HOME') .. '/.local/share/resurrect/state/')

-- Keep the rolling .bak of the workspace JSON but disable the dated archive
-- copies: with a 60s periodic save, 10 extra full-workspace JSONs per save
-- site is pure disk amplification for a single-user box.
resurrect.state_manager.backup_retention_count = 0

resurrect.setup(config, {
    keybindings = false,
    claude_hooks = false,
    status_bar = false,
    auto_restore_prompt = false,
    save_workspaces = true,
    -- Only the workspace + per-instance saves are needed: the restore flow
    -- reads instance state, and the named window/tab saves would duplicate
    -- the same scrollback up to ~4x more (the workspace JSON already
    -- contains every window and tab).
    save_windows = false,
    save_tabs = false,
    periodic_interval = 60,
})

-- WezTerm has no window-close event (verified against the pinned rev), so the
-- periodic save above is the crash safety net: a crash loses at most
-- periodic_interval of session structure.
--
-- Restore the most recent saved session on startup, into the default window
-- that wezterm spawns for an empty mux (gui-startup fires before that window
-- exists, so poll briefly for it). The restored instance is tombstoned
-- (parity with the plugin's own restore_instances) and the restored session
-- is immediately re-saved under this boot's instance id, so a crash before
-- the next periodic save cannot regress the on-disk state to the pre-restore
-- snapshot.
local function restore_latest_session()
    local instances = resurrect.instance_manager.list_instances()
    local current = resurrect.instance_manager.instance_id
    local latest = nil
    for _, inst in ipairs(instances) do
        if inst.instance_id ~= current
            and inst.meta and (inst.meta.tab_count or 0) > 0 then
            latest = inst
            break
        end
    end
    if not latest then return end

    local state = resurrect.instance_manager.load_instance(latest.instance_id)
    if not state then return end

    local gui_win = wezterm.gui.gui_windows()[1]
    if not gui_win then return end
    local mux_win = gui_win:mux_window()
    resurrect.workspace_state.restore_workspace(state, {
        window = mux_win,
        pane = mux_win:active_pane(),
        relative = true,
        restore_text = true,
        on_pane_restore = resurrect.tab_state.default_on_pane_restore,
    })

    resurrect.instance_manager.tombstone_instance(latest.instance_id)
    resurrect.state_manager.save_workspace_full()
end

local function wait_for_window_and_restore(attempts)
    if wezterm.gui.gui_windows()[1] then
        -- Grace period so the default pane's shell has initialized before
        -- the restore sends `cd`/process commands into it.
        wezterm.time.call_after(0.5, restore_latest_session)
    elseif attempts > 0 then
        wezterm.time.call_after(0.05, function()
            wait_for_window_and_restore(attempts - 1)
        end)
    end
end

wezterm.on('gui-startup', function()
    -- ~10s budget: the default window appears within milliseconds normally.
    wait_for_window_and_restore(200)
end)

config.font = wezterm.font 'JetBrains Mono'
config.font_size = 12.0
config.font_rules = {
    {
        intensity = 'Bold',
        font = wezterm.font('JetBrains Mono', { weight = 'Regular' }),
    },
}

config.window_background_opacity = 1.0
config.window_padding = {
    left = 3,
    right = 0,
    top = 1,
    bottom = 0,
}

config.default_cursor_style = 'BlinkingBlock'

config.scrollback_lines = 500000

config.tab_bar_at_bottom = true
config.use_fancy_tab_bar = false
config.tab_max_width = 20

wezterm.on('switch-to-left', function(window, pane)
    local tab = window:mux_window():active_tab()

    if tab:get_pane_direction 'Left' ~= nil then
        window:perform_action(wezterm.action.ActivatePaneDirection 'Left', pane)
    else
        window:perform_action(wezterm.action.ActivateTabRelative(-1), pane)
    end
end)

wezterm.on('switch-to-right', function(window, pane)
    local tab = window:mux_window():active_tab()

    if tab:get_pane_direction 'Right' ~= nil then
        window:perform_action(wezterm.action.ActivatePaneDirection 'Right', pane)
    else
        window:perform_action(wezterm.action.ActivateTabRelative(1), pane)
    end
end)

config.keys = {
    {
        key = 'h',
        mods = 'ALT',
        action = wezterm.action.EmitEvent 'switch-to-left',
    },
    {
        key = 'j',
        mods = 'ALT',
        action = wezterm.action.ActivatePaneDirection 'Down',
    },
    {
        key = 'k',
        mods = 'ALT',
        action = wezterm.action.ActivatePaneDirection 'Up',
    },
    {
        key = 'l',
        mods = 'ALT',
        action = wezterm.action.EmitEvent 'switch-to-right',
    },
    {
        key = 'n',
        mods = 'ALT',
        action = wezterm.action.SpawnTab 'CurrentPaneDomain',
    },
    {
        key = 'w',
        mods = 'ALT',
        action = wezterm.action.CloseCurrentPane { confirm = false },
    },
    {
        key = '|',
        mods = 'ALT',
        action = wezterm.action.SplitHorizontal { domain = 'CurrentPaneDomain' },
    },
    {
        key = '-',
        mods = 'ALT',
        action = wezterm.action.SplitVertical { domain = 'CurrentPaneDomain' },
    },
    {
        key = 'z',
        mods = 'ALT',
        action = wezterm.action.TogglePaneZoomState,
    },
    {
        key = 'r',
        mods = 'ALT',
        action = wezterm.action.PromptInputLine {
            description = 'Enter new name for tab',
            action = wezterm.action_callback(function(window, _, line)
                if line then
                    window:active_tab():set_title(line)
                end
            end),
        },
    },
    -- resurrect.wezterm manual save / restore (event + periodic saves are
    -- also always on via resurrect.setup; these are for on-demand use).
    {
        key = 's',
        mods = 'ALT',
        action = wezterm.action_callback(function(win, pane)
            resurrect.state_manager.save_workspace_full()
            wezterm.emit('resurrect.save.finished')
        end),
    },
    {
        key = 'R',
        mods = 'ALT|SHIFT',
        action = wezterm.action_callback(function(win, pane)
            resurrect.instance_manager.show_instance_selector(win, pane, {
                relative = true,
                restore_text = true,
                on_pane_restore = resurrect.tab_state.default_on_pane_restore,
            })
        end),
    },
}

local function tab_title(tab_info)
    local title = tab_info.tab_title
    if title and #title > 0 then
        return title
    end

    return tab_info.active_pane.title
end

wezterm.on('format-tab-title', function(tab, _, _, copy_config, _, _)
    local color_scheme = copy_config.color_scheme
    local color_schemes = copy_config.color_schemes

    local colors = {
        bg_inactive = color_schemes[color_scheme].tab_bar.background,
        fg_inactive = color_schemes[color_scheme].tab_bar.new_tab.fg_color,
        bg_active = color_schemes[color_scheme].ansi[3],
        fg_active = color_schemes[color_scheme].tab_bar.background,
    }

    local title = tab_title(tab)

    return {
        {
            Background = {
                Color = tab.is_active and colors.bg_active
                    or colors.bg_inactive,
            },
        },
        {
            Foreground = {
                Color = tab.is_active and colors.fg_active
                    or colors.fg_inactive,
            },
        },
        { Text = title },
    }
end)

config.color_schemes = {
    ['black'] = {
        foreground = '#E6E6E6',
        background = '#000000',
        cursor_bg = '#E6E6E6',
        cursor_fg = '#000000',
        cursor_border = '#E6E6E6',
        selection_fg = '#000000',
        selection_bg = '#0F2F57',
        scrollbar_thumb = '#333333',
        split = '#333333',
        ansi = {
            '#000000',
            '#FF5555',
            '#55FF55',
            '#FFFF55',
            '#5555FF',
            '#FF55FF',
            '#55FFFF',
            '#E6E6E6',
        },
        brights = {
            '#555555',
            '#FF5555',
            '#55FF55',
            '#FFFF55',
            '#5555FF',
            '#FF55FF',
            '#55FFFF',
            '#FFFFFF',
        },
        tab_bar = {
            background = '#000000',
            active_tab = {
                bg_color = '#000000',
                fg_color = '#E6E6E6',
                intensity = 'Bold',
            },
            inactive_tab = {
                bg_color = '#000000',
                fg_color = '#808080',
            },
            inactive_tab_hover = {
                bg_color = '#1A1A1A',
                fg_color = '#808080',
            },
            new_tab = {
                bg_color = '#000000',
                fg_color = '#555555',
            },
            new_tab_hover = {
                bg_color = '#1A1A1A',
                fg_color = '#808080',
            },
        },
    },
}

config.color_scheme = 'black'

return config
