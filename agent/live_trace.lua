-- ===========================================================================
--  live_trace.lua — root-only in-game live trace stream for LLM Connect
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Emits compact trace lines directly into the Luanti chat log while enabled.
--  This complements raw prompt_trace files and is designed for live debugging
--  of prompt construction, provider calls, executor prechecks, runtime errors,
--  skill dispatch, and retry loops.
-- ===========================================================================

local core = core
local M = {}

M.version = "1.2.0-dev"
M.max_line_len = 220
M.max_buffer = 300
M.categories = {
    prompt = true,
    request = true,
    response = true,
    parser = true,
    middleware = true,
    executor = true,
    runtime = true,
    skills = true,
    retry = true,
    context = true,
    lua = true,
    trace = true,
}
M.buffer = M.buffer or {}

local function setting_bool(key, default)
    return core.settings:get_bool(key, default == true)
end

function M.enabled()
    return setting_bool("llm_live_trace_chat", false)
end

function M.raw_lua_enabled()
    return setting_bool("llm_live_trace_show_lua", false)
end

function M.verbosity()
    return tostring(core.settings:get("llm_live_trace_verbosity") or "normal")
end

local function verbosity_allows(category)
    local v = M.verbosity()
    if v == "verbose" then return true end
    if v == "quiet" then
        return category == "runtime"
            or category == "executor"
            or category == "retry"
            or category == "skills"
            or category == "trace"
    end
    return true
end

local function line_limit()
    local v = M.verbosity()
    if v == "quiet" then return 140 end
    if v == "verbose" then return 600 end
    return M.max_line_len
end

local function category_enabled(category)
    category = tostring(category or "trace"):lower()
    if not M.categories[category] then return false end
    local raw = core.settings:get("llm_live_trace_categories") or ""
    if raw == "" or raw == "*" or raw == "all" then return true end
    for item in raw:gmatch("[^,%s]+") do
        item = item:lower()
        if item == "all" or item == "*" or item == category then return true end
    end
    return false
end

local function has_root(name)
    if not name or name == "" then return false end
    local policy = _G.llm_connect and _G.llm_connect.policy
    if policy and policy.is_root then
        local ok, res = pcall(policy.is_root, name)
        if ok then return res == true end
    end
    local privs = core.get_player_privs(name) or {}
    return privs.llm_root == true
end

local function compact(text, max_len)
    text = tostring(text or "")
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("\n+", " ⏎ "):gsub("%s+", " ")
    max_len = max_len or M.max_line_len
    if #text > max_len then return text:sub(1, max_len - 3) .. "..." end
    return text
end

local function timestamp()
    return os.date("%H:%M:%S")
end

local function push_buffer(entry)
    M.buffer[#M.buffer + 1] = entry
    while #M.buffer > M.max_buffer do
        table.remove(M.buffer, 1)
    end
end

local function serialize_data(data)
    if data == nil then return "" end
    if type(data) == "string" then return compact(data) end
    local ok, encoded = pcall(core.write_json, data, false)
    if ok and encoded then return compact(encoded) end
    return compact(tostring(data))
end

local function recipients(preferred)
    local seen, out = {}, {}
    local function add(name)
        if name and name ~= "" and not seen[name] and has_root(name) then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    add(preferred)
    for _, player in ipairs(core.get_connected_players() or {}) do
        add(player:get_player_name())
    end
    return out
end

function M.emit(category, player_name, message, data)
    if not M.enabled() then return false end
    category = tostring(category or "trace"):lower()
    if not category_enabled(category) then return false end
    if not verbosity_allows(category) then return false end

    local max_len = line_limit()
    local entry = {
        time = timestamp(),
        category = category,
        player = player_name,
        message = compact(message or "", max_len),
        data = serialize_data(data),
    }
    push_buffer(entry)

    local label = category:upper()
    local line = core.colorize("#8888ff", "[LLM TRACE:" .. label .. "] ")
        .. compact(message or "", max_len)
    local extra = entry.data
    if extra ~= "" then
        line = line .. core.colorize("#777777", " | " .. extra)
    end
    for _, name in ipairs(recipients(player_name)) do
        core.chat_send_player(name, line)
    end
    return true
end

function M.emit_lua(player_name, code)
    if not M.enabled() or not M.raw_lua_enabled() then return false end
    return M.emit("lua", player_name, code)
end

function M.clear()
    M.buffer = {}
    return true
end

function M.get_entries()
    local out = {}
    for i, entry in ipairs(M.buffer or {}) do out[i] = entry end
    return out
end

function M.format_buffer()
    local lines = {}
    for _, e in ipairs(M.buffer or {}) do
        local line = string.format("%s [%s] %s", tostring(e.time), tostring(e.category):upper(), tostring(e.message))
        if e.data and e.data ~= "" then line = line .. " | " .. e.data end
        lines[#lines + 1] = line
    end
    if #lines == 0 then return "No live trace entries." end
    return table.concat(lines, "\n")
end

function M.show_formspec(player_name)
    if not has_root(player_name) then return false end
    local fs = {
        "formspec_version[6]",
        "size[16,12]",
        "bgcolor[#0f0f0f;both]",
        "style_type[*;bgcolor=#1a1a1a;textcolor=#e0e0e0;font=mono]",
        "label[0.35,0.35;LLM Connect Live Trace]",
        "button[12.1,0.2;1.6,0.55;llm_trace_refresh;Refresh]",
        "button[13.9,0.2;1.6,0.55;llm_trace_clear;Clear]",
        "textarea[0.35,0.95;15.3,10.55;llm_trace_buffer;;" .. core.formspec_escape(M.format_buffer()) .. "]",
        "button_exit[6.8,11.45;2.4,0.45;llm_trace_close;Close]",
    }
    core.show_formspec(player_name, "llm_connect:live_trace", table.concat(fs))
    return true
end

core.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "llm_connect:live_trace" or not player then return false end
    local name = player:get_player_name()
    if not has_root(name) then return true end
    if fields.llm_trace_clear then
        M.clear()
        M.show_formspec(name)
        return true
    elseif fields.llm_trace_refresh then
        M.show_formspec(name)
        return true
    end
    return true
end)

core.log("action", "[live_trace] module loaded — in-game root trace stream available")

return M
