-- ===========================================================================
--  skills_init.lua — Skills subsystem loader for LLM Connect 1.2.0-dev
--
--  Purpose:
--    Keep skill registration/loading behind one boundary. Skills are not GUI
--    addons anymore; they are agent/runtime capabilities.
-- ===========================================================================

local core = core
local M = {}
local health = rawget(_G, "llm_connect") and _G.llm_connect.health or nil
local function mark_failed(name, err)
    if health and health.mark_failed then health.mark_failed("skills." .. tostring(name), err) end
end


local mod_dir = core.get_modpath(core.get_current_modname())
local SKILLS_DIR = mod_dir .. "/skills"

local function load_required(name, filename)
    local path = SKILLS_DIR .. "/" .. filename
    local ok, module = pcall(dofile, path)
    if not ok then
        local msg = "required skills module failed: " .. name .. " (" .. path .. ") — " .. tostring(module)
        core.log("warning", "[skills_init] " .. msg)
        mark_failed(name, msg)
        module = { skills = {} }
    end
    if module == nil then
        local msg = "required skills module returned nil: " .. name .. " (" .. path .. ")"
        core.log("warning", "[skills_init] " .. msg)
        mark_failed(name, msg)
        module = { skills = {} }
    end
    M[name] = module
    return module
end

local function registry_call(method, fallback, ...)
    local fn = M.registry and M.registry[method]
    if type(fn) ~= "function" then
        core.log("warning", "[skills_init] registry." .. tostring(method) .. " unavailable")
        return fallback
    end
    local ok, result = pcall(fn, ...)
    if not ok then
        core.log("warning", "[skills_init] registry." .. tostring(method) .. " failed: " .. tostring(result))
        return fallback
    end
    if result == nil then return fallback end
    return result
end

M.registry = load_required("registry", "registry.lua")
if type(M.registry.expose_global) == "function" then
    M.registry.expose_global()
end

-- Preserve any skill API tables that may have been installed before this
-- facade is assigned. Internal skills loaded later attach directly to M.
local root = rawget(_G, "llm_connect") or {}
local existing_skill_api = type(root.skills) == "table" and root.skills or nil
if existing_skill_api and existing_skill_api ~= M then
    for k, v in pairs(existing_skill_api) do
        if M[k] == nil then M[k] = v end
    end
end
M.addons = M.addons or M.registry.skills -- old UI wording compatibility only
M.skills = M.skills or M.registry.skills -- registry data view, not the public skill API namespace

function M.load_internal()
    local loaded, info = registry_call("load_internal", 0)
    M.internal_skill_load = info or (M.registry and M.registry.internal_skill_load) or { loaded = loaded or 0, failed = 0, results = {} }
    return loaded or 0, M.internal_skill_load
end

function M.health()
    local info = M.internal_skill_load or (M.registry and M.registry.internal_skill_load) or {}
    return {
        ok = (info.failed or 0) == 0,
        loaded = info.loaded or 0,
        failed = info.failed or 0,
        results = info.results or {},
    }
end

function M.is_available(id)
    if not id then return false end
    return M.registry and M.registry.get_skill and M.registry.get_skill(id) ~= nil or false
end

function M.discover_external()
    return registry_call("discover_external", nil)
end

function M.register_skill(def)
    return registry_call("register_skill", false, def)
end

function M.unregister_skill(id)
    return registry_call("unregister_skill", false, id)
end

function M.get_skill(id)
    return registry_call("get_skill", nil, id)
end

function M.list(player_name, filter)
    return registry_call("list_skills", {}, player_name, filter)
end

function M.get_active(player_name, filter)
    return registry_call("list_skills", {}, player_name, filter)
end

function M.list_active(player_name, filter)
    return M.get_active(player_name, filter)
end

function M.get_loaded()
    return M.registry and M.registry.skills or {}
end

function M.get_status(player_name)
    return registry_call("get_status", {}, player_name)
end

function M.describe_for_agent(player_name, filter)
    return registry_call("describe_for_agent", "", player_name, filter)
end

function M.is_enabled(player_name, id)
    return registry_call("is_addon_enabled", false, player_name, id)
end

function M.set_enabled(player_name, id, enabled)
    return registry_call("set_player_addon", false, player_name, id, enabled)
end

function M.reset_player(player_name)
    return registry_call("reset_player_addons", false, player_name)
end

function M.register_context_provider(id, fn, meta)
    return registry_call("register_context_provider", false, id, fn, meta)
end

function M.get_contexts(player_name, filter)
    return registry_call("get_contexts", {}, player_name, filter)
end

_G.llm_connect = rawget(_G, "llm_connect") or {}
_G.llm_connect.skills = M
_G.llm_connect.skills_subsystem = M
_G.llm_connect.registry = M.registry
_G.llm_connect.addons = M -- deprecated alias: addons == skills facade

_G.registry = M.registry

core.log("action", "[skills_init] skills subsystem loaded")

return M
