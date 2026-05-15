-- ===========================================================================
--  agent_retry.lua — repair-loop decision helpers
-- ===========================================================================

local M = {}

function M.failure_signature(result)
    if not result then return nil end
    local err = tostring(result.error or result.message or "")
    local code = tostring(result.action_code or result.code or "")
    return err:sub(1, 220) .. "\n" .. code:sub(1, 600)
end

function M.should_retry_failed_actions(state, action_results)
    if not state or not action_results or #action_results == 0 then return false end
    local failed
    for _, r in ipairs(action_results) do
        if not (r.success or r.ok) then
            failed = r
            break
        end
    end
    if not failed then return false end
    if state.failure_retries and state.failure_retries >= 1 then return false end

    local sig = M.failure_signature(failed)
    if sig and state.last_failure_signature == sig then return false end
    state.last_failure_signature = sig
    state.failure_retries = (state.failure_retries or 0) + 1
    if core and core.log then
        core.log("warning", ("[agent_retry] action failed; scheduling one repair iteration for %s"):format(tostring(state.message or "task")))
    end
    return true
end

return M
