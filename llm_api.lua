-- llm_api.lua
-- Central LLM API interface for LLM-Connect (v0.8+)

local core = core
local M = {}

-- Internal states
M.http = nil
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
    timeout             = 120,    -- global fallback
    timeout_chat        = 0,      -- 0 = use global
    timeout_ide         = 0,
    timeout_we          = 0,
    language            = "en",
    language_repeat     = 1,
    -- context
    context_max_history = 20,
    -- ide
    ide_naming_guide        = true,
    ide_include_run_output  = true,
    ide_context_mod_list    = true,
    ide_max_code_context    = 300,
    -- worldedit
    we_max_iterations       = 6,
    we_snapshot             = true,
}

local language_instruction_cache = nil

-- ============================================================
-- Initialization
-- ============================================================

function M.init(http_api)
    if not http_api then
        core.log("error", "[llm_api] No HTTP API provided")
        return false
    end
    M.http = http_api

    -- Load settings once
    M.reload_config()
    return true
end

-- ============================================================
-- Configuration loading / updating
-- ============================================================

function M.reload_config()
    -- Read exact keys from settingtypes.txt
    M.config.api_key    = core.settings:get("llm_api_key")    or ""
    M.config.api_url    = core.settings:get("llm_api_url")    or ""
    M.config.model      = core.settings:get("llm_model")      or ""

    M.config.max_tokens = tonumber(core.settings:get("llm_max_tokens")) or 4000
    M.config.max_tokens_integer = core.settings:get_bool("llm_max_tokens_integer", true)

    M.config.temperature       = tonumber(core.settings:get("llm_temperature")) or 0.7
    M.config.top_p             = tonumber(core.settings:get("llm_top_p")) or 0.9
    M.config.presence_penalty  = tonumber(core.settings:get("llm_presence_penalty")) or 0.0
    M.config.frequency_penalty = tonumber(core.settings:get("llm_frequency_penalty")) or 0.0

    M.config.timeout          = tonumber(core.settings:get("llm_timeout")) or 120
    M.config.timeout_chat     = tonumber(core.settings:get("llm_timeout_chat")) or 0
    M.config.timeout_ide      = tonumber(core.settings:get("llm_timeout_ide"))  or 0
    M.config.timeout_we       = tonumber(core.settings:get("llm_timeout_we"))   or 0

    M.config.language         = core.settings:get("llm_language") or "en"
    M.config.language_repeat  = tonumber(core.settings:get("llm_language_instruction_repeat")) or 1

    M.config.context_max_history = tonumber(core.settings:get("llm_context_max_history")) or 20

    M.config.ide_naming_guide        = core.settings:get_bool("llm_ide_naming_guide", true)
    M.config.ide_include_run_output  = core.settings:get_bool("llm_ide_include_run_output", true)
    M.config.ide_context_mod_list    = core.settings:get_bool("llm_ide_context_mod_list", true)
    M.config.ide_max_code_context    = tonumber(core.settings:get("llm_ide_max_code_context")) or 300

    M.config.we_max_iterations = tonumber(core.settings:get("llm_we_max_iterations")) or 6
    M.config.we_snapshot       = core.settings:get_bool("llm_we_snapshot_before_exec", true)

    -- Invalidate cache
    language_instruction_cache = nil

end

-- Returns the effective timeout for a given mode ("chat", "ide", "we").
-- Uses per-mode override if > 0, otherwise falls back to global llm_timeout.
function M.get_timeout(mode)
    local override = 0
    if mode == "chat" then override = M.config.timeout_chat
    elseif mode == "ide"  then override = M.config.timeout_ide
    elseif mode == "we"   then override = M.config.timeout_we
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
    return M.config.api_key ~= "" and
           M.config.api_url ~= "" and
           M.config.model  ~= ""
end

-- ============================================================
-- Language instruction (cached)
-- ============================================================

