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
        if result.output and result.output ~= "" then return result.output end
        return "success"
    end
    return "error: " .. tostring(result.error or "failed")
end

function M.action_history_entry(iteration, result)
    local idx = tonumber(result and result.index) or 0
    local status = (result and (result.success or result.ok)) and "OK" or "FAIL"
    local prefix = string.format("[Iter %d Action %d] %s: ", tonumber(iteration) or 0, idx, status)

    local rv = result and result.return_value
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

    if result and not (result.success or result.ok) then
        local lines = { prefix .. M.one_line(result.error or result.message or "failed", 300) }
        if result.action_code and result.action_code ~= "" then
            lines[#lines + 1] = "Attempted code:"
            lines[#lines + 1] = "```lua\n" .. tostring(result.action_code) .. "\n```"
        end
        lines[#lines + 1] = "Please fix the error or request documentation if an API is unclear."
        return table.concat(lines, "\n")
    end

    return prefix .. M.one_line(result and (result.message or result.error or "ok") or "ok", 200)
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
