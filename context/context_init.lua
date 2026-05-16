-- ===========================================================================
--  context_init.lua — Context subsystem loader for LLM Connect 1.2.0-dev
--
--  Purpose:
--    Present context as a small routed subsystem instead of scattered globals.
--    The public retrieval API remains llm_connect.context.*.
-- ===========================================================================

local core = core
local M = {}
local health = rawget(_G, "llm_connect") and _G.llm_connect.health or nil
local function mark_failed(name, err)
    if health and health.mark_failed then health.mark_failed("context." .. tostring(name), err) end
end


local mod_dir = core.get_modpath(core.get_current_modname())
local CONTEXT_DIR = mod_dir .. "/context"

local function load_required(name, filename)
    local path = CONTEXT_DIR .. "/" .. filename
    local ok, module = pcall(dofile, path)
    if not ok then
        local msg = "required context module failed: " .. name .. " (" .. path .. ") — " .. tostring(module)
        core.log("warning", "[context_init] " .. msg)
        mark_failed(name, msg)
        module = {}
    end
    if module == nil then
        local msg = "required context module returned nil: " .. name .. " (" .. path .. ")"
        core.log("warning", "[context_init] " .. msg)
        mark_failed(name, msg)
        module = {}
    end
    M[name] = module
    return module
end

local function load_optional(name, filename)
    local path = CONTEXT_DIR .. "/" .. filename
    local ok, module = pcall(dofile, path)
    if not ok then
        core.log("warning", "[context_init] optional context module failed: " .. name .. " (" .. path .. ") — " .. tostring(module))
        M[name] = {}
        return M[name]
    end
    if module == nil then
        core.log("warning", "[context_init] optional context module returned nil: " .. name .. " (" .. path .. ")")
        module = {}
    end
    M[name] = module
    return M[name]
end

local function registry_call(method, ...)
    local fn = M.registry and M.registry[method]
    if type(fn) ~= "function" then
        core.log("warning", "[context_init] context_registry." .. tostring(method) .. " unavailable")
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if not ok then
        core.log("warning", "[context_init] context_registry." .. tostring(method) .. " failed: " .. tostring(a))
        mark_failed("registry", a)
        return nil
    end
    return a, b
end

M.basic_context = load_required("basic_context", "basic_context.lua")
M.serializers = load_optional("serializers", "context_serializers.lua")
M.sections = load_optional("sections", "context_sections.lua")
M.discovery = load_optional("discovery", "context_discovery.lua")
M.registry = load_required("registry", "context_registry.lua")

-- Compatibility note:
--   Runtime/GUI code may call:       context.search(player_name, query, opts)
--   Agent-facing prompt examples use: context.search(query, opts)
-- The sandbox normally receives context_registry.make_sandbox_proxy(player),
-- but the public facade stays tolerant so legacy/direct calls do not crash.
local function normalize_context_args(player_name, a, b)
    -- list_sections(opts)
    if type(player_name) == "table" and a == nil then
        return nil, player_name, nil
    end
    return player_name, a, b
end

local function normalize_query_args(player_name, query, opts)
    -- search(query, opts)
    if type(player_name) == "string" and (query == nil or type(query) == "table") then
        return nil, player_name, query
    end
    return player_name, query, opts
end

local function normalize_section_args(player_name, id, args)
    -- get_section(id, args)
    if type(player_name) == "string" and (id == nil or type(id) == "table") then
        return nil, player_name, id
    end
    return player_name, id, args
end

function M.list_sections(player_name, opts)
    player_name, opts = normalize_context_args(player_name, opts)
    return registry_call("list_sections", player_name, opts) or {}
end

function M.search(player_name, query, opts)
    player_name, query, opts = normalize_query_args(player_name, query, opts)
    return registry_call("search", player_name, query, opts) or {}
end

function M.get_section(player_name, id, args)
    player_name, id, args = normalize_section_args(player_name, id, args)
    return registry_call("get_section", player_name, id, args)
end


function M.keys(player_name, opts)
    player_name, opts = normalize_context_args(player_name, opts)
    return registry_call("keys", player_name, opts) or {}
end

function M.has(player_name, key)
    player_name, key = normalize_section_args(player_name, key, nil)
    return registry_call("has", player_name, key) or {}
end

function M.lookup(player_name, key, args)
    player_name, key, args = normalize_section_args(player_name, key, args)
    return registry_call("lookup", player_name, key, args) or {}
end

function M.load(player_name, key, args)
    player_name, key, args = normalize_section_args(player_name, key, args)
    return registry_call("load", player_name, key, args) or {}
end

function M.search_first(player_name, query, opts)
    player_name, query, opts = normalize_query_args(player_name, query, opts)
    return registry_call("search_first", player_name, query, opts) or {}
end

function M.register_section(def)
    return registry_call("register_section", def)
end

function M.unregister_section(id)
    return registry_call("unregister_section", id)
end

local function basic_call(method, player_name)
    local fn = M.basic_context and M.basic_context[method]
    if type(fn) == "function" then
        local ok, result = pcall(fn, player_name)
        if ok then return result or "" end
        core.log("warning", "[context_init] basic_context." .. method .. " failed: " .. tostring(result))
    end
    if method ~= "get" and M.basic_context and type(M.basic_context.get) == "function" then
        local ok, result = pcall(M.basic_context.get, player_name)
        if ok then return result or "" end
        core.log("warning", "[context_init] basic_context.get fallback failed: " .. tostring(result))
    end
    return ""
end

function M.get_chat(player_name)
    return basic_call("get_chat", player_name)
end

function M.get_agent(player_name)
    return basic_call("get_agent", player_name)
end

function M.get_ide(player_name)
    return basic_call("get_ide", player_name)
end

function M.get(player_name, mode)
    if mode == "chat" then return M.get_chat(player_name) end
    if mode == "agent" then return M.get_agent(player_name) end
    if mode == "ide" then return M.get_ide(player_name) end
    return basic_call("get", player_name)
end

_G.llm_connect = rawget(_G, "llm_connect") or {}
_G.llm_connect.basic_context = M.basic_context
_G.llm_connect.context = M
_G.llm_connect.context_registry = M.registry
_G.llm_connect.context_modules = M

_G.basic_context = M.basic_context
_G.context_registry = M.registry

core.log("action", "[context_init] context subsystem loaded")

return M
