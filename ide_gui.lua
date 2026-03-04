-- ide_gui.lua
-- Smart Lua IDE interface for LLM-Connect
-- v0.9.0: File manager with dropdown, save/load from dedicated snippets folder

local core = core
local M = {}

-- ======================================================
-- File Storage
-- ======================================================

-- Resolve paths at load time (like sethome/init.lua does) – NOT lazily at runtime.
-- Under mod security, io.open works reliably when called with paths
-- resolved during the mod loading phase.
local SNIPPETS_DIR = (core.get_worldpath or minetest.get_worldpath)() .. "/" .. "llm_snippets"
local MKDIR_FN     = core.mkdir or minetest.mkdir

-- Create snippets dir immediately at load time
if MKDIR_FN then
    MKDIR_FN(SNIPPETS_DIR)
else
    core.log("warning", "[ide_gui] mkdir not available – snippets dir may not exist")
end

core.log("action", "[ide_gui] snippets dir: " .. SNIPPETS_DIR)

local function get_snippets_dir()
    return SNIPPETS_DIR
end

local function ensure_snippets_dir()
    -- Dir was already created at load time; this is now a no-op that just returns the path
    return SNIPPETS_DIR
end

-- Index file tracks all saved snippets (avoids core.get_dir_list which is unreliable under mod security)
local INDEX_PATH = SNIPPETS_DIR .. "/_index.txt"

local function get_index_path()
    return INDEX_PATH
end

local function read_index()
    local path = get_index_path()
    local f = io.open(path, "r")
    if not f then return {} end
    local files = {}
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            table.insert(files, line)
        end
    end
    f:close()
    table.sort(files)
    return files
end

local function write_index(files)
    local path = get_index_path()
    local sorted = {}
    for _, v in ipairs(files) do table.insert(sorted, v) end
    table.sort(sorted)
    -- deduplicate
    local seen = {}
    local deduped = {}
    for _, v in ipairs(sorted) do
        if not seen[v] then seen[v] = true; table.insert(deduped, v) end
    end
    local ok = core.safe_file_write(path, table.concat(deduped, "\n"))
    return ok
end

local function index_add(filename)
    local files = read_index()
    local exists = false
    for _, v in ipairs(files) do
        if v == filename then exists = true; break end
    end
    if not exists then
        table.insert(files, filename)
        write_index(files)
    end
end

local function index_remove(filename)
    local files = read_index()
    local new = {}
    for _, v in ipairs(files) do
        if v ~= filename then table.insert(new, v) end
    end
    write_index(new)
end

