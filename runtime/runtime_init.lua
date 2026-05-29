-- ===========================================================================
--  runtime_init.lua — Runtime subsystem loader for LLM Connect 1.2.0-dev
--
--  Purpose:
--    Make execution policy, path policy, IDE storage and core executor a single
--    runtime boundary used by GUI, agent and future API frontends.
-- ===========================================================================

local core = core
local M = {}
local health = rawget(_G, "llm_connect") and _G.llm_connect.health or nil
local function mark_failed(name, err)
    if health and health.mark_failed then health.mark_failed("runtime." .. tostring(name), err) end
end


local mod_dir = core.get_modpath(core.get_current_modname())
local RUNTIME_DIR = mod_dir .. "/runtime"

local function load_required(name, path)
    local ok, module = pcall(dofile, path)
    if not ok then
        local msg = "required runtime module failed: " .. name .. " (" .. path .. ") — " .. tostring(module)
        core.log("warning", "[runtime_init] " .. msg)
        mark_failed(name, msg)
        module = {}
    end
    if module == nil then
        local msg = "required runtime module returned nil: " .. name .. " (" .. path .. ")"
        core.log("warning", "[runtime_init] " .. msg)
        mark_failed(name, msg)
        module = {}
    end
    M[name] = module
    return module
end

local function load_optional(name, path)
    local ok, module = pcall(dofile, path)
    if not ok then
        core.log("warning", "[runtime_init] optional runtime module failed: " .. name .. " (" .. path .. ") — " .. tostring(module))
        M[name] = {}
        return M[name]
    end
    if module == nil then
        core.log("warning", "[runtime_init] optional runtime module returned nil: " .. name .. " (" .. path .. ")")
        module = {}
    end
    M[name] = module
    return module
end

local function executor_call(method, fallback, ...)
    local fn = M.core_executor and M.core_executor[method]
    if type(fn) ~= "function" then
        core.log("warning", "[runtime_init] core_executor." .. tostring(method) .. " unavailable")
        return fallback
    end
    local ok, result = pcall(fn, ...)
    if not ok then
        core.log("warning", "[runtime_init] core_executor." .. tostring(method) .. " failed: " .. tostring(result))
        if type(fallback) == "table" then
            fallback.message = fallback.message or tostring(result)
            fallback.error = fallback.error or tostring(result)
        end
        return fallback
    end
    if result == nil then return fallback end
    return result
end

M.execution_policy = load_required("execution_policy", RUNTIME_DIR .. "/execution_policy.lua")
M.path_policy = load_required("path_policy", RUNTIME_DIR .. "/path_policy.lua")
M.code_classifier = load_required("code_classifier", RUNTIME_DIR .. "/code_classifier.lua")
M.ide_storage = load_required("ide_storage", RUNTIME_DIR .. "/ide_storage.lua")
M.core_executor = load_required("core_executor", RUNTIME_DIR .. "/core_executor.lua")

local function normalize_request(player_name_or_request, code, options)
    if type(player_name_or_request) == "table" then
        local req = player_name_or_request
        local opts = req.options or {}
        for k, v in pairs(req) do
            if opts[k] == nil and k ~= "code" and k ~= "payload" then opts[k] = v end
        end
        return req.actor or req.player_name or req.name, req.code or req.payload or code, opts
    end
    return player_name_or_request, code, options or {}
end

local function failure(msg)
    return { ok = false, success = false, message = msg, error = msg }
end

-- Stable runtime facade.
-- Privileges remain in execution_policy/path_policy; this namespace is only
-- the routed entrypoint for GUI, agent, skills and future API frontends.
function M.precheck(player_name_or_request, code, options)
    local player_name, payload, opts = normalize_request(player_name_or_request, code, options)
    return executor_call("precheck", failure("core_executor.precheck unavailable"), payload, player_name, opts)
end

function M.execute(player_name_or_request, code, options)
    local player_name, payload, opts = normalize_request(player_name_or_request, code, options)
    return executor_call("execute", failure("core_executor.execute unavailable"), player_name, payload, opts)
end

function M.execute_llm_response(player_name_or_request, response_text, options)
    local player_name, payload, opts = normalize_request(player_name_or_request, response_text, options)
    return executor_call("execute_llm_response", failure("core_executor.execute_llm_response unavailable"), player_name, payload, opts)
end

function M.execute_with_retry(player_name_or_request, code, options)
    local player_name, payload, opts = normalize_request(player_name_or_request, code, options)
    return executor_call("execute_with_retry", failure("core_executor.execute_with_retry unavailable"), player_name, payload, opts)
end

local function policy_call(method, fallback, ...)
    local fn = M.execution_policy and M.execution_policy[method]
    if type(fn) ~= "function" then return fallback end
    local ok, result = pcall(fn, ...)
    if ok then return result end
    core.log("warning", "[runtime_init] execution_policy." .. tostring(method) .. " failed: " .. tostring(result))
    return fallback
end

function M.check_policy(player_name, capability, options)
    options = options or {}
    if capability == "chat" then return policy_call("can_chat", false, player_name) end
    if capability == "ide" then return policy_call("can_ide", false, player_name) end
    if capability == "agent" then return policy_call("can_agent", false, player_name) end
    if capability == "config" then return policy_call("can_config", false, player_name) end
    if capability == "unsandboxed" then return policy_call("can_execute_unsandboxed", false, player_name) end
    if capability == "persist_scripts" then return policy_call("can_persist_scripts", false, player_name) end
    if options.priv then return policy_call("has_priv", false, player_name, options.priv) end
    return false
end

function M.resolve_execution(player_name, purpose, options)
    return policy_call("resolve_execution", { allowed = false, reason = "execution_policy.resolve_execution unavailable" }, player_name, purpose, options)
end

function M.get_capabilities(player_name)
    return policy_call("get_capabilities", {}, player_name)
end

_G.llm_connect = rawget(_G, "llm_connect") or {}
_G.llm_connect.runtime = M
_G.llm_connect.policy = M.execution_policy
_G.llm_connect.path_policy = M.path_policy
_G.llm_connect.code_classifier = M.code_classifier
_G.llm_connect.ide_storage = M.ide_storage
_G.llm_connect.core_executor = M.core_executor

-- Legacy global aliases kept for older GUI/IDE/debug snippets.
_G.execution_policy = M.execution_policy
_G.path_policy = M.path_policy
_G.code_classifier = M.code_classifier
_G.ide_storage = M.ide_storage
_G.core_executor = M.core_executor

core.log("action", "[runtime_init] runtime subsystem loaded")

return M
