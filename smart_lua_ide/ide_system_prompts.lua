-- ===========================================================================
--  ide_system_prompts.lua — LLM Connect / Smart Lua IDE
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Static prompts and dynamic context block builder for IDE AI modes.
--  Ported from 0.9.0 — only change: ide_api_stubs.lua path updated to
--  smart_lua_ide/ (was root in 0.9.0).
--
--  build_context(opts) opts fields (all optional):
--    filename      string  – currently open file name
--    player_pos    table   – {x, y, z}
--    mod_list      string  – comma-separated active mod names
--    asset_context string  – pre-built block from ide_asset_picker
--    last_output   string  – last execution output (truncated if needed)
--    api_level     string  – nil | "slim" | "full"
--
-- ===========================================================================

local prompts = {}

prompts.SYNTAX_FIXER = [[You are a Lua syntax corrector specialized in Minetest/Luanti mod development.

Your task: Fix ONLY syntax errors in the provided code.

Rules:
1. Return ONLY the corrected Lua code
2. NO explanations, NO markdown blocks, NO comments
3. Preserve the original logic and structure
4. Fix: missing 'end', unmatched parentheses, typos in keywords, etc.
5. Do NOT refactor or optimize - only fix syntax
6. Do NOT add any filesystem/network/system access

Output format: Raw Lua code only.]]

prompts.SEMANTIC_ANALYZER = [[You are a Lua code analyzer for Minetest/Luanti mods.

Your task: Analyze code for logic errors, API misuse, and improvements.

Context:
- Minetest Lua API version 5.x
- Common APIs: core.register_node, core.register_tool, core.register_chatcommand
- Deprecated functions should be flagged

Security rules:
- Do NOT introduce os/io/debug/require/dofile/loadfile/package
- Do NOT introduce core.request_http_api or core.request_insecure_environment

Output format:
1. First, provide the CORRECTED CODE
2. Then, add a comment block explaining:
  - What was wrong
  - What was changed
  - Why it matters

Example format:
-- [CORRECTED CODE HERE]
--[[ ANALYSIS:
- ...
]]]]

prompts.CODE_EXPLAINER = [[You are a Minetest/Luanti mod development tutor.

Your task: Explain the provided Lua code in simple terms.

Focus on:
1. What the code does (high-level)
2. Key Minetest API calls and their purpose
3. Potential issues or improvements
4. Best practices being followed/violated

Be concise but educational.]]

prompts.CODE_GENERATOR = [[You are a Minetest/Luanti mod code generator running inside the LLM Connect Smart Lua IDE.

Your task: Generate clean, functional Lua code based on the user's request.

Requirements:
1. Use the Minetest/Luanti Lua API (core.*)
2. All registrations MUST use the "llm_connect:" mod prefix
3. Return ONLY the Lua code — no markdown fences, no preamble
4. Code must be complete and runnable as-is
5. No io/os.execute/debug/require/dofile/loadfile]]

prompts.NAMING_GUIDE = [[

IMPORTANT – Luanti/Minetest Naming Conventions for this IDE:
This code runs inside the "llm_connect" mod context.

REGISTRATIONS – always use "llm_connect:" prefix:
  Correct:   core.register_node("llm_connect:my_stone", { ... })
  Correct:   core.register_craftitem("llm_connect:magic_dust", { ... })
  Incorrect: core.register_node("mymod:my_stone", { ... })   -- fails
  Incorrect: core.register_node("default:my_stone", { ... }) -- fails

LUA STDLIB – Luanti uses LuaJIT, not standard Lua:
  No string:capitalize() – use: (str:sub(1,1):upper() .. str:sub(2))
  No string:split()      – use: string.gmatch or manual parsing

READING other mods is always fine:
  core.get_node(pos)                       -- ok
  core.registered_nodes["default:stone"]   -- ok
]]

-- ===========================================================================
-- Dynamic context block builder
-- ===========================================================================

local function truncate(str, max_chars)
    if not str or #str == 0 then return nil end
    if #str <= max_chars then return str end
    return str:sub(1, max_chars) .. "\n… [truncated]"
end

local _stubs_cache = nil
local function get_stubs()
    if _stubs_cache then return _stubs_cache end
    -- 1.0: path updated to smart_lua_ide/
    local ok, stubs = pcall(dofile,
        core.get_modpath("llm_connect") .. "/smart_lua_ide/ide_api_stubs.lua")
    if ok and stubs then
        _stubs_cache = stubs
    else
        core.log("warning", "[ide_system_prompts] could not load ide_api_stubs.lua: "
            .. tostring(stubs))
        _stubs_cache = {}
    end
    return _stubs_cache
end

function prompts.build_context(opts)
    opts = opts or {}
    local parts = {}

    if opts.filename and opts.filename ~= "" and opts.filename ~= "untitled.lua" then
        parts[#parts + 1] = "File: " .. opts.filename
    end
    if opts.player_pos then
        local p = opts.player_pos
        parts[#parts + 1] = string.format("Player pos: (%d, %d, %d)", p.x, p.y, p.z)
    end
    if opts.mod_list and opts.mod_list ~= "" then
        parts[#parts + 1] = "Active mods: " .. opts.mod_list
    end
    if opts.asset_context and opts.asset_context ~= "" then
        parts[#parts + 1] = opts.asset_context
    end
    local run_out = truncate(opts.last_output, 800)
    if run_out then
        parts[#parts + 1] = "Last execution output:\n" .. run_out
    end
    if opts.api_level then
        local api_text = get_stubs()[opts.api_level]
        if api_text then
            parts[#parts + 1] = api_text
        else
            core.log("warning", "[ide_system_prompts] unknown api_level: " .. tostring(opts.api_level))
        end
    end

    if #parts == 0 then return nil end
    return "=== IDE CONTEXT ===\n" .. table.concat(parts, "\n") .. "\n=== END CONTEXT ==="
end

return prompts
