-- ===========================================================================
--  subsystem_health.lua — LLM Connect 1.2.0-dev subsystem health/fallback layer
--
--  Purpose:
--    Keep subsystem failures observable without turning every missing module
--    into an immediate nil-crash. This is not a permission system; it is only
--    bootstrap diagnostics and safe-call plumbing.
-- ===========================================================================

local core = core
local root = rawget(_G, "llm_connect") or {}
_G.llm_connect = root

local H = root.health or {}
H.status = H.status or {}
H.events = H.events or {}

local function now()
    if core and core.get_us_time then
        return tostring(core.get_us_time())
    end
    return tostring(os.time())
end

local function stringify(x)
    if x == nil then return "nil" end
    return tostring(x)
end

function H.mark_ok(name, meta)
    H.status[name] = {
        ok = true,
        degraded = false,
        message = meta and meta.message or "ok",
        path = meta and meta.path or nil,
        time = now(),
    }
    table.insert(H.events, { subsystem = name, ok = true, message = H.status[name].message, time = H.status[name].time })
    return true
end

function H.mark_failed(name, err, meta)
    H.status[name] = {
        ok = false,
        degraded = true,
        message = stringify(err),
        path = meta and meta.path or nil,
        fatal = meta and meta.fatal == true or false,
        time = now(),
    }
    table.insert(H.events, { subsystem = name, ok = false, message = H.status[name].message, time = H.status[name].time })
    if core and core.log then
        core.log((meta and meta.fatal) and "error" or "warning",
            "[llm_connect.health] " .. tostring(name) .. " degraded: " .. H.status[name].message)
    end
    return false
end

function H.mark_degraded(name, msg, meta)
    return H.mark_failed(name, msg or "degraded", meta)
end

function H.is_ok(name)
    local s = H.status[name]
    return s and s.ok == true
end

function H.get(name)
    return H.status[name]
end

function H.report_lines()
    local lines = {}
    local names = {}
    for name in pairs(H.status) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local s = H.status[name]
        local prefix = s.ok and "ok" or "degraded"
        table.insert(lines, name .. ": " .. prefix .. " — " .. tostring(s.message or ""))
    end
    return lines
end

function H.report_text()
    local lines = H.report_lines()
    if #lines == 0 then return "no subsystem health data" end
    return table.concat(lines, "\n")
end

function H.safe_call(label, fn, fallback, ...)
    if type(fn) ~= "function" then
        H.mark_degraded(label or "unknown", "safe_call target is not a function")
        return fallback
    end
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then
        H.mark_degraded(label or "unknown", a)
        return fallback
    end
    return a, b, c, d
end

function H.unavailable_result(subsystem, action, err)
    local msg = "subsystem unavailable: " .. tostring(subsystem)
    if action then msg = msg .. "." .. tostring(action) end
    if err then msg = msg .. " — " .. tostring(err) end
    return { ok = false, success = false, degraded = true, subsystem = subsystem, action = action, message = msg, error = msg }
end

root.health = H
root.safe_call = function(label, fn, fallback, ...)
    return H.safe_call(label, fn, fallback, ...)
end

return H
