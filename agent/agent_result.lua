-- ===========================================================================
--  agent_result.lua — result formatting and normalization helpers
-- ===========================================================================

local M = {}

function M.trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.one_line(s, max_len)
    s = tostring(s or "")
    s = s:gsub("\n+", " "):gsub("%s+", " ")
    max_len = max_len or 120
    if #s > max_len then return s:sub(1, max_len - 3) .. "..." end
    return s
end

function M.action_result_message(result)
    if not result then return "no result" end
    if result.success or result.ok then
        local rv = result.return_value
        if type(rv) == "table" then
            if type(rv.content) == "string" and rv.content ~= "" then
                return tostring(rv.message or "context loaded") .. "\n" .. rv.content
            end
            if type(rv.sections) == "table" then
                local lines = { tostring(rv.message or "context sections") }
                for _, sec in ipairs(rv.sections) do
                    lines[#lines + 1] = string.format("- %s: %s", tostring(sec.id or "?"), tostring(sec.summary or sec.title or ""))
                end
                return table.concat(lines, "\n")
            end
            return tostring(rv.message or rv.result or rv.status or "ok")
        end
        if result.output and result.output ~= "" then return result.output end
        return "ok"
    end
    return tostring(result.error or "failed")
end

function M.action_history_entry(iteration, result)
    local prefix = string.format(
        "iteration %d action %d: %s — ",
        tonumber(iteration) or 0,
        tonumber(result and result.index) or 0,
        (result and (result.success or result.ok)) and "ok" or "failed"
    )

    local rv = result and result.return_value
    if type(rv) == "table" and type(rv.content) == "string" and rv.content ~= "" then
        local content = rv.content
        if #content > 6000 then content = content:sub(1, 6000) .. "\n... [context truncated]" end
        return prefix .. tostring(rv.message or "context loaded") .. "\n" .. content
    end
    if type(rv) == "table" and type(rv.sections) == "table" then
        local lines = { prefix .. tostring(rv.message or "context sections") }
        for _, sec in ipairs(rv.sections) do
            lines[#lines + 1] = string.format("- %s: %s", tostring(sec.id or "?"), tostring(sec.summary or sec.title or ""))
        end
        return table.concat(lines, "\n")
    end
    if result and not (result.success or result.ok) then
        local lines = { prefix .. M.one_line(result.error or result.message or "failed", 240) }
        if result.action_code and result.action_code ~= "" then
            lines[#lines + 1] = "Failed lua_action code:"
            lines[#lines + 1] = "```lua"
            lines[#lines + 1] = tostring(result.action_code)
            lines[#lines + 1] = "```"
        end
        if result.traceback and result.traceback ~= "" then
            lines[#lines + 1] = "Traceback/error detail:"
            lines[#lines + 1] = M.one_line(result.traceback, 1200)
        end
        lines[#lines + 1] = "Repair instruction: either request focused context first, or emit a corrected lua_action. Do not repeat the same failing action."
        return table.concat(lines, "\n")
    end

    return prefix .. M.one_line(result and (result.message or result.error or "") or "", 180)
end

function M.format_results(result)
    if not result then return "(no result)" end
    if not (result.success or result.ok) then
        return "✗ Error: " .. tostring(result.error or "unknown")
    end
    local visible = M.trim(result.visible_text or "")
    if visible ~= "" then return visible end

    local count = #(result.action_results or {})
    if count > 0 then
        local last = result.action_results[count]
        return "✓ Action completed: " .. M.one_line(last and (last.message or last.output or "ok") or "ok", 120)
    end
    return "(no visible response)"
end

return M
