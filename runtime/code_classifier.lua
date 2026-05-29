-- ===========================================================================
--  code_classifier.lua - IDE/runtime code classification metadata
--
--  Classification is advisory metadata only. It may block execution through
--  callers, but it must never change filesystem paths.
-- ===========================================================================

local M = {}

M.version = "1.2.0"

local DANGEROUS_PATTERNS = {
    {pattern = "os%.execute%s*%(", label = "os.execute"},
    {pattern = "io%.popen%s*%(", label = "io.popen"},
    {pattern = "package%.", label = "package.*"},
    {pattern = "debug%.", label = "debug.*"},
    {pattern = "loadfile%s*%(", label = "loadfile"},
    {pattern = "dofile%s*%(", label = "dofile"},
    {pattern = "require%s*%(", label = "require"},
}

local STARTUP_PATTERNS = {
    {pattern = "%.register_node%s*%(", label = "register_node"},
    {pattern = "%.register_tool%s*%(", label = "register_tool"},
    {pattern = "%.register_craftitem%s*%(", label = "register_craftitem"},
    {pattern = "%.register_entity%s*%(", label = "register_entity"},
    {pattern = "%.register_craft%s*%(", label = "register_craft"},
    {pattern = "%.register_privilege%s*%(", label = "register_privilege"},
}

local STICKY_PATTERNS = {
    {pattern = "%.register_globalstep%s*%(", label = "register_globalstep"},
    {pattern = "%.register_chatcommand%s*%(", label = "register_chatcommand"},
    {pattern = "%.register_on_%w+%s*%(", label = "register_on_*"},
    {pattern = "%.register_abm%s*%(", label = "register_abm"},
    {pattern = "%.register_lbm%s*%(", label = "register_lbm"},
}

local function collect_hits(code, patterns)
    local hits = {}
    for _, item in ipairs(patterns) do
        if code:find(item.pattern) then hits[#hits + 1] = item.label end
    end
    return hits
end

local function scan_registration_names(code)
    local names = {}
    for name in code:gmatch("register_%w+%s*%(%s*[%\"%']([^%\"%']+)[%\"%']") do
        names[#names + 1] = name
    end
    return names
end

function M.classify(code, context)
    context = context or {}
    code = tostring(code or "")

    local mode = context.mode or "in_runtime"
    local result = {
        class = "runtime_safe",
        mode = mode,
        persistable = true,
        requires_restart = false,
        sticky = false,
        dangerous = false,
        issues = {},
        hits = {},
        namespace_violations = {},
    }

    local dangerous_hits = collect_hits(code, DANGEROUS_PATTERNS)
    if #dangerous_hits > 0 then
        result.class = "dangerous"
        result.persistable = false
        result.dangerous = true
        result.hits = dangerous_hits
        result.issues[#result.issues + 1] = "Dangerous host access: " .. table.concat(dangerous_hits, ", ")
        return result
    end

    local allowed_prefix = "llm_connect"

    for _, reg_name in ipairs(scan_registration_names(code)) do
        local prefix = reg_name:match("^([^:]+):")
        if prefix and prefix ~= allowed_prefix then
            result.namespace_violations[#result.namespace_violations + 1] = reg_name
        elseif not prefix then
            result.namespace_violations[#result.namespace_violations + 1] = reg_name
        end
    end

    if #result.namespace_violations > 0 then
        result.issues[#result.issues + 1] = "Registration namespace outside " .. allowed_prefix .. ":*: "
            .. table.concat(result.namespace_violations, ", ")
    end

    local startup_hits = collect_hits(code, STARTUP_PATTERNS)
    local sticky_hits = collect_hits(code, STICKY_PATTERNS)

    if #startup_hits > 0 then
        result.class = "startup_preferred"
        result.requires_restart = true
        result.hits = startup_hits
    elseif #sticky_hits > 0 then
        result.class = "sticky_runtime"
        result.sticky = true
        result.hits = sticky_hits
        result.issues[#result.issues + 1] = "Sticky runtime registration may duplicate callbacks on reload."
    end

    return result
end

function M.format_summary(classification)
    classification = classification or {class = "unknown"}
    local parts = {"Class: " .. tostring(classification.class)}
    parts[#parts + 1] = "Cold reload: enable saved scripts in Files for next server/world restart"
    if classification.requires_restart then parts[#parts + 1] = "Restart: recommended" end
    if classification.sticky then parts[#parts + 1] = "Sticky: yes" end
    if classification.issues and #classification.issues > 0 then
        parts[#parts + 1] = "Issues: " .. table.concat(classification.issues, " | ")
    end
    return table.concat(parts, "\n")
end

M.format_class_summary = M.format_summary

return M
