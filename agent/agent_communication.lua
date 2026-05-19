-- ===========================================================================
--  agent_communication.lua — guarded access to external agent subsystems
-- ===========================================================================

local M = {}

function M.get_root()
    return rawget(_G, "llm_connect")
end

function M.safe_call(fn, ...)
    if type(fn) ~= "function" then return false, nil end
    return pcall(fn, ...)
end

function M.get_skills()
    local root = M.get_root()
    return type(root) == "table" and (root.skills or root.skills_subsystem or root.registry) or rawget(_G, "registry")
end

function M.get_api()
    local root = M.get_root()
    return type(root) == "table" and (root.api or root.llm_api) or rawget(_G, "llm_api")
end

function M.get_basic_context()
    local root = M.get_root()
    return type(root) == "table" and (root.context_modules or root.context or root.basic_context) or rawget(_G, "basic_context")
end

function M.get_provider()
    local api = M.get_api()
    if api and type(api.get_provider) == "function" then
        local ok, provider = pcall(api.get_provider)
        if ok then return provider end
    end
    return nil
end

function M.get_skill_status(player_name)
    local skills = M.get_skills()
    if not skills then return nil end
    local ok, status = M.safe_call(skills.get_status, player_name)
    if ok and type(status) == "table" then return status end
    return nil
end

function M.describe_skills_for_agent(player_name, skill_filter)
    local skills = M.get_skills()
    if not skills or type(skills.describe_for_agent) ~= "function" then return "" end
    local ok, text = pcall(skills.describe_for_agent, player_name, skill_filter)
    if ok and text and text ~= "" then return tostring(text) end
    return ""
end

function M.get_agent_context(player_name)
    local context = M.get_basic_context()
    if not context then return "" end

    local fn = context.get_agent or context.get
    if type(fn) == "function" then
        local ok, ctx = pcall(fn, player_name, "agent")
        if ok and ctx and ctx ~= "" then return tostring(ctx) end
        if not ok and core and core.log then core.log("warning", "[agent_communication] context failed: " .. tostring(ctx)) end
    end
    return ""
end

core.log("action", "[agent_communication] loaded — external agent subsystem access ready")

return M
