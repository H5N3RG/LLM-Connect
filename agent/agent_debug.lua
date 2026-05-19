-- ===========================================================================
--  agent_debug.lua — raw prompt tracing and root-only live trace stream
-- ===========================================================================

local core = core
local M = {}

-- ---------------------------------------------------------------------------
-- Raw prompt/response file trace
-- ---------------------------------------------------------------------------

local prompt_trace = {}

prompt_trace.user_log_name = "llm_user_prompt_log.txt"
prompt_trace.response_log_name = "llm_response_prompt_log.txt"

local function prompt_trace_enabled()
    return core.settings:get_bool("llm_trace_prompt_log", false)
end

local function ts()
    if os and os.date then return os.date("!%Y-%m-%dT%H:%M:%SZ") end
    return tostring(core.get_gametime and core.get_gametime() or "unknown-time")
end

local function world_file(name)
    return core.get_worldpath() .. "/" .. name
end

local function stringify(value)
    if type(value) == "string" then return value end
    local ok, json = pcall(core.write_json, value, true)
    if ok and json then return json end
    return tostring(value)
end

local function append_file(path, text)
    if not io or not io.open then return false, "io.open unavailable" end
    local f, err = io.open(path, "a")
    if not f then return false, err end
    f:write(text)
    f:close()
    return true
end

local function write_prompt_trace(kind, filename, meta, payload)
    if not prompt_trace_enabled() then return true end
    local lines = {
        "\n==================== LLM CONNECT TRACE ====================\n",
        "time_utc: ", ts(), "\n",
        "kind: ", tostring(kind), "\n",
    }
    for k, v in pairs(meta or {}) do
        lines[#lines + 1] = tostring(k)
        lines[#lines + 1] = ": "
        lines[#lines + 1] = tostring(v)
        lines[#lines + 1] = "\n"
    end
    lines[#lines + 1] = "-------------------- PAYLOAD BEGIN --------------------\n"
    lines[#lines + 1] = stringify(payload)
    lines[#lines + 1] = "\n--------------------- PAYLOAD END ---------------------\n"

    local ok, err = append_file(world_file(filename), table.concat(lines))
    if not ok then
        core.log("warning", "[prompt_trace] failed to write " .. tostring(filename) .. ": " .. tostring(err))
    end
    return ok, err
end

function prompt_trace.enabled()
    return prompt_trace_enabled()
end

function prompt_trace.log_request(meta, body_table, body_raw)
    if not prompt_trace_enabled() then return true end
    return write_prompt_trace("request", prompt_trace.user_log_name, meta, {
        body_table = body_table,
        raw_json = body_raw,
        note = "Authorization header is intentionally not logged; request body and prompt messages are complete.",
    })
end

function prompt_trace.log_response(meta, result, parsed)
    if not prompt_trace_enabled() then return true end
    return write_prompt_trace("response", prompt_trace.response_log_name, meta, {
        fetch_result = result,
        parsed_json = parsed,
    })
end

function prompt_trace.log_error_response(meta, err)
    if not prompt_trace_enabled() then return true end
    return write_prompt_trace("response_error", prompt_trace.response_log_name, meta, err)
end

-- ---------------------------------------------------------------------------
-- Root-only in-game live trace stream
-- ---------------------------------------------------------------------------

local live_trace = {}

live_trace.version = "1.2.0-dev"
live_trace.max_line_len = 220
live_trace.max_buffer = 300
live_trace.categories = {
    prompt = true,
    request = true,
    response = true,
    parser = true,
    flow = true,
    middleware = true,
    executor = true,
    runtime = true,
    skills = true,
    retry = true,
    context = true,
    lua = true,
    trace = true,
}
live_trace.buffer = live_trace.buffer or {}

local function setting_bool(key, default)
    return core.settings:get_bool(key, default == true)
end

function live_trace.enabled()
    return setting_bool("llm_live_trace_chat", false)
end

function live_trace.raw_lua_enabled()
    return setting_bool("llm_live_trace_show_lua", false)
end

function live_trace.verbosity()
    return tostring(core.settings:get("llm_live_trace_verbosity") or "normal")
end

local function verbosity_allows(category)
    local v = live_trace.verbosity()
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
    local v = live_trace.verbosity()
    if v == "quiet" then return 140 end
    if v == "verbose" then return 600 end
    return live_trace.max_line_len
end

local function category_enabled(category)
    category = tostring(category or "trace"):lower()
    if not live_trace.categories[category] then return false end
    local raw = core.settings:get("llm_live_trace_categories") or ""
    if raw == "" or raw == "*" or raw == "all" then return true end
    for item in raw:gmatch("[^,%s]+") do
        local selected = item:lower()
        if selected == "all" or selected == "*" or selected == category then return true end
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
    max_len = max_len or live_trace.max_line_len
    if #text > max_len then return text:sub(1, max_len - 3) .. "..." end
    return text
end

local function timestamp()
    return os.date("%H:%M:%S")
end

local function push_buffer(entry)
    live_trace.buffer[#live_trace.buffer + 1] = entry
    while #live_trace.buffer > live_trace.max_buffer do
        table.remove(live_trace.buffer, 1)
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

function live_trace.emit(category, player_name, message, data)
    if not live_trace.enabled() then return false end
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

function live_trace.emit_lua(player_name, code)
    if not live_trace.enabled() or not live_trace.raw_lua_enabled() then return false end
    return live_trace.emit("lua", player_name, code)
end

function live_trace.clear()
    live_trace.buffer = {}
    return true
end

function live_trace.get_entries()
    local out = {}
    for i, entry in ipairs(live_trace.buffer or {}) do out[i] = entry end
    return out
end

function live_trace.format_buffer()
    local lines = {}
    for _, e in ipairs(live_trace.buffer or {}) do
        local line = string.format("%s [%s] %s", tostring(e.time), tostring(e.category):upper(), tostring(e.message))
        if e.data and e.data ~= "" then line = line .. " | " .. e.data end
        lines[#lines + 1] = line
    end
    if #lines == 0 then return "No live trace entries." end
    return table.concat(lines, "\n")
end

function live_trace.show_formspec(player_name)
    if not has_root(player_name) then return false end
    local fs = {
        "formspec_version[6]",
        "size[16,12]",
        "bgcolor[#0f0f0f;both]",
        "style_type[*;bgcolor=#1a1a1a;textcolor=#e0e0e0;font=mono]",
        "label[0.35,0.35;LLM Connect Live Trace]",
        "button[12.1,0.2;1.6,0.55;llm_trace_refresh;Refresh]",
        "button[13.9,0.2;1.6,0.55;llm_trace_clear;Clear]",
        "textarea[0.35,0.95;15.3,10.55;llm_trace_buffer;;" .. core.formspec_escape(live_trace.format_buffer()) .. "]",
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
        live_trace.clear()
        live_trace.show_formspec(name)
        return true
    elseif fields.llm_trace_refresh then
        live_trace.show_formspec(name)
        return true
    end
    return true
end)

M.prompt_trace = prompt_trace
M.live_trace = live_trace

core.log("action", "[agent_debug] loaded — prompt trace and live trace ready")

return M
