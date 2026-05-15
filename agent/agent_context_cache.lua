-- ===========================================================================
--  agent_context_cache.lua — task-local retrieved context cache
-- ===========================================================================

local M = {}

local function ensure(state)
    state.context_cache = state.context_cache or { sections = {}, order = {} }
    state.context_cache.sections = state.context_cache.sections or {}
    state.context_cache.order = state.context_cache.order or {}
    return state.context_cache
end

local function remember_section(cache, id, title, content)
    id = tostring(id or "")
    if id == "" then return end
    if cache.sections[id] == nil then
        cache.order[#cache.order + 1] = id
    end
    cache.sections[id] = {
        id = id,
        title = tostring(title or id),
        content = tostring(content or ""),
    }
end

function M.observe_result(state, result)
    if not state or not result or not (result.success or result.ok) then return end
    local rv = result.return_value
    if type(rv) ~= "table" then return end

    local cache = ensure(state)

    if type(rv.id) == "string" and type(rv.content) == "string" then
        remember_section(cache, rv.id, rv.title or rv.message, rv.content)
    elseif type(rv.section) == "table" then
        remember_section(cache, rv.section.id, rv.section.title or rv.message, rv.section.content)
    elseif type(rv.sections) == "table" then
        for _, section in ipairs(rv.sections) do
            if type(section) == "table" then
                remember_section(cache, section.id, section.title or section.summary, section.content or section.summary)
            end
        end
    elseif type(rv.content) == "string" and result.is_context_action == true then
        local id = "context-action-" .. tostring(#cache.order + 1)
        remember_section(cache, id, rv.message or "Context action", rv.content)
    end
end

function M.render_for_prompt(state, max_chars)
    if not state or not state.context_cache then return "" end
    local cache = ensure(state)
    local lines = {}
    local remaining = tonumber(max_chars) or 6000

    for _, id in ipairs(cache.order) do
        local sec = cache.sections[id]
        if sec and sec.content and sec.content ~= "" and remaining > 0 then
            local block = ("[CACHED CONTEXT: %s]\n%s"):format(tostring(sec.title or id), tostring(sec.content))
            if #block > remaining then block = block:sub(1, remaining) .. "\n... [cached context truncated]" end
            lines[#lines + 1] = block
            remaining = remaining - #block
        end
    end

    return table.concat(lines, "\n\n")
end

return M
