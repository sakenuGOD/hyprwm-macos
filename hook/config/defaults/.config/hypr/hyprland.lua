-- Portable HyprWM baseline. runtime.json provides validated local overrides.
-- SUPER = Option, CTRL = Control, ALT = Command on macOS.
hl.config {
    general = {
        layout = "dwindle", gaps_in = 5,
        gaps_out = { top = 8, right = 12, bottom = 12, left = 12 }, border_size = 2,
        col = { active_border = { colors = { "rgba(ffb4a4ee)", "rgba(7fd0f5ee)" }, angle = 45 },
                inactive_border = "rgba(53434155)" },
    },
    decoration = {
        rounding = 18, rounding_power = 2.6, active_opacity = 1.0, inactive_opacity = 1.0,
        shadow = { enabled = true, range = 34, render_power = 3, offset = {0, 10},
                   color = "rgba(00000077)", color_inactive = "rgba(00000044)" },
        glow = { enabled = true, range = 18, render_power = 3,
                 color = "rgba(ffb4a433)", color_inactive = "rgba(ffb4a400)" },
    },
    dwindle = { preserve_split = true, force_split = 0, smart_split = false,
                default_split_ratio = 1.0, split_width_multiplier = 1.0 },
    input = { follow_mouse = 1, repeat_rate = 40, repeat_delay = 280 },
    cursor = { no_warps = true },
    binds = { workspace_back_and_forth = true, allow_workspace_cycles = true },
    animations = { enabled = true },
}
hl.curve("smooth", { type = "bezier", points = {{0.25, 1.0}, {0.5, 1.0}} })
hl.curve("snappy", { type = "bezier", points = {{0.2, 0.9}, {0.1, 1.0}} })
hl.curve("overshot", { type = "bezier", points = {{0.05, 0.9}, {0.1, 1.06}} })
hl.curve("drift", { type = "spring", mass = 1, stiffness = 210, damping = 24 })
hl.curve("bounce", { type = "spring", mass = 1, stiffness = 260, damping = 20 })
for _, a in ipairs {
    { leaf = "global", enabled = true, speed = 8, bezier = "smooth" },
    { leaf = "windowsMove", enabled = true, speed = 5, spring = "drift" },
    { leaf = "windowsIn", enabled = true, speed = 4.5, spring = "bounce", style = "popin 86%" },
    { leaf = "windowsOut", enabled = true, speed = 2.6, bezier = "snappy", style = "popin 92%" },
    { leaf = "fadeIn", enabled = true, speed = 3, bezier = "smooth" },
    { leaf = "fadeOut", enabled = true, speed = 2.4, bezier = "smooth" },
    { leaf = "fadeSwitch", enabled = true, speed = 4, bezier = "smooth" },
    { leaf = "border", enabled = true, speed = 6, bezier = "smooth" },
} do hl.animation(a) end

local function bind(keys, action, desc, opts)
    opts = opts or {}; opts.description = "[OmniWM] " .. desc
    hl.bind(keys, action, opts)
end
for key, direction in pairs { left = "left", right = "right", up = "up", down = "down" } do
    bind("CTRL + SUPER + " .. key, hl.dsp.focus { direction = direction }, "Фокус: " .. direction)
    bind("CTRL + SUPER + SHIFT + " .. key, hl.dsp.window.move { direction = direction }, "Перенос: " .. direction)
end
bind("CTRL + SUPER + Return", hl.dsp.layout("togglesplit"), "Изменить направление деления")
bind("CTRL + SUPER + F", hl.dsp.window.float { action = "toggle" }, "Плавающее окно")
bind("SUPER + F", hl.dsp.window.fullscreen { mode = "fullscreen" }, "Полный экран")
bind("SUPER + SHIFT + Return", hl.dsp.window.fullscreen { mode = "maximized" }, "Развернуть в рабочей области")
bind("SUPER + Q", hl.dsp.window.close {}, "Закрыть окно")
-- Native keys use the descriptions; the actions also work in the Lua runtime.
bind("SUPER + W", function()
    hl.dispatch(hl.dsp.window.move { workspace = "special:hidden", follow = false })
end, "Скрыть окно")
bind("SUPER + SHIFT + W", function()
    local parked = hl.get_windows { workspace = "special:hidden" }
    local window = parked[#parked]
    if window then
        hl.dispatch(hl.dsp.window.move { window = "address:" .. window.address,
            workspace = hl.get_active_workspace().id, follow = true })
        hl.dispatch(hl.dsp.focus { window = "address:" .. window.address })
    end
end, "Вернуть скрытое")
bind("SUPER + SHIFT + B", function()
    local active = hl.get_active_window()
    for _, window in ipairs(hl.get_workspace_windows(hl.get_active_workspace().id)) do
        if not window.floating then
            hl.dispatch(hl.dsp.focus { window = "address:" .. window.address })
            hl.dispatch(hl.dsp.layout("splitratio 1 exact"))
        end
    end
    if active then hl.dispatch(hl.dsp.focus { window = "address:" .. active.address }) end
end, "Равные пропорции")
for i = 1, 10 do
    local key = i == 10 and "0" or tostring(i)
    bind("SUPER + " .. key, hl.dsp.focus { workspace = i }, "Стол " .. i)
    bind("CTRL + SUPER + " .. key, hl.dsp.window.move { workspace = i, follow = true }, "Перенести на стол " .. i)
end
