-- ===========================================================================
--  api_init.lua — Provider/API subsystem loader for LLM Connect 1.2.0-dev
--
--  Purpose:
--    Keep provider-facing modules behind one API boundary so init.lua and
--    frontends do not need to know individual provider file names.
-- ===========================================================================

local core = core
local M = {}
local health = rawget(_G, "llm_connect") and _G.llm_connect.health or nil

local function mark_failed(name, err)
    if health and health.mark_failed then health.mark_failed("api." .. tostring(name), err) end
end


local mod_dir = core.get_modpath(core.get_current_modname())
local API_DIR = mod_dir .. "/api"

local function log_warn(msg)
    core.log("warning", "[api_init] " .. msg)
end

local function load_required(name, filename)
    local path = API_DIR .. "/" .. filename
    local ok, module = pcall(dofile, path)
    if not ok then
        local msg = "required API module failed: " .. name .. " (" .. path .. ") — " .. tostring(module)
        log_warn(msg)
        mark_failed(name, msg)
        module = {}
    end
    if module == nil then
        local msg = "required API module returned nil: " .. name .. " (" .. path .. ")"
        log_warn(msg)
        mark_failed(name, msg)
        module = {}
    end
    M[name] = module
    return module
end

local function load_optional(name, filename)
    local path = API_DIR .. "/" .. filename
    local ok, module = pcall(dofile, path)
    if not ok then
        log_warn("optional API module failed: " .. name .. " (" .. path .. ") — " .. tostring(module))
        M[name] = {}
        return M[name]
    end
    if module == nil then
        log_warn("optional API module returned nil: " .. name .. " (" .. path .. ")")
        module = {}
    end
    M[name] = module
    return module
end

local function call_api(method, ...)
    local fn = M.llm_api and M.llm_api[method]
    if type(fn) ~= "function" then
        local msg = "llm_api." .. tostring(method) .. " unavailable"
        log_warn(msg)
        mark_failed("llm_api", msg)
        return false, msg
    end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        log_warn("llm_api." .. tostring(method) .. " failed: " .. tostring(a))
        mark_failed("llm_api", a)
        return false, tostring(a)
    end
    return a, b, c
end

M.llm_api = load_required("llm_api", "llm_api.lua")
if type(M.llm_api.init) ~= "function" then
    M.llm_api.init = function() return false end
end
M.provider_capabilities = load_optional("provider_capabilities", "provider_capabilities.lua")
M.providers = {
    openai  = load_optional("provider_openai", "provider_openai.lua"),
    ollama  = load_optional("provider_ollama", "provider_ollama.lua"),
    localai = load_optional("provider_localai", "provider_localai.lua"),
    mistral = load_optional("provider_mistral", "provider_mistral.lua"),
}

-- Stable subsystem facade.
-- Other subsystems should prefer llm_connect.api.* over direct llm_api.* calls.
local function callback_failure(callback, err)
    if type(callback) == "function" then
        callback({ success = false, ok = false, error = tostring(err), message = tostring(err) })
    end
    return false, tostring(err)
end

function M.request(messages, callback, options)
    local ok, err = call_api("request", messages, callback, options)
    if ok == false then return callback_failure(callback, err) end
    return ok, err
end

function M.chat(messages, callback, options)
    local ok, err = call_api("chat", messages, callback, options)
    if ok == false then return callback_failure(callback, err) end
    return ok, err
end

function M.ask(system_prompt, user_message, callback, options)
    local ok, err = call_api("ask", system_prompt, user_message, callback, options)
    if ok == false then return callback_failure(callback, err) end
    return ok, err
end

function M.code(system_prompt, code_block, callback, options)
    local ok, err = call_api("code", system_prompt, code_block, callback, options)
    if ok == false then return callback_failure(callback, err) end
    return ok, err
end

function M.reload_config()
    return call_api("reload_config")
end

function M.set_config(updates)
    return call_api("set_config", updates)
end

function M.is_configured()
    local fn = M.llm_api and M.llm_api.is_configured
    if type(fn) ~= "function" then return false end
    return fn()
end

function M.get_timeout(mode)
    local fn = M.llm_api and M.llm_api.get_timeout
    if type(fn) == "function" then return fn(mode) end
    return tonumber(core.settings:get("llm_timeout_" .. tostring(mode or "chat"))) or tonumber(core.settings:get("llm_timeout")) or 60
end

function M.get_config()
    return (M.llm_api and M.llm_api.config) or {}
end

function M.get_provider()
    if M.llm_api and type(M.llm_api.get_provider) == "function" then
        return M.llm_api.get_provider()
    end
    return (M.llm_api and M.llm_api.config and M.llm_api.config.api_url) or nil
end

_G.llm_connect = rawget(_G, "llm_connect") or {}
_G.llm_connect.api = M
_G.llm_connect.llm_api = M.llm_api
_G.llm_connect.provider_capabilities = M.provider_capabilities
_G.llm_connect.providers = M.providers

core.log("action", "[api_init] API/provider subsystem loaded")

return M
