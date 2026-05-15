-- ===========================================================================
--  llm_api.lua — LLM Connect 1.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Central HTTP interface for OpenAI-compatible LLM APIs.
--  Ported from 0.9.0, adapted for 1.0 architecture:
--    - timeout_we  → timeout_agent  (new slot for the agent loop)
--    - WE-specific config keys removed (we_max_iterations, we_snapshot)
--    - IDE config keys remain (smart_lua_ide is a first-class sub-system)
--    - get_timeout("agent") instead of get_timeout("we")
--    - Everything else carried over 1:1 from 0.9.0
--
--  PUBLIC API:
--    M.init(http_api)              → bool
--    M.reload_config()             → void
--    M.set_config(updates)         → void
--    M.is_configured()             → bool
--    M.get_timeout(mode)           → number   mode: "chat"|"ide"|"agent"
--    M.request(messages, cb, opts) → void     (async)
--    M.chat(messages, cb, opts)    → void
--    M.ask(system, user, cb, opts) → void
--    M.code(system, code, cb, opts)→ void
--
-- ===========================================================================

local core = core
local M = {}

-- ===========================================================================
-- Config state
-- ===========================================================================

M.http   = nil
M.config = {
    api_key             = "",
    api_url             = "",
    model               = "",
    max_tokens          = 4000,
    max_tokens_integer  = true,
    temperature         = 0.7,
    top_p               = 0.9,
    presence_penalty    = 0.0,
    frequency_penalty   = 0.0,
    timeout             = 120,   -- global fallback
    timeout_chat        = 0,     -- 0 = use global
    timeout_ide         = 0,
    timeout_agent       = 0,     -- 1.0: was timeout_we in 0.9
    language            = "en",
    language_repeat     = 1,
    -- chat
    context_max_history = 20,
    -- ide (smart_lua_ide is a first-class sub-system — keys stay here)
    ide_naming_guide        = true,
    ide_include_run_output  = true,
    ide_context_mod_list    = true,
    ide_max_code_context    = 300,
}

local language_instruction_cache = nil

-- ===========================================================================
-- Initialization
-- ===========================================================================

function M.init(http_api)
    if not http_api then
        core.log("error", "[llm_api] no HTTP API provided")
        return false
    end
    M.http = http_api
    M.reload_config()
    return true
end

-- ===========================================================================
-- Configuration
-- ===========================================================================

function M.reload_config()
    M.config.api_key = core.settings:get("llm_api_key") or ""
    M.config.api_url = core.settings:get("llm_api_url") or ""
    M.config.model   = core.settings:get("llm_model")   or ""

    M.config.max_tokens         = tonumber(core.settings:get("llm_max_tokens")) or 4000
    M.config.max_tokens_integer = core.settings:get_bool("llm_max_tokens_integer", true)

    M.config.temperature       = tonumber(core.settings:get("llm_temperature"))       or 0.7
    M.config.top_p             = tonumber(core.settings:get("llm_top_p"))             or 0.9
    M.config.presence_penalty  = tonumber(core.settings:get("llm_presence_penalty"))  or 0.0
    M.config.frequency_penalty = tonumber(core.settings:get("llm_frequency_penalty")) or 0.0

    M.config.timeout       = tonumber(core.settings:get("llm_timeout"))       or 120
    M.config.timeout_chat  = tonumber(core.settings:get("llm_timeout_chat"))  or 0
    M.config.timeout_ide   = tonumber(core.settings:get("llm_timeout_ide"))   or 0
    M.config.timeout_agent = tonumber(core.settings:get("llm_timeout_agent")) or 0

    M.config.language        = core.settings:get("llm_language") or "en"
    M.config.language_repeat = tonumber(core.settings:get("llm_language_instruction_repeat")) or 1

    M.config.context_max_history = tonumber(core.settings:get("llm_context_max_history")) or 20

    M.config.ide_naming_guide       = core.settings:get_bool("llm_ide_naming_guide",       true)
    M.config.ide_include_run_output = core.settings:get_bool("llm_ide_include_run_output", true)
    M.config.ide_context_mod_list   = core.settings:get_bool("llm_ide_context_mod_list",   true)
    M.config.ide_max_code_context   = tonumber(core.settings:get("llm_ide_max_code_context")) or 300

    language_instruction_cache = nil
