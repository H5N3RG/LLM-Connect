-- ===========================================================================
--  agent_init.lua — loader for the 1.2 agent middleware modules
-- ===========================================================================

local core = core
local M = {}
local health = rawget(_G, "llm_connect") and _G.llm_connect.health or nil
local function mark_failed(name, err)
    if health and health.mark_failed then health.mark_failed("agent." .. tostring(name), err) end
end


local mod_dir = core.get_modpath(core.get_current_modname())
local AGENT_DIR = mod_dir .. "/agent"

local files = {
    agent_state = "agent_state.lua",
    agent_capabilities = "agent_capabilities.lua",
    agent_context_cache = "agent_context_cache.lua",
    agent_result = "agent_result.lua",
    agent_retry = "agent_retry.lua",
    agent_middleware = "agent_middleware.lua",
    agent_prompt_builder = "agent_prompt_builder.lua",
}

local function load_one(name, filename)
    local path = AGENT_DIR .. "/" .. filename
    local ok, module = pcall(dofile, path)
    if not ok then
        local msg = "required agent module failed: " .. name .. " (" .. path .. ") — " .. tostring(module)
        core.log("warning", "[agent_init] " .. msg)
        mark_failed(name, msg)
        module = {}
    end
    if module == nil then
        local msg = "required agent module returned nil: " .. name .. " (" .. path .. ")"
        core.log("warning", "[agent_init] " .. msg)
        mark_failed(name, msg)
        module = {}
    end
    M[name] = module
    _G.llm_connect = rawget(_G, "llm_connect") or {}
    _G.llm_connect[name] = module
    return module
end

-- Load in deterministic order; pairs() would make debugging load-order issues
-- needlessly annoying.
local ordered = {
    "agent_state",
    "agent_capabilities",
    "agent_context_cache",
    "agent_result",
    "agent_retry",
    "agent_middleware",
    "agent_prompt_builder",
}

for _, name in ipairs(ordered) do
    load_one(name, files[name])
end

_G.llm_connect.agent_modules = M

core.log("action", "[agent_init] agent middleware modules loaded")

return M