local function get_language_instruction()
    if language_instruction_cache then
        return language_instruction_cache
    end

    local lang = M.config.language
    local repeat_count = math.max(0, M.config.language_repeat or 1)

    if lang == "en" or repeat_count == 0 then
        language_instruction_cache = ""
        return ""
    end

    local lang_name = "English"
    local lang_mod_path = core.get_modpath("llm_connect") .. "/ide_languages.lua"
    local ok, lang_mod = pcall(dofile, lang_mod_path)
    if ok and lang_mod and lang_mod.get_language_name then
        lang_name = lang_mod.get_language_name(lang) or lang_name
    end

    local instr = "Important: Answer exclusively in " .. lang_name .. "!\n" ..
                  "All explanations, code, comments, output and any text you generate must be in " .. lang_name .. "."

    local parts = {}
    for _ = 1, repeat_count do
        table.insert(parts, instr)
    end

    language_instruction_cache = table.concat(parts, "\n\n") .. "\n\n"
    return language_instruction_cache
end

-- ============================================================
-- Request Function
-- ============================================================

function M.request(messages, callback, options)
    if not M.is_configured() then
        callback({ success = false, error = "LLM API not configured (Check API Key/URL/Model)" })
        return
    end

    options = options or {}
    local cfg = M.config

    local lang_instr = get_language_instruction()
    if lang_instr ~= "" and (not messages[1] or messages[1].role ~= "system") then
        table.insert(messages, 1, { role = "system", content = lang_instr })
    end

    local body_table = {
        model               = options.model or cfg.model,
        messages            = messages,
        max_tokens          = options.max_tokens or cfg.max_tokens,
        temperature         = options.temperature or cfg.temperature,
        top_p               = options.top_p or cfg.top_p,
        presence_penalty    = options.presence_penalty or cfg.presence_penalty,
        frequency_penalty   = options.frequency_penalty or cfg.frequency_penalty,
        stream              = options.stream == true,
    }

    if options.tools then
        body_table.tools = options.tools
        body_table.tool_choice = options.tool_choice or "auto"
    end

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

    if core.settings:get_bool("llm_debug") then
        core.log("action", "[llm_api] Requesting " .. cfg.model .. " at " .. cfg.api_url)
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
                -- Proxy-level errors (Envoy overflow, connection reset, etc.)
                local raw = tostring(result.error)
                if raw:find("overflow") or raw:find("reset") or raw:find("upstream") then
                    err = "Proxy/upstream error (possibly Mistral overload or rate limit). Retry in a moment."
                else
                    err = raw
                end
            end
            callback({ success = false, error = err, code = result.code })
            return
        end

        -- Handle non-JSON responses (proxy errors often return plain text)
        local raw_data = tostring(result.data or "")
        if raw_data:find("upstream connect error") or raw_data:find("reset reason") then
            callback({ success = false, error = "Proxy/upstream error: " .. raw_data:sub(1, 80) .. " – possibly Mistral overload, retry in a moment." })
            return
        end

        local response = core.parse_json(result.data)
        if not response or type(response) ~= "table" then
            local raw_preview = raw_data:sub(1, 120)
            callback({ success = false, error = "Invalid JSON response: " .. raw_preview })
            return
        end

        if response.error then
            callback({
                success = false,
                error = response.error.message or "API error",
                error_type = response.error.type,
                code = response.error.code
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
            success     = content ~= nil,
            content     = content,
            raw         = response,
            finish_reason = response.choices and response.choices[1] and response.choices[1].finish_reason,
            usage       = response.usage,
        }

        if response.choices and response.choices[1] and response.choices[1].message.tool_calls then
            ret.tool_calls = response.choices[1].message.tool_calls
        end

        if core.settings:get_bool("llm_debug") then
            core.log("action", "[llm_api DEBUG] Raw response: " .. tostring(result.data or "no data"))
            core.log("action", "[llm_api DEBUG] Parsed: " .. core.write_json(response or {}, true))
        end

        callback(ret)
    end)
end

-- ============================================================
-- Helper Wrappers
-- ============================================================

function M.chat(messages, callback, options)
    M.request(messages, callback, options)
end

function M.ask(system_prompt, user_message, callback, options)
    local messages = {
        { role = "system", content = system_prompt },
        { role = "user",   content = user_message },
    }
    M.request(messages, callback, options)
end

function M.code(system_prompt, code_block, callback, options)
    local user_msg = "```lua\n" .. code_block .. "\n```"
    M.ask(system_prompt, user_msg, callback, options)
end

return M
