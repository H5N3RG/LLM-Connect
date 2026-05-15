-- ===========================================================================
--  prompt_trace.lua — optional raw LLM traffic logger
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Writes complete request/response payloads to world-local trace files when
--  llm_trace_prompt_log is enabled. This is intentionally raw and verbose for
--  debugging prompt leaks, mode contamination, and provider errors.
-- ===========================================================================

local core = core
local M = {}

M.user_log_name = "llm_user_prompt_log.txt"
M.response_log_name = "llm_response_prompt_log.txt"

local function enabled()
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

local function write(kind, filename, meta, payload)
    if not enabled() then return true end
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

function M.enabled()
    return enabled()
end

function M.log_request(meta, body_table, body_raw)
    if not enabled() then return true end
    return write("request", M.user_log_name, meta, {
        body_table = body_table,
        raw_json = body_raw,
        note = "Authorization header is intentionally not logged; request body and prompt messages are complete.",
    })
end

function M.log_response(meta, result, parsed)
    if not enabled() then return true end
    return write("response", M.response_log_name, meta, {
        fetch_result = result,
        parsed_json = parsed,
    })
end

function M.log_error_response(meta, err)
    if not enabled() then return true end
    return write("response_error", M.response_log_name, meta, err)
end

core.log("action", "[prompt_trace] module loaded — raw LLM traffic logging available")

return M
