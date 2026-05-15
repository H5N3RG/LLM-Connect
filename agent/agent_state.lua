-- ===========================================================================
--  agent_state.lua — task-local state for LLM-Connect agent runs
-- ===========================================================================

local M = {}

local states = {}

local function default_state()
    return {
        running = false,
        cancelled = false,
        iteration = 0,
        max_iterations = 1,
        message = "",
        visible_parts = {},
        action_results = {},
        tool_history = {},
        context_cache = {},
        failure_retries = 0,
        last_failure_signature = nil,
        capability_snapshot = nil,
        options = {},
    }
end

function M.get(player_name)
    player_name = tostring(player_name or "")
    if states[player_name] == nil then
        states[player_name] = default_state()
    end
    return states[player_name]
end

function M.reset(player_name, message, options)
    local state = default_state()
    state.running = true
    state.message = tostring(message or "")
    state.options = options or {}
    state.max_iterations = tonumber(state.options.max_iterations) or state.max_iterations
    states[tostring(player_name or "")] = state
    return state
end

function M.cancel(player_name)
    local state = M.get(player_name)
    state.cancelled = true
    state.running = false
    return state
end

function M.finish(player_name)
    local state = M.get(player_name)
    state.running = false
    return state
end

function M.is_running(player_name)
    return M.get(player_name).running == true
end

function M.append_visible(state, text)
    text = tostring(text or "")
    if text ~= "" then
        state.visible_parts[#state.visible_parts + 1] = text
    end
end

function M.append_action_result(state, result)
    state.action_results[#state.action_results + 1] = result
end

function M.append_tool_history(state, entry)
    if entry and entry ~= "" then
        state.tool_history[#state.tool_history + 1] = tostring(entry)
    end
end

function M.set_capability_snapshot(state, snapshot)
    state.capability_snapshot = snapshot
    return snapshot
end

function M.get_all()
    return states
end

return M