end

-- Returns the effective timeout for a given mode.
-- mode: "chat" | "ide" | "agent"
-- Uses the per-mode override if > 0, otherwise falls back to the global timeout.
function M.get_timeout(mode)
    local override = 0
    if     mode == "chat"  then override = M.config.timeout_chat
    elseif mode == "ide"   then override = M.config.timeout_ide
    elseif mode == "agent" then override = M.config.timeout_agent
    end
    if override and override > 0 then return override end
    return M.config.timeout
end

function M.set_config(updates)
    for k, v in pairs(updates) do
        if M.config[k] ~= nil then
            M.config[k] = v
        end
    end
    language_instruction_cache = nil
end

function M.is_configured()
    return M.config.api_key ~= ""
       and M.config.api_url ~= ""
       and M.config.model   ~= ""
end

-- ===========================================================================
-- Language instruction (cached)
-- ===========================================================================

local function get_language_instruction()
    if language_instruction_cache then
        return language_instruction_cache
    end

    local lang         = M.config.language
    local repeat_count = math.max(0, M.config.language_repeat or 1)

    if lang == "en" or repeat_count == 0 then
        language_instruction_cache = ""
        return ""
    end

    local lang_name = "English"
    local lang_path = core.get_modpath("llm_connect") .. "/gui/ide_languages.lua"
    local ok, lang_mod = pcall(dofile, lang_path)
    if ok and lang_mod and lang_mod.get_language_name then
        lang_name = lang_mod.get_language_name(lang) or lang_name
    end

    local instr = "Important: Answer exclusively in " .. lang_name .. "!\n"
               .. "All explanations, code, comments, output and any text you generate must be in "
               .. lang_name .. "."

    local parts = {}
    for _ = 1, repeat_count do
        table.insert(parts, instr)
    end
    language_instruction_cache = table.concat(parts, "\n\n") .. "\n\n"
    return language_instruction_cache
end

-- ===========================================================================
-- Request
-- ===========================================================================

