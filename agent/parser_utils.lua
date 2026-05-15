-- ===========================================================================
--  parser_utils.lua — LLM Connect v1.2.0-dev
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Stateless parsing / repair helpers for LLM output.
--
--  ROLE:
--    Raw LLM text -> normalized executable Lua text.
--    This module must stay side-effect free: no registry writes, no execution.
-- ===========================================================================

local M = {}

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------

function M.trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.normalize_line_endings(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    -- remove UTF-8 BOM if present
    s = s:gsub("^\239\187\191", "")
    return s
end

function M.strip_markdown_fence_noise(s)
    s = M.normalize_line_endings(s)
    s = s:gsub("^%s*```[%w_%-]*%s*\n", "")
    s = s:gsub("\n%s*```%s*$", "")
    return M.trim(s)
end

function M.safe_split_lines(s)
    s = M.normalize_line_endings(s)
    local lines = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- fence/block extraction
-- ---------------------------------------------------------------------------

function M.extract_code_fences(text)
    text = M.normalize_line_endings(text)
    local blocks = {}

    -- Standard fenced blocks: ```lua\n...\n```
    for lang, body in text:gmatch("```%s*([%w_%-]*)%s*\n(.-)\n%s*```") do
        blocks[#blocks + 1] = {
            lang = (lang or ""):lower(),
            code = M.trim(body),
        }
    end

    -- Broken fence fallback: opening fence without closing fence.
    if #blocks == 0 then
        local lang, body = text:match("```%s*([%w_%-]*)%s*\n(.+)$")
        if body then
            blocks[#blocks + 1] = {
                lang = (lang or ""):lower(),
                code = M.trim(body:gsub("%s*```%s*$", "")),
                repaired = true,
            }
        end
    end

    return blocks
end

function M.extract_lua_blocks(text)
    local out = {}
    for _, block in ipairs(M.extract_code_fences(text)) do
        if block.lang == "" or block.lang == "lua" or block.lang == "luau" then
            out[#out + 1] = block
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- shape detection
-- ---------------------------------------------------------------------------

function M.looks_like_lua(s)
    s = M.trim(M.strip_markdown_fence_noise(s))
    if s == "" then return false end

    local lua_markers = {
        "core%.", "minetest%.", "local%s+", "function%s*[%w_%.:]*%s*%(",
        "return%s+", "for%s+.+%s+do", "while%s+.+%s+do", "if%s+.+%s+then",
        "llm_connect%.", "registry%.", "print%s*%(", "=%s*function%s*%(",
    }
    for _, pat in ipairs(lua_markers) do
        if s:match(pat) then return true end
    end
    return false
end

local FORBIDDEN_PATTERNS = {
    {pat = "%f[%a_]io%s*%.", label = "io.*"},
    {pat = "%f[%a_]os%s*%.%s*execute", label = "os.execute"},
    {pat = "%f[%a_]debug%s*%.", label = "debug.*"},
    {pat = "%f[%a_]package%s*%.", label = "package.*"},
    {pat = "%f[%a_]require%s*%(", label = "require"},
    {pat = "%f[%a_]dofile%s*%(", label = "dofile"},
    {pat = "%f[%a_]loadfile%s*%(", label = "loadfile"},
    {pat = "%f[%a_]loadstring%s*%(", label = "loadstring"},
    {pat = "%f[%a_]load%s*%(", label = "load"},
    {pat = "%f[%a_]setfenv%s*%(", label = "setfenv"},
    {pat = "%f[%a_]getfenv%s*%(", label = "getfenv"},
}

function M.contains_forbidden_patterns(code)
    local hits = {}
    code = M.normalize_line_endings(code)
    for _, rule in ipairs(FORBIDDEN_PATTERNS) do
        if code:match(rule.pat) then hits[#hits + 1] = rule.label end
    end
    return #hits > 0, hits
end

-- ---------------------------------------------------------------------------
-- extraction policy
-- ---------------------------------------------------------------------------

local function score_lua_candidate(code)
    local score = 0
    if M.looks_like_lua(code) then score = score + 10 end
    if code:match("core%.") or code:match("minetest%.") then score = score + 8 end
    if code:match("register_%w+%s*%(") then score = score + 5 end
    if code:match("llm_connect%.") then score = score + 4 end
    if code:match("^%s*%{") then score = score - 8 end
    return score
end

function M.extract_best_lua(text)
    text = M.normalize_line_endings(text)
    local candidates = {}

    for _, block in ipairs(M.extract_lua_blocks(text)) do
        candidates[#candidates + 1] = {
            code = block.code,
            source = "fence",
            repaired = block.repaired,
            score = score_lua_candidate(block.code) + 20,
        }
    end

    if #candidates == 0 then
        local stripped = M.strip_markdown_fence_noise(text)
        if M.looks_like_lua(stripped) then
            candidates[#candidates + 1] = {
                code = stripped,
                source = "raw",
                score = score_lua_candidate(stripped),
            }
        end
    end

    if #candidates == 0 then
        return { ok = false, code = nil, reason = "no Lua code found" }
    end

    table.sort(candidates, function(a, b) return a.score > b.score end)
    local best = candidates[1]
    best.ok = best.code and best.code ~= ""
    return best
end

-- ---------------------------------------------------------------------------
-- light repair helpers — intentionally conservative
-- ---------------------------------------------------------------------------

function M.fix_markdown_fences(text)
    return M.strip_markdown_fence_noise(text)
end

function M.fix_common_lua_errors(code)
    code = M.normalize_line_endings(code)
    -- Convert old namespace in generated snippets to current preferred alias.
    code = code:gsub("%f[%a_]minetest%.", "core.")
    return M.trim(code)
end

function M.auto_repair_lua(code)
    code = M.fix_markdown_fences(code)
    code = M.fix_common_lua_errors(code)
    return code
end


-- ---------------------------------------------------------------------------
-- dual-channel action blocks
-- ---------------------------------------------------------------------------

function M.extract_action_blocks(text)
    text = M.normalize_line_endings(text or "")
    local actions = {}
    for lang, body in text:gmatch("```%s*([%w_%-]*)%s*\n(.-)\n%s*```") do
        local l = (lang or ""):lower()
        if l == "lua_action" or l == "luanti_action" or l == "llm_action" then
            actions[#actions + 1] = {
                lang = l,
                code = M.auto_repair_lua(body),
            }
        end
    end
    return actions
end

function M.strip_action_blocks(text)
    text = M.normalize_line_endings(text or "")
    text = text:gsub("```%s*[Ll][Uu][Aa]_[Aa][Cc][Tt][Ii][Oo][Nn]%s*\n.-\n%s*```", "")
    text = text:gsub("```%s*[Ll][Uu][Aa][Nn][Tt][Ii]_[Aa][Cc][Tt][Ii][Oo][Nn]%s*\n.-\n%s*```", "")
    text = text:gsub("```%s*[Ll][Ll][Mm]_[Aa][Cc][Tt][Ii][Oo][Nn]%s*\n.-\n%s*```", "")
    text = text:gsub("\n%s*\n%s*\n+", "\n\n")
    return M.trim(text)
end

function M.split_dual_channel_response(text)
    text = M.normalize_line_endings(text or "")
    return {
        raw = text,
        visible_text = M.strip_action_blocks(text),
        actions = M.extract_action_blocks(text),
    }
end

-- ---------------------------------------------------------------------------
-- Compatibility wrapper for code paths that still ask for one executable chunk.
-- The agent loop uses split_dual_channel_response() directly; this wrapper is
-- Lua-only and intentionally has no legacy tool-call fallback.
-- ---------------------------------------------------------------------------

function M.parse_llm_response(text, opts)
    opts = opts or {}
    local raw = M.normalize_line_endings(text or "")

    local lua = M.extract_best_lua(raw)
    if lua.ok then
        lua.code = M.auto_repair_lua(lua.code)
        lua.kind = "lua"
        local forbidden, hits = M.contains_forbidden_patterns(lua.code)
        lua.has_forbidden_patterns = forbidden
        lua.forbidden_patterns = hits
        return lua
    end

    return {
        ok = false,
        kind = "unknown",
        reason = lua.reason or "no executable Lua found",
        raw = raw,
    }
end

core.log("action", "[parser_utils] module loaded")

return M
