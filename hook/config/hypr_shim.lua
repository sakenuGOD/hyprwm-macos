-- Исполняет дотфайлы Hyprland (Lua-конфиг 0.56) без правок и выгружает объявленное в JSON.
-- usage: lua hypr_shim.lua <dotfiles_home> <out.json>
--   <dotfiles_home> — каталог, внутри которого лежит .config/hypr/hyprland.lua
-- Всё, что конфиг делает в рантайме (exec, dispatch, get_windows…), здесь — заглушки:
-- нам нужно только ЧТО объявлено, а не выполнение команд.

local HOME, OUT = arg[1], arg[2]
assert(HOME and OUT, "usage: lua hypr_shim.lua <dotfiles_home> <out.json>")

local R = { config = {}, curves = {}, animations = {}, binds = {}, monitors = {},
            workspace_rules = {}, window_rules = {}, layer_rules = {}, events = {}, execs = {},
            unknown = {} }

-- глубокое слияние таблиц hl.config(...)
local function merge(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" and #v == 0 then merge(dst[k], v)
        else dst[k] = v end
    end
end

-- hl.dsp.* : любая цепочка/вызов превращается в описание {dsp = "window.move", args = {...}}
local function dsp_node(path)
    return setmetatable({}, {
        __index = function(_, k) return dsp_node(path and (path .. "." .. k) or k) end,
        __call = function(_, ...) return { dsp = path, args = { ... } } end,
    })
end

local function action_repr(a)
    if type(a) == "table" and a.dsp then return a end
    if type(a) == "function" then return { lua = true } end
    return { raw = tostring(a) }
end

hl = {
    config = function(t) merge(R.config, t) end,
    curve = function(name, t) R.curves[name] = t end,
    animation = function(t) R.animations[#R.animations + 1] = t end,
    bind = function(keys, action, opts)
        local o = {}   -- копия: binds.lua переиспользует одну таблицу opts для нескольких биндов
        for k, v in pairs(opts or {}) do o[k] = v end
        R.binds[#R.binds + 1] = { keys = keys, action = action_repr(action), opts = o }
    end,
    monitor = function(t) R.monitors[#R.monitors + 1] = t end,
    workspace_rule = function(t) R.workspace_rules[#R.workspace_rules + 1] = t end,
    window_rule = function(t) R.window_rules[#R.window_rules + 1] = t end,
    layer_rule = function(t) R.layer_rules[#R.layer_rules + 1] = t end,
    on = function(ev, _) R.events[#R.events + 1] = ev end,
    exec_cmd = function(cmd) R.execs[#R.execs + 1] = cmd end,
    exec_once = function(cmd) R.execs[#R.execs + 1] = cmd end,
    dispatch = function() end,
    dsp = dsp_node(nil),
    get_windows = function() return {} end,
    get_workspace_windows = function() return {} end,
    get_active_window = function() return nil end,
    get_active_workspace = function() return { id = 1 } end,
    get_monitors = function() return {} end,
}
-- незнакомые функции hl.* не роняют конфиг, а записываются
setmetatable(hl, { __index = function(_, k)
    R.unknown[#R.unknown + 1] = k
    return function() end
end })

-- HOME конфига = каталог дотфайлов (на маке ~/.config/hypr нет)
local real_getenv = os.getenv
os.getenv = function(k) if k == "HOME" then return HOME end return real_getenv(k) end
package.path = HOME .. "/.config/hypr/?.lua;" .. package.path

local ok, err = pcall(dofile, HOME .. "/.config/hypr/hyprland.lua")
R.load_ok, R.load_error = ok, ok and nil or tostring(err)

-- минимальный JSON-энкодер
local function enc(v, ind)
    ind = ind or ""
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" or t == "number" then return tostring(v) end
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            return ({ ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\t'] = '\\t' })[c]
                or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if t == "function" then return '"<lua function>"' end
    if t == "table" then
        local n = #v
        local is_arr = n > 0 or next(v) == nil
        if is_arr and next(v) ~= nil then
            for k in pairs(v) do if type(k) ~= "number" then is_arr = false break end end
        end
        local parts, nind = {}, ind .. " "
        if is_arr then
            for i = 1, n do parts[#parts + 1] = nind .. enc(v[i], nind) end
            return #parts == 0 and "[]" or "[\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = nind .. enc(tostring(k)) .. ": " .. enc(v[k], nind)
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. ind .. "}"
    end
    return '"<' .. t .. '>"'
end

local f = assert(io.open(OUT, "w"))
f:write(enc(R)); f:close()
print(string.format("hypr_shim: load_ok=%s curves=%d animations=%d binds=%d monitors=%d%s",
    tostring(ok), (function() local c = 0 for _ in pairs(R.curves) do c = c + 1 end return c end)(),
    #R.animations, #R.binds, #R.monitors, ok and "" or (" ОШИБКА: " .. tostring(err))))