function M.request(messages, callback, options)
    if not M.is_configured() then
        callback({ success = false, error = "LLM API not configured (Check API Key/URL/Model)" })
        return
    end

    options = options or {}
    local cfg = M.config

    -- Prepend language instruction as system message if no system prompt is present
    local lang_instr = get_language_instruction()
    if lang_instr ~= "" and (not messages[1] or messages[1].role ~= "system") then
        table.insert(messages, 1, { role = "system", content = lang_instr })
    end

    local body_table = {
        model             = options.model       or cfg.model,
        messages          = messages,
        max_tokens        = options.max_tokens  or cfg.max_tokens,
        temperature       = options.temperature or cfg.temperature,
        top_p             = options.top_p       or cfg.top_p,
        presence_penalty  = options.presence_penalty  or cfg.presence_penalty,
        frequency_penalty = options.frequency_penalty or cfg.frequency_penalty,
        stream            = options.stream == true,
    }

    local max_t = body_table.max_tokens
    if cfg.max_tokens_integer then
        body_table.max_tokens = math.floor(max_t)
    else
        body_table.max_tokens = tonumber(max_t)
    end

    local body = core.write_json(body_table)

    if cfg.max_tokens_integer then
        body = body:gsub('"max_tokens"%s*:%s*(%d+)%.0', '"max_tokens": %1')
    end

    local trace = rawget(_G, "llm_connect") and _G.llm_connect.prompt_trace or rawget(_G, "prompt_trace")
    local trace_meta = {
        mode = tostring(options.mode or "unknown"),
        model = tostring(body_table.model or ""),
        api_url = tostring(cfg.api_url or ""),
        message_count = tostring(type(messages) == "table" and #messages or 0),
        stream = tostring(body_table.stream == true),
        timeout = tostring(options.timeout or cfg.timeout),
    }
    if trace and trace.log_request then
        pcall(trace.log_request, trace_meta, body_table, body)
    end

    if core.settings:get_bool("llm_debug") then
        core.log("action", "[llm_api] Request → " .. cfg.model .. " @ " .. cfg.api_url)
    end

    M.http.fetch({
        url     = cfg.api_url,
        method  = "POST",
        data    = body,
        timeout = options.timeout or cfg.timeout,
        extra_headers = {
            "Content-Type: application/json",
            "Authorization: Bearer " .. cfg.api_key,
        },
    }, function(result)
        if not result.succeeded then
            local err = "HTTP request failed"
            if result.timeout then
                err = "Request timed out (limit: " .. tostring(options.timeout or cfg.timeout) .. "s)"
            elseif result.code then
                err = "HTTP " .. tostring(result.code)
            elseif result.error then
                local raw = tostring(result.error)
                if raw:find("overflow") or raw:find("reset") or raw:find("upstream") then
                    err = "Proxy/upstream error (possibly overload or rate limit). Retry in a moment."
                else
                    err = raw
                end
            end
            if trace and trace.log_error_response then
                pcall(trace.log_error_response, trace_meta, {
                    succeeded = result.succeeded,
                    timeout = result.timeout,
                    code = result.code,
                    error = result.error,
                    data = result.data,
                    normalized_error = err,
                })
            end
            callback({ success = false, error = err, code = result.code })
            return
        end

        local raw_data = tostring(result.data or "")
        if raw_data:find("upstream connect error") or raw_data:find("reset reason") then
            callback({ success = false,
                error = "Proxy/upstream error: " .. raw_data:sub(1, 80) .. " — retry in a moment." })
            return
        end

        local response = core.parse_json(result.data)
        if trace and trace.log_response then
            pcall(trace.log_response, trace_meta, {
                succeeded = result.succeeded,
                timeout = result.timeout,
                code = result.code,
                error = result.error,
                data = raw_data,
            }, response)
        end
        if not response or type(response) ~= "table" then
            callback({ success = false,
                error = "Invalid JSON response: " .. raw_data:sub(1, 120) })
            return
        end

        if response.error then
            callback({
                success    = false,
                error      = response.error.message or "API error",
                error_type = response.error.type,
                code       = response.error.code,
            })
            return
        end

        local content = nil
        if response.choices and response.choices[1] then
            content = response.choices[1].message.content
        elseif response.message and response.message.content then
            content = response.message.content
        end

        local ret = {
            success       = content ~= nil,
            content       = content,
            raw           = response,
            finish_reason = response.choices
                            and response.choices[1]
                            and response.choices[1].finish_reason,
            usage         = response.usage,
        }

        if core.settings:get_bool("llm_debug") then
            core.log("action", "[llm_api DEBUG] Raw: " .. tostring(result.data or "no data"))
            core.log("action", "[llm_api DEBUG] Parsed: " .. core.write_json(response or {}, true))
        end

        callback(ret)
    end)
end

-- ===========================================================================
-- Convenience Wrappers
-- ===========================================================================

function M.chat(messages, callback, options)
    M.request(messages, callback, options)
end

function M.ask(system_prompt, user_message, callback, options)
    M.request({
        { role = "system", content = system_prompt },
        { role = "user",   content = user_message  },
    }, callback, options)
end

function M.code(system_prompt, code_block, callback, options)
    M.ask(system_prompt, "```lua\n" .. code_block .. "\n```", callback, options)
end

-- ===========================================================================

core.log("action", "[llm_api] module loaded")

return M
