-- ===========================================================================
--  execution_policy.lua — LLM Connect 1.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Central execution / capability policy.
--  Purpose: keep root/dev semantics in one place without changing behavior.
--
--  Philosophy:
--    llm_root → unconditional sovereignty / unrestricted execution
--    llm_dev  → IDE authority, but sandboxed when server policy enforces it
--
-- ===========================================================================

local core = core
local M    = {}

local function raw_priv(name, priv)
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

function M.raw_priv(name, priv)
    return raw_priv(name, priv)
end

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

function M.can_agent(name)
    return M.has_priv(name, "llm_agent")
end

function M.can_config(name)
    return raw_priv(name, "llm_root")
end

function M.is_dev_scoped()
    return core.settings:get_bool("llm_ide_whitelist_enabled", true)
end

function M.root_is_unrestricted()
    return true
end

-- Current behavior intentionally stays conservative:
-- llm_dev runs sandboxed; llm_root runs unrestricted.
-- The llm_ide_whitelist_enabled setting remains the policy anchor for later
-- widening/narrowing of dev scope, but does not change runtime behavior yet.
function M.get_execution_mode(name, requested_profile)
    requested_profile = requested_profile or (M.is_root(name) and "llm_root" or "llm_dev")

    if requested_profile == "llm_root" and M.is_root(name) then
        return "unrestricted"
    end

    if requested_profile == "llm_dev" and M.can_ide(name) then
        return "sandboxed"
    end

    return "denied"
end

function M.get_context(name, requested_profile)
    local mode = M.get_execution_mode(name, requested_profile)
    local profile = requested_profile or (M.is_root(name) and "llm_root" or "llm_dev")
    local unrestricted = (mode == "unrestricted")

    return {
        profile = profile,
        execution_mode = mode,
        sandbox_enabled = (mode == "sandboxed"),
        unrestricted = unrestricted,
        can_chat = M.can_chat(name),
        can_ide = M.can_ide(name),
        can_agent = M.can_agent(name),
        can_config = M.can_config(name),
        can_persist = unrestricted,
    }
end

function M.resolve_ide_execution(name, options)
    options = options or {}
    local requested_profile = options.profile or (M.is_root(name) and "llm_root" or "llm_dev")
    local mode = M.get_execution_mode(name, requested_profile)

    local use_sandbox = options.sandbox ~= false
    if mode == "unrestricted" then
        use_sandbox = false
    elseif mode == "sandboxed" then
        use_sandbox = true
    end

    return {
        profile = requested_profile,
        execution_mode = mode,
        sandbox = use_sandbox,
        unrestricted = (mode == "unrestricted"),
        can_persist = (mode == "unrestricted"),
    }
end

return M
