-- ===========================================================================
--  agent_flow.lua — loop decisions, repair retries, result formatting
-- ===========================================================================

local M = {}

-- ---------------------------------------------------------------------------
-- Result formatting and normalization
-- ---------------------------------------------------------------------------

local result = {}

function result.trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function result.one_line(s, max_len)
    s = tostring(s or "")
    s = s:gsub("\n+", " "):gsub("%s+", " ")
    max_len = max_len or 120
    if #s > max_len then return s:sub(1, max_len - 3) .. "..." end
    return s
end

function result.action_result_message(action_result)
    if not action_result then return "no result" end
    if action_result.success or action_result.ok then
        local rv = action_result.return_value
        if type(rv) == "table" then
            if rv.permission_required == true then
                return tostring(rv.message or ("Permission requested: " .. tostring(rv.summary or rv.kind or "agent action")))
            end
            if type(rv.content) == "string" and rv.content ~= "" then
                local preview = rv.content
                if #preview > 1000 then preview = preview:sub(1, 1000) .. "\n... [truncated]" end
                return tostring(rv.message or "context loaded") .. ":\n" .. preview
            end
            if type(rv.sections) == "table" then
                local lines = { tostring(rv.message or "context sections available:") }
                for i, sec in ipairs(rv.sections) do
                    if i > 15 then
                        lines[#lines + 1] = "... and more"
                        break
                    end
                    lines[#lines + 1] = string.format("- %s: %s", tostring(sec.id or "?"), tostring(sec.summary or sec.title or ""))
                end
                return table.concat(lines, "\n")
            end
            return tostring(rv.message or rv.result or rv.status or "action successful")
        end
        if action_result.output and action_result.output ~= "" then return action_result.output end
        return "success"
    end
    return "error: " .. tostring(action_result.error or "failed")
end

function result.action_history_entry(iteration, action_result)
    local idx = tonumber(action_result and action_result.index) or 0
    local status = (action_result and (action_result.success or action_result.ok)) and "OK" or "FAIL"
    local prefix = string.format("[Iter %d Action %d] %s: ", tonumber(iteration) or 0, idx, status)

    local rv = action_result and action_result.return_value
    if type(rv) == "table" then
        if rv.permission_required == true then
            return prefix .. tostring(rv.message or ("Permission requested: " .. tostring(rv.summary or rv.kind or "agent action")))
        end
        if type(rv.content) == "string" and rv.content ~= "" then
            local content = rv.content
            -- Keep context history lean. The model should have what it needs now.
            if #content > 2000 then content = content:sub(1, 2000) .. "\n... [large context truncated in history]" end
            return prefix .. tostring(rv.message or "context loaded") .. "\n" .. content
        end
        if type(rv.sections) == "table" then
            local lines = { prefix .. tostring(rv.message or "available sections:") }
            for i, sec in ipairs(rv.sections) do
                if i > 10 then lines[#lines+1] = "- ..."; break end
                lines[#lines + 1] = string.format("- %s: %s", tostring(sec.id or "?"), tostring(sec.summary or sec.title or ""))
            end
            return table.concat(lines, "\n")
        end
    end

    if action_result and not (action_result.success or action_result.ok) then
        local lines = { prefix .. result.one_line(action_result.error or action_result.message or "failed", 300) }
        if action_result.action_code and action_result.action_code ~= "" then
            lines[#lines + 1] = "Attempted code:"
            lines[#lines + 1] = "```lua\n" .. tostring(action_result.action_code) .. "\n```"
        end
        lines[#lines + 1] = "Please fix the error or request documentation if an API is unclear."
        return table.concat(lines, "\n")
    end

    return prefix .. result.one_line(action_result and (action_result.message or action_result.error or "ok") or "ok", 200)
end

function result.format_results(run_result)
    if not run_result then return "(no result)" end
    if not (run_result.success or run_result.ok) then
        return "✗ Error: " .. tostring(run_result.error or "unknown")
    end
    local visible = result.trim(run_result.visible_text or "")
    if visible ~= "" then return visible end

    local count = #(run_result.action_results or {})
    if count > 0 then
        local last = run_result.action_results[count]
        return "✓ Action completed: " .. result.one_line(last and (last.message or last.output or "ok") or "ok", 120)
    end
    return "(no visible response)"
end

-- ---------------------------------------------------------------------------
-- Repair retry decisions
-- ---------------------------------------------------------------------------

local retry = {}

local function configured_max_retries()
    local raw = core and core.settings and core.settings:get("llm_agent_max_repair_retries")
    local n = tonumber(raw) or 1
    n = math.floor(n)
    if n < 0 then return 0 end
    if n > 10 then return 10 end
    return n
end

function retry.failure_signature(action_result)
    if not action_result then return nil end
    local err = tostring(action_result.error or action_result.message or "")
    local code = tostring(action_result.action_code or action_result.code or "")
    return err:sub(1, 220) .. "\n" .. code:sub(1, 600)
end

function retry.should_retry_failed_actions(state, action_results)
    if not state or not action_results or #action_results == 0 then return false end
    local failed
    for _, r in ipairs(action_results) do
        if not (r.success or r.ok) then
            failed = r
            break
        end
    end
    if not failed then return false end
    local max_retries = configured_max_retries()
    if max_retries <= 0 then return false end
    if state.failure_retries and state.failure_retries >= max_retries then return false end

    local sig = retry.failure_signature(failed)
    if sig and state.last_failure_signature == sig then return false end
    state.last_failure_signature = sig
    state.failure_retries = (state.failure_retries or 0) + 1
    if core and core.log then
        core.log("warning", ("[agent_flow] action failed; scheduling repair iteration %d/%d for %s")
            :format(tonumber(state.failure_retries) or 0, max_retries, tostring(state.message or "task")))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Adaptive continuation decisions
-- ---------------------------------------------------------------------------

local flow = {}

local function wants_continue(action_result)
    if not action_result or not (action_result.success or action_result.ok) then return false end

    local rv = action_result.return_value
    if type(rv) ~= "table" then
        return false
    end

    -- Explicit protocol
    if rv.continue == true then return true end
    if rv.done == true then return false end

    -- Context-only actions are intermediate steps once the runtime normalized
    -- their result to "not done".
    if action_result.is_context_action == true then return true end

    -- If it's a successful skill action but doesn't say it's done,
    -- we might want to allow the model one more turn to acknowledge or follow up.
    -- However, to avoid infinite loops, we are conservative here.
    return false
end

flow.wants_continue = wants_continue

function flow.decide_after_step(state, action_results, deps)
    deps = deps or {}
    local decision = {
        continue = false,
        reason = "no_continuation_requested",
    }

    for _, action_result in ipairs(action_results or {}) do
        if wants_continue(action_result) then
            decision.continue = true
            decision.reason = action_result.is_context_action and "context_lookup" or "action_requested_continue"
            return decision
        end
    end

    local retry_policy = deps.retry or retry
    if retry_policy and retry_policy.should_retry_failed_actions and retry_policy.should_retry_failed_actions(state, action_results) then
        decision.continue = true
        decision.reason = "repair_retry"
        return decision
    end

    return decision
end

M.result = result
M.retry = retry
M.flow = flow
M.middleware = flow

core.log("action", "[agent_flow] loaded — loop decisions, repair retries, and result formatting ready")

return M