-- One-time migration: if index is empty, probe known filenames via io.open
-- and rebuild the index from whatever is actually on disk.
-- Luanti doesn't give us reliable directory listing under mod security,
-- so we use a best-effort scan of any names we can discover.
local migration_done = false
local function maybe_migrate()
    if migration_done then return end
    migration_done = true
    local idx = read_index()
    if #idx > 0 then return end  -- index already populated, nothing to do

    -- We can't list the directory, but we can check for files the user
    -- might have saved under common names in older versions.
    local dir = ensure_snippets_dir()
    local candidates = {"untitled.lua", "colorstones.lua", "test.lua", "init.lua", "startup.lua"}
    local found = {}
    for _, name in ipairs(candidates) do
        local f = io.open(dir .. "/" .. name, "r")
        if f then f:close(); table.insert(found, name) end
    end
    if #found > 0 then
        write_index(found)
        core.log("action", "[ide_gui] Migration: added " .. #found .. " existing snippets to index")
    end
end

-- Public: returns sorted list of snippet filenames
local function list_snippet_files()
    maybe_migrate()
    return read_index()
end

local function read_file(filepath)
    local f, err = io.open(filepath, "r")
    if not f then
        core.log("warning", "[ide_gui] read_file failed: " .. tostring(filepath) .. " – " .. tostring(err))
        return nil, err
    end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(filepath, content)
    -- core.safe_file_write does atomic write, preferred for snippets
    local ok = core.safe_file_write(filepath, content)
    if not ok then
        -- fallback to io.open
        local f, err = io.open(filepath, "w")
        if not f then return false, err end
        f:write(content)
        f:close()
    end
    return true
end

-- ======================================================
-- Module helpers
-- ======================================================

local function get_executor()
    if not _G.executor then
        error("[ide_gui] executor not available - init.lua failed?")
    end
    return _G.executor
end

local function get_llm_api()
    if not _G.llm_api then
        error("[ide_gui] llm_api not available - init.lua failed?")
    end
    return _G.llm_api
end

local prompts
local function get_prompts()
    if not prompts then
        local ok, p = pcall(dofile, core.get_modpath("llm_connect") .. "/ide_system_prompts.lua")
        if not ok then
            core.log("error", "[ide_gui] Failed to load prompts: " .. tostring(p))
            prompts = {
                SYNTAX_FIXER      = "Fix syntax errors in this Lua/Minetest code. Return raw Lua only.",
                SEMANTIC_ANALYZER = "Analyze this Minetest Lua code for logic errors.",
                CODE_EXPLAINER    = "Explain this Minetest Lua code simply.",
                CODE_GENERATOR    = "Generate clean Minetest Lua code based on the user request.",
            }
        else
            prompts = p
        end
    end
    return prompts
end

-- Session data per player
local sessions = {}

local DEFAULT_CODE = [[-- Welcome to Smart Lua IDE!
-- Write your Luanti mod code here.

core.register_node("example:test_node", {
    description = "Test Node",
    tiles = {"default_stone.png"},
    groups = {cracky = 3},
})
]]

local function get_session(name)
    if not sessions[name] then
        sessions[name] = {
            code             = DEFAULT_CODE,
            output           = "Ready!\nUse the toolbar buttons or type a prompt and click Generate.",
            guiding_active   = false,  -- Naming guide toggle (off by default)
            filename         = "untitled.lua",
            pending_proposal = nil,
            last_prompt      = "",
            last_modified    = os.time(),
            file_list        = {},
            selected_file    = "",
        }
        sessions[name].file_list = list_snippet_files()
    end
    return sessions[name]
end

local function has_priv(name, priv)
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

local function can_use_ide(name)
    return has_priv(name, "llm_ide") or has_priv(name, "llm_dev") or has_priv(name, "llm_root")
end

local function can_execute(name)
    return has_priv(name, "llm_dev") or has_priv(name, "llm_root")
end

local function is_root(name)
    return has_priv(name, "llm_root")
end

-- ======================================================
-- Main Formspec
-- ======================================================

function M.show(name)
    if not can_use_ide(name) then
        core.chat_send_player(name, "Missing privilege: llm_ide (or higher)")
        return
    end

    local session = get_session(name)
    -- Refresh file list on every render
    session.file_list = list_snippet_files()

    local code_esc   = core.formspec_escape(session.code or "")
    local output_esc = core.formspec_escape(session.output or "")
    local fn_esc     = core.formspec_escape(session.filename or "untitled.lua")
    local prompt_esc = core.formspec_escape(session.last_prompt or "")

    local W, H     = 19.2, 13.0
    local PAD      = 0.2
    local HEADER_H = 0.8
    local TOOL_H   = 0.9
    local FILE_H   = 0.9
    local PROMPT_H = 0.8
    local STATUS_H = 0.6

    local tool_y   = HEADER_H + PAD
    local file_y   = tool_y + TOOL_H + PAD
    local prompt_y = file_y + FILE_H + PAD
    local work_y   = prompt_y + PROMPT_H + PAD
    local work_h   = H - work_y - STATUS_H - PAD * 2
    local col_w    = (W - PAD * 3) / 2

    local fs = {
        "formspec_version[6]",
        "size[" .. W .. "," .. H .. "]",
        "bgcolor[#0f0f0f;both]",
        "style_type[*;bgcolor=#1a1a1a;textcolor=#e8e8e8;font=mono]",
    }

    -- ── Header ───────────────────────────────────────────────
    table.insert(fs, "box[0,0;" .. W .. "," .. HEADER_H .. ";#1e1e1e]")
    table.insert(fs, "label[" .. PAD .. "," .. (HEADER_H/2 - 0.15) .. ";Smart Lua IDE  |  " .. fn_esc .. "]")
    table.insert(fs, "label[" .. (W - 6.2) .. "," .. (HEADER_H/2 - 0.15) .. ";" .. os.date("%H:%M") .. "]")
    table.insert(fs, "style[close_ide;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, "button[" .. (W - PAD - 2.0) .. ",0.08;2.0,0.65;close_ide;x Close]")

    -- ── Toolbar ───────────────────────────────────────────────
    local bw   = 1.85
    local bp   = 0.12
    local bh   = TOOL_H - 0.05
    local x    = PAD

    local function add_btn(id, label, tip, enabled)
        if not enabled then
            table.insert(fs, "style[" .. id .. ";bgcolor=#444444;textcolor=#888888]")
        end
        table.insert(fs, "button[" .. x .. "," .. tool_y .. ";" .. bw .. "," .. bh .. ";" .. id .. ";" .. label .. "]")
        if tip then table.insert(fs, "tooltip[" .. id .. ";" .. tip .. "]") end
        x = x + bw + bp
    end

    add_btn("syntax",  "Syntax",   "Local syntax check + AI fix if errors found", true)
    add_btn("analyze", "Analyze",  "AI: find logic & API issues", true)
    add_btn("explain", "Explain",  "AI: explain the code in plain language", true)
    add_btn("run",     "▶ Run",    can_execute(name) and "Execute in sandbox" or "Execute (needs llm_dev)", can_execute(name))

    if session.pending_proposal then
        table.insert(fs, "style[apply;bgcolor=#2a6a2a;textcolor=#ffffff]")
        add_btn("apply", "✓ Apply", "Apply AI proposal into editor", true)
    else
        add_btn("apply", "Apply",  "No pending proposal yet", false)
    end

    -- ── File Manager Row ──────────────────────────────────────
    -- Layout: [Dropdown (files)] [Load] [Filename field] [Save] [New]
    local files   = session.file_list
    local dd_str  = #files > 0 and table.concat(files, ",") or "(no files)"
    -- Find index for pre-selection
    local dd_idx  = 1
    if session.selected_file ~= "" then
        for i, f in ipairs(files) do
            if f == session.selected_file then dd_idx = i; break end
        end
    end

    local DD_W   = 4.5
    local BTN_SM = 1.4
    local FN_W   = W - PAD * 6 - DD_W - BTN_SM * 3
    local fbh    = FILE_H - 0.05

    -- Dropdown
    table.insert(fs, "dropdown[" .. PAD .. "," .. file_y .. ";" .. DD_W .. "," .. fbh
        .. ";file_dropdown;" .. dd_str .. ";" .. dd_idx .. ";false]")
    table.insert(fs, "tooltip[file_dropdown;Select a saved snippet]")

    local fx = PAD + DD_W + PAD

    -- Load button
    table.insert(fs, "button[" .. fx .. "," .. file_y .. ";" .. BTN_SM .. "," .. fbh .. ";file_load;Load]")
    table.insert(fs, "tooltip[file_load;Load selected file into editor]")
    fx = fx + BTN_SM + PAD

    -- Filename input
    table.insert(fs, "field[" .. fx .. "," .. file_y .. ";" .. FN_W .. "," .. fbh .. ";filename_input;;" .. fn_esc .. "]")
    table.insert(fs, "field_close_on_enter[filename_input;false]")
    table.insert(fs, "style[filename_input;bgcolor=#1e1e1e;textcolor=#e8e8e8]")
    table.insert(fs, "tooltip[filename_input;Filename to save as (auto-appends .lua)]")
    fx = fx + FN_W + PAD

    -- Save / New (root only)
    if is_root(name) then
        table.insert(fs, "style[file_save;bgcolor=#2a4a6a;textcolor=#ffffff]")
        table.insert(fs, "button[" .. fx .. "," .. file_y .. ";" .. BTN_SM .. "," .. fbh .. ";file_save;Save]")
        table.insert(fs, "tooltip[file_save;Save editor content as the given filename]")
        fx = fx + BTN_SM + PAD
        table.insert(fs, "button[" .. fx .. "," .. file_y .. ";" .. BTN_SM .. "," .. fbh .. ";file_new;New]")
        table.insert(fs, "tooltip[file_new;Clear editor for a new file]")
    end

    -- ── Prompt Row ────────────────────────────────────────────
    -- Layout: [Prompt field ............] [☐ Guide] [Generate]
    local gen_w   = 2.2
    local guide_w = 3.2   -- checkbox + label
    local pr_w    = W - PAD * 4 - guide_w - gen_w

    table.insert(fs, "field[" .. PAD .. "," .. prompt_y .. ";" .. pr_w .. "," .. PROMPT_H
        .. ";prompt_input;;" .. prompt_esc .. "]")
    table.insert(fs, "field_close_on_enter[prompt_input;false]")
    table.insert(fs, "style[prompt_input;bgcolor=#1e1e1e;textcolor=#e8e8e8]")
    table.insert(fs, "tooltip[prompt_input;Describe what code to generate, then click Generate]")

    -- Naming guide toggle checkbox
    local guide_on = session.guiding_active == true
    local cx = PAD + pr_w + PAD
    local guide_color = guide_on and "#1a3a1a" or "#252525"
    table.insert(fs, "style[guide_toggle;bgcolor=" .. guide_color .. ";textcolor=#aaffaa]")
    table.insert(fs, "checkbox[" .. cx .. "," .. (prompt_y + 0.15) .. ";guide_toggle;llm_connect: guide;" .. (guide_on and "true" or "false") .. "]")
    table.insert(fs, "tooltip[guide_toggle;Inject naming convention guide into Generate calls.\nTeaches the LLM to use the llm_connect: prefix for registrations.]")

    local gx = cx + guide_w + PAD
    if can_execute(name) then
        table.insert(fs, "style[generate;bgcolor=#2a4a6a;textcolor=#ffffff]")
    else
        table.insert(fs, "style[generate;bgcolor=#444444;textcolor=#888888]")
    end
    table.insert(fs, "button[" .. gx .. "," .. prompt_y .. ";" .. gen_w .. "," .. PROMPT_H
        .. ";generate;Generate]")
    table.insert(fs, "tooltip[generate;"
        .. (can_execute(name) and "AI: generate code from your prompt" or "Generate (needs llm_dev)")
        .. "]")

    -- ── Editor & Output ───────────────────────────────────────
    table.insert(fs, "style[code;bgcolor=#1e1e1e;textcolor=#e8e8e8;border=true]")
    table.insert(fs, "textarea[" .. PAD .. "," .. work_y .. ";" .. (col_w - PAD) .. "," .. work_h
        .. ";code;;" .. code_esc .. "]")

    table.insert(fs, "style[output;bgcolor=#181818;textcolor=#cccccc;border=true]")
    table.insert(fs, "textarea[" .. (PAD + col_w + PAD) .. "," .. work_y .. ";" .. (col_w - PAD) .. "," .. work_h
        .. ";output;;" .. output_esc .. "]")

    -- ── Status Bar ────────────────────────────────────────────
    local sy = H - STATUS_H - PAD
    table.insert(fs, "box[0," .. sy .. ";" .. W .. "," .. STATUS_H .. ";#1e1e1e]")
    local status = "File: " .. fn_esc .. "  |  Modified: " .. os.date("%H:%M", session.last_modified)
    if session.pending_proposal then
        status = status .. "  |  ★ PROPOSAL READY – click Apply"
    end
    table.insert(fs, "label[" .. PAD .. "," .. (sy + 0.22) .. ";" .. status .. "]")

    core.show_formspec(name, "llm_connect:ide", table.concat(fs))
end

-- ======================================================
-- Formspec Handler
-- ======================================================

function M.handle_fields(name, formname, fields)
    if not formname:match("^llm_connect:ide") then return false end
    if not can_use_ide(name) then return true end

    local session = get_session(name)
    local updated = false

    -- Capture live editor/field state
    if fields.code           then session.code         = fields.code; session.last_modified = os.time() end
    if fields.prompt_input   then session.last_prompt  = fields.prompt_input end
    if fields.guide_toggle ~= nil then
        session.guiding_active = (fields.guide_toggle == "true")
        M.show(name)
        return true
    end
    if fields.filename_input and fields.filename_input ~= "" then
        local fn = fields.filename_input:match("^%s*(.-)%s*$")
        if fn ~= "" then
            if not fn:match("%.lua$") then fn = fn .. ".lua" end
            session.filename = fn
        end
    end

    -- Dropdown: track selection
    if fields.file_dropdown then
        local val = fields.file_dropdown
        if val ~= "(no files)" and val ~= "" then
            -- index_event=false → val is the filename directly
            -- Fallback: if val is a number string, resolve via file_list index
            local as_num = tonumber(val)
            if as_num and session.file_list and session.file_list[as_num] then
                val = session.file_list[as_num]
            end
            session.selected_file = val
        end
        updated = true
    end

    -- ── File operations ───────────────────────────────────────
    if fields.file_load then
        local target = session.selected_file
        if target == "" or target == "(no files)" then
            session.output = "Please select a file in the dropdown first."
        else
            local path    = ensure_snippets_dir() .. DIR_DELIM .. target
            local content, read_err = read_file(path)
            if content then
                session.code          = content
                session.filename      = target
                session.last_modified = os.time()
                session.output        = "✓ Loaded: " .. target
            else
                session.output = "✗ Could not read: " .. target
                    .. "\nPath: " .. path
                    .. (read_err and ("\nError: " .. tostring(read_err)) or "")
                -- Remove from index if file is gone
                index_remove(target)
                session.file_list = list_snippet_files()
            end
        end
        updated = true

    elseif fields.file_save and is_root(name) then
        local fn = session.filename
        if fn == "" then fn = "untitled.lua" end
        if not fn:match("%.lua$") then fn = fn .. ".lua" end
        fn = fn:match("([^/\\]+)$") or fn   -- prevent path traversal
        session.filename = fn

        local path      = ensure_snippets_dir() .. DIR_DELIM .. fn
        local ok, err   = write_file(path, session.code)
        if ok then
            index_add(fn)
            session.output        = "✓ Saved: " .. fn
            session.last_modified = os.time()
            session.file_list     = list_snippet_files()
            session.selected_file = fn
        else
            session.output = "✗ Save failed: " .. tostring(err)
        end
        updated = true

    elseif fields.file_new and is_root(name) then
        session.code             = DEFAULT_CODE
        session.filename         = "untitled.lua"
        session.last_modified    = os.time()
        session.pending_proposal = nil
        session.output           = "New file ready. Write code and save."
        updated = true

    -- ── Toolbar actions ───────────────────────────────────────
    elseif fields.syntax then
        M.check_syntax(name); return true

    elseif fields.analyze then
        M.analyze_code(name); return true

    elseif fields.explain then
        M.explain_code(name); return true

    elseif fields.generate and can_execute(name) then
        M.generate_code(name); return true

    elseif fields.run and can_execute(name) then
        M.run_code(name); return true

    elseif fields.apply then
        if session.pending_proposal then
            session.code             = session.pending_proposal
            session.pending_proposal = nil
            session.last_modified    = os.time()
            session.output           = "✓ Applied proposal to editor."
        else
            session.output = "No pending proposal to apply."
        end
        updated = true

    elseif fields.close_ide or fields.quit then
        if _G.chat_gui then _G.chat_gui.show(name) end
        return true
    end

    if updated then M.show(name) end
    return true
end

-- ======================================================
-- Actions (AI)
-- ======================================================

function M.check_syntax(name)
    local session = get_session(name)
    local func, err = loadstring(session.code)
    if func then
        session.output = "✓ Syntax OK – no errors found."
        M.show(name)
        return
    end

    session.output = "✗ Syntax error:\n" .. tostring(err) .. "\n\nAsking AI to fix…"
    M.show(name)

    local p = get_prompts()
    get_llm_api().code(p.SYNTAX_FIXER, session.code, function(result)
        if result.success then
            local fixed = result.content
            fixed = fixed:match("```lua\n(.-)```") or fixed:match("```\n(.-)```") or fixed
            session.pending_proposal = fixed
            session.output = "AI fix proposal:\n\n" .. fixed .. "\n\n→ Press [Apply] to use."
        else
            session.output = "Syntax error:\n" .. tostring(err)
                .. "\n\nAI fix failed: " .. (result.error or "?")
        end
        M.show(name)
    end)
end

function M.analyze_code(name)
    local session = get_session(name)
    session.output = "Analyzing code… (please wait)"
    M.show(name)

    local p = get_prompts()
    get_llm_api().code(p.SEMANTIC_ANALYZER, session.code, function(result)
        if result.success then
            local content   = result.content
            local code_part = content:match("```lua\n(.-)```") or content:match("```\n(.-)```")
            local analysis  = content:match("%-%-%[%[(.-)%]%]") or content
            if code_part then
                session.pending_proposal = code_part
                session.output = "Analysis:\n" .. analysis .. "\n\n→ Improved code ready. Press [Apply]."
            else
                session.output = "Analysis:\n" .. content
            end
        else
            session.output = "Error: " .. (result.error or "No response")
        end
        M.show(name)
    end)
end

function M.explain_code(name)
    local session = get_session(name)
    session.output = "Explaining code… (please wait)"
    M.show(name)

    local p = get_prompts()
    get_llm_api().code(p.CODE_EXPLAINER, session.code, function(result)
        session.output = result.success and result.content or ("Error: " .. (result.error or "?"))
        M.show(name)
    end)
end

function M.generate_code(name)
    local session  = get_session(name)
    local user_req = (session.last_prompt or ""):match("^%s*(.-)%s*$")

    if user_req == "" then
        session.output = "Please enter a prompt in the field above first."
        M.show(name)
        return
    end

    session.output = "Generating code… (please wait)"
    M.show(name)

    local p       = get_prompts()

    -- Append naming guide if toggle is active in session
    local guide_addendum = ""
    if session.guiding_active and p.NAMING_GUIDE then
        guide_addendum = p.NAMING_GUIDE
    end

    local sys_msg = p.CODE_GENERATOR .. guide_addendum .. "\n\nUser request: " .. user_req
    get_llm_api().code(sys_msg, session.code, function(result)
        if result.success and result.content then
            local gen = result.content
            gen = gen:match("```lua\n(.-)```") or gen:match("```\n(.-)```") or gen
            session.pending_proposal = gen
            session.output = "Generated code proposal:\n\n" .. gen
                .. "\n\n→ Press [Apply] to insert into editor."
        else
            session.output = "Generation failed: " .. (result.error or "No response")
        end
        M.show(name)
    end)
end

function M.run_code(name)
    local session  = get_session(name)
    local executor = get_executor()

    session.output = "Executing… (please wait)"
    M.show(name)

    local res = executor.execute(name, session.code, {sandbox = true})
    if res.success then
        local out = "✓ Execution successful.\n\nOutput:\n"
            .. (res.output ~= "" and res.output or "(no output)")
        if res.return_value then out = out .. "\n\nReturn: " .. tostring(res.return_value) end
        if res.persisted    then out = out .. "\n\n→ Startup file updated (restart needed)" end
        session.output = out
    else
        session.output = "✗ Execution failed:\n" .. (res.error or "Unknown error")
        if res.output and res.output ~= "" then
            session.output = session.output .. "\n\nOutput before error:\n" .. res.output
        end
    end
    M.show(name)
end

-- Cleanup
core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

return M
