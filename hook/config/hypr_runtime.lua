-- Живой рантайм дотфайлов Hyprland для hyprwm: hyprland.lua + nebula/*.lua исполняются КАК ЕСТЬ,
-- бинды-функции (hide_window, restore_window, quit_app, balance …) вызываются по нажатию.
-- Всё, что функции спрашивают/делают через hl.*, уходит демону (hook/hyprwm.py) по stdin/stdout:
--   демон -> рантайм:  {"op":"call","i":N}          (номер бинда из @@BINDS)
--   рантайм -> демон:  @@RPC {"op":"dispatch"|"get_windows"|…, "args":[…]}  -> одна строка-ответ JSON
--   рантайм -> демон:  @@DONE {"ok":true}            (бинд отработал)
-- usage: lua hypr_runtime.lua <dotfiles_home>
local HOME = assert(arg[1], "usage: lua hypr_runtime.lua <dotfiles_home>")

-- ── JSON (одной строкой) ───────────────────────────────────────────────
local function enc(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return math.type(v) == "integer" and tostring(v) or string.format("%.17g", v)
    end
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            return ({ ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\t'] = '\\t' })[c]
                or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if t == "table" then
        if getmetatable(v) and getmetatable(v).__dsp then return enc({ dsp = getmetatable(v).__dsp }) end
        local n, is_arr = #v, true
        for k in pairs(v) do if type(k) ~= "number" then is_arr = false break end end
        local parts = {}
        if is_arr then
            for i = 1, n do parts[#parts + 1] = enc(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for k, x in pairs(v) do
            if type(x) ~= "function" then parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(x) end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"   -- функции и прочее демону не передаём
end

local function dec(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local val
    local function str()
        local out, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == '"' then i = j + 1 return table.concat(out) end
            if c == "\\" then
                local e = s:sub(j + 1, j + 1)
                if e == "u" then
                    local cp = tonumber(s:sub(j + 2, j + 5), 16)
                    if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j + 6, j + 7) == "\\u" then
                        local lo = tonumber(s:sub(j + 8, j + 11), 16)
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00); j = j + 6
                    end
                    out[#out + 1] = utf8.char(cp); j = j + 6
                else
                    out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[e] or e; j = j + 2
                end
            else out[#out + 1] = c; j = j + 1 end
        end
    end
    function val()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local o = {}; i = i + 1; ws()
            if s:sub(i, i) == "}" then i = i + 1 return o end
            while true do
                ws(); local k = str(); ws(); i = i + 1   -- ':'
                o[k] = val(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "}" then return o end
            end
        elseif c == "[" then
            local a = {}; i = i + 1; ws()
            if s:sub(i, i) == "]" then i = i + 1 return a end
            while true do
                a[#a + 1] = val(); ws()
                local d = s:sub(i, i); i = i + 1
                if d == "]" then return a end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
        else
            local num = s:match("^-?[%d.eE+-]+", i); i = i + #num
            return math.tointeger(tonumber(num)) or tonumber(num)
        end
    end
    return val()
end

local function rpc(op, args)
    io.write("@@RPC " .. enc({ op = op, args = args }) .. "\n"); io.flush()
    local line = io.read("l")
    if not line then os.exit(0) end
    return dec(line)
end

-- ── hl ─────────────────────────────────────────────────────────────────
local BINDS = {}

-- hl.dsp.window.move({...}) -> {dsp="window.move", args={...}} — как в Hyprland, действие-значение
local function dsp_node(path)
    return setmetatable({}, {
        __dsp = path,
        __index = function(_, k) return dsp_node(path and (path .. "." .. k) or k) end,
        __call = function(_, ...) return { dsp = path, args = { ... } } end,
    })
end

hl = {
    bind = function(keys, action, opts)
        local o = {}   -- копия: binds.lua переиспользует одну таблицу opts (R) для нескольких биндов
        for k, v in pairs(opts or {}) do o[k] = v end
        BINDS[#BINDS + 1] = { keys = keys, action = action, opts = o }
    end,
    dsp = dsp_node(nil),
    dispatch = function(d) return rpc("dispatch", { d }) end,
    exec_cmd = function(cmd) return rpc("exec", { cmd }) end,
    get_windows = function(filter) return rpc("get_windows", { filter }) or {} end,
    get_workspace_windows = function(id) return rpc("get_workspace_windows", { id }) or {} end,
    get_active_window = function() return rpc("get_active_window", {}) end,
    get_active_workspace = function() return rpc("get_active_workspace", {}) end,
    get_workspace = function(id) return rpc("get_workspace", { id }) end,
    get_active_monitor = function() return rpc("get_active_monitor", {}) end,
    get_monitors = function() return rpc("get_monitors", {}) or {} end,
    -- объявления конфига: значения демон берёт из hypr_cfg.json (hypr_shim.lua), здесь не нужны
    config = function() end, curve = function() end, animation = function() end,
    monitor = function() end, workspace_rule = function() end, window_rule = function() end,
    layer_rule = function() end, env = function() end, exec_once = function() end,
    on = function() end,        -- события Linux-сессии (autostart, мониторы) на маке не шлём
    timer = function() return { set_enabled = function() end } end,
}
setmetatable(hl, { __index = function() return function() end end })

local real_getenv = os.getenv
os.getenv = function(k) if k == "HOME" then return HOME end return real_getenv(k) end
package.path = HOME .. "/.config/hypr/?.lua;" .. package.path

local ok, err = pcall(dofile, HOME .. "/.config/hypr/hyprland.lua")
if not ok then io.stderr:write("hypr_runtime: конфиг не загрузился: " .. tostring(err) .. "\n") end

local list = {}
for i, b in ipairs(BINDS) do
    local a = b.action
    list[i] = { i = i, keys = b.keys, desc = b.opts.description or "", mouse = b.opts.mouse and true or false,
                kind = type(a) == "function" and "lua" or "dsp",
                action = type(a) == "table" and a or nil }
end
io.write("@@BINDS " .. enc(list) .. "\n"); io.flush()

for line in io.lines() do
    local req = dec(line)
    local res = { ok = true }
    if req and req.op == "call" then
        local b = BINDS[req.i]
        if not b then res = { ok = false, error = "нет бинда " .. tostring(req.i) }
        else
            local okc, e = pcall(function()
                if type(b.action) == "function" then b.action() else hl.dispatch(b.action) end
            end)
            if not okc then res = { ok = false, error = tostring(e) } end
        end
    end
    io.write("@@DONE " .. enc(res) .. "\n"); io.flush()
end
