-- ===========================================================================
--  agent_middleware.lua — adaptive loop continuation decisions
-- ===========================================================================

local M = {}

local function wants_continue(result)
    if not result or not (result.success or result.ok) then return false end

    local rv = result.return_value
    if type(rv) ~= "table" then
        return false
    end

    -- Explicit protocol
    if rv.continue == true then return true end
    if rv.done == true then return false end

    -- Context-only actions are intermediate steps once the runtime normalized
    -- their result to "not done".
    if result.is_context_action == true then return true end

    -- If it's a successful skill action but doesn't say it's done,
    -- we might want to allow the model one more turn to acknowledge or follow up.
    -- However, to avoid infinite loops, we are conservative here.
    return false
end

M.wants_continue = wants_continue

function M.decide_after_step(state, action_results, deps)
    deps = deps or {}
    local decision = {
        continue = false,
        reason = "no_continuation_requested",
    }

    for _, result in ipairs(action_results or {}) do
        if wants_continue(result) then
            decision.continue = true
            decision.reason = result.is_context_action and "context_lookup" or "action_requested_continue"
            return decision
        end
    end

    local retry = deps.retry
    if retry and retry.should_retry_failed_actions and retry.should_retry_failed_actions(state, action_results) then
        decision.continue = true
        decision.reason = "repair_retry"
        return decision
    end

    return decision
end

return M
