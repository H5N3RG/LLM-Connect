-- ===========================================================================
--  agent_system_prompts.lua — LLM Connect v1.2.0-dev
--
--  Tombstone module. agent.lua now builds Lua-first prompts inline and routes
--  execution through parser_utils.lua + core_executor.lua.
-- ===========================================================================

local M = {}

M.version = "1.2.0-dev"
M.protocol = "lua-first"

function M.build_system_prompt()
    return table.concat({
        "You are the LLM-Connect Lua-first agent.",
        "Return only executable Lua code.",
        "Execution is handled by parser_utils.lua and core_executor.lua.",
    }, "\n")
end

function M.build_user_prompt(goal)
    return "Goal:\n" .. tostring(goal or "") .. "\n\nReturn Lua code for the next safe step."
end

core.log("action", "[agent_system_prompts] tombstone loaded; agent.lua owns the Lua-first prompt")

return M
