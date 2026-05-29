-- ===========================================================================
--  execution_policy.lua — LLM Connect 1.2.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Central execution / capability policy.
--
--  Contract:
--    llm        → plain chat UI
--    llm_dev    → Smart Lua IDE as coding assistant; sandboxed execution only
--    llm_agent  → agent mode + Lua-first skills; no IDE access
--    llm_root   → owner privilege; implies all LLM Connect capabilities
-- ===========================================================================

local core = core
local M    = {}

local function raw_priv(name, priv)
    if type(name) ~= "string" or name == "" then return false end
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

function M.raw_priv(name, priv)
    return raw_priv(name, priv)
end

-- llm_root is intentionally sovereign inside LLM Connect and implies all
-- LLM Connect privileges. Raw checks remain available for root-only gates.
function M.has_priv(name, priv)
    if raw_priv(name, "llm_root") then return true end
    return raw_priv(name, priv)
end

function M.is_root(name)
    return raw_priv(name, "llm_root")
end

function M.can_chat(name)
    return M.has_priv(name, "llm")
end

function M.can_ide(name)
    return M.has_priv(name, "llm_dev")
end

function M.can_execute_ide_code(name)
    return M.can_ide(name)
end

function M.can_agent(name)
    return M.has_priv(name, "llm_agent")
end

function M.can_use_agent_skills(name)
    return M.can_agent(name)
end

function M.can_config(name)
    return raw_priv(name, "llm_root")
end

function M.can_execute_unsandboxed(name)
    return M.is_root(name)
end

function M.can_persist_scripts(name)
    return M.is_root(name)
end

function M.can_execute_startup_bound_code(name)
    return M.is_root(name)
end

function M.is_dev_scoped()
    return core.settings:get_bool("llm_ide_whitelist_enabled", true)
end

function M.root_is_unrestricted()
    return core.settings:get_bool("llm_root_agent_unrestricted", false)
end

function M.root_bypasses_safety_filters()
    return core.settings:get_bool("llm_root_bypass_safety_filters", false)
end

function M.root_allows_startup_execution()
    return core.settings:get_bool("llm_root_allow_startup_execution", false)
end

function M.get_capabilities(name)
    local root = M.is_root(name)
    return {
        is_root = root,
        can_chat = root or raw_priv(name, "llm"),
        can_open_ide = root or raw_priv(name, "llm_dev"),
        can_execute_ide_code = root or raw_priv(name, "llm_dev"),
        can_use_agent_skills = root or raw_priv(name, "llm_agent"),
        can_config = root,
        can_execute_unsandboxed = root,
        can_persist_scripts = root,
        can_execute_startup_bound_code = root,
    }
end

local function denied_ctx(profile, purpose)
    return {
        profile = profile or "denied",
        purpose = purpose or "unknown",
        execution_mode = "denied",
        sandbox = true,
        sandbox_enabled = true,
        unrestricted = false,
        can_persist = false,
    }
end

function M.resolve_ide_execution(name, options)
    options = options or {}
    local requested_profile = options.profile or (M.is_root(name) and "llm_root" or "llm_dev")

    if requested_profile == "llm_root" then
        if not M.is_root(name) then return denied_ctx(requested_profile, "ide") end
        return {
            profile = "llm_root",
            purpose = "ide",
            execution_mode = "unrestricted",
            sandbox = false,
            sandbox_enabled = false,
            unrestricted = true,
            can_persist = true,
        }
    end

    if not M.can_execute_ide_code(name) then
        return denied_ctx(requested_profile, "ide")
    end

    return {
        profile = "llm_dev",
        purpose = "ide",
        execution_mode = "sandboxed",
        sandbox = true,
        sandbox_enabled = true,
        unrestricted = false,
        can_persist = false,
    }
end

function M.resolve_agent_execution(name, options)
    options = options or {}

    if not M.can_use_agent_skills(name) then
        return denied_ctx("llm_agent", "agent")
    end

    if M.is_root(name) and M.root_is_unrestricted() then
        return {
            profile = "llm_root",
            purpose = "agent",
            execution_mode = "unrestricted",
            sandbox = false,
            sandbox_enabled = false,
            unrestricted = true,
            can_persist = true,
            bypass_safety_filters = M.root_bypasses_safety_filters(),
            allow_startup_execution = M.root_allows_startup_execution(),
        }
    end

    -- Agent actions are sandboxed by default, including for llm_root unless the
    -- explicit root override above is enabled. Root still has sovereignty, but
    -- it has to opt in through config instead of accidentally de-sandboxing chat.
    return {
        profile = M.is_root(name) and "llm_root" or "llm_agent",
        purpose = "agent",
        execution_mode = "sandboxed",
        sandbox = true,
        sandbox_enabled = true,
        unrestricted = false,
        can_persist = false,
        bypass_safety_filters = false,
        allow_startup_execution = false,
    }
end

function M.resolve_execution(name, purpose, options)
    purpose = purpose or "ide"
    if purpose == "agent" or purpose == "skill" then
        return M.resolve_agent_execution(name, options)
    end
    return M.resolve_ide_execution(name, options)
end

-- Backward-compatible helper used by the IDE status row.
function M.get_execution_mode(name, requested_profile)
    return M.resolve_ide_execution(name, { profile = requested_profile }).execution_mode
end

function M.get_context(name, requested_profile)
    local ctx = M.resolve_ide_execution(name, { profile = requested_profile })
    local caps = M.get_capabilities(name)

    return {
        profile = ctx.profile,
        execution_mode = ctx.execution_mode,
        sandbox = ctx.sandbox,
        sandbox_enabled = ctx.sandbox_enabled,
        unrestricted = ctx.unrestricted,
        can_chat = caps.can_chat,
        can_ide = caps.can_open_ide,
        can_agent = caps.can_use_agent_skills,
        can_config = caps.can_config,
        can_persist = caps.can_persist_scripts,
        can_open_ide = caps.can_open_ide,
        can_execute_ide_code = caps.can_execute_ide_code,
        can_use_agent_skills = caps.can_use_agent_skills,
        can_execute_unsandboxed = caps.can_execute_unsandboxed,
        can_persist_scripts = caps.can_persist_scripts,
        can_execute_startup_bound_code = caps.can_execute_startup_bound_code,
    }
end

return M
