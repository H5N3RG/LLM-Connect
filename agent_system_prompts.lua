-- ===========================================================================
--  agent_system_prompts.lua — LLM Connect v1.1.0-dev
--
--  Tombstone module. The 1.0.0-dev JSON tool-call prompt builder was removed.
--  agent.lua now builds Lua-first prompts inline and routes all execution through
--  parser_utils.lua + core_executor.lua.
-- ===========================================================================

local M = {}

M.version = "1.1.0-dev"
M.protocol = "lua-first"

function M.build_system_prompt()
    return table.concat({
        "You are the LLM-Connect Lua-first agent.",
        "Return only executable Lua code.",
        "Do not return JSON tool calls.",
        "Execution is handled by parser_utils.lua and core_executor.lua.",
    }, "\n")
end

function M.build_user_prompt(goal)
    return "Goal:\n" .. tostring(goal or "") .. "\n\nReturn Lua code for the next safe step."
end

core.log("action", "[agent_system_prompts] legacy JSON prompt builder removed; Lua-first tombstone loaded")

return M
