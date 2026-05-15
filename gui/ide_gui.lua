-- ===========================================================================
--  ide_gui.lua — LLM Connect / Smart Lua IDE
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Smart Lua IDE formspec, toolbar, file manager, and all AI actions.
--  Ported from 0.9.0, adapted for 1.0 architecture:
--    - ide_system_prompts.lua loaded from gui/ subfolder
--    - code_executor.lua loaded from gui/ subfolder
--    - close_ide button returns to main_gui (was chat_gui in 0.9.0)
--    - _G.executor → _G.code_executor
--
-- ===========================================================================

local core = core
local M    = {}

-- ===========================================================================
-- File Storage
-- ===========================================================================

local SNIPPETS_DIR = (core.get_worldpath or minetest.get_worldpath)() .. "/" .. "llm_snippets"
local MKDIR_FN     = core.mkdir or minetest.mkdir

if MKDIR_FN then
    MKDIR_FN(SNIPPETS_DIR)
else
    core.log("warning", "[ide_gui] mkdir not available – snippets dir may not exist")
end

core.log("action", "[ide_gui] snippets dir: " .. SNIPPETS_DIR)

local function ensure_snippets_dir()
    return SNIPPETS_DIR
end

local INDEX_PATH = SNIPPETS_DIR .. "/_index.txt"

local function read_index()
    local f = io.open(INDEX_PATH, "r")
    if not f then return {} end
    local files = {}
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then table.insert(files, line) end
    end
    f:close()
    table.sort(files)
    return files
end

local function write_index(files)
    local sorted = {}
    for _, v in ipairs(files) do table.insert(sorted, v) end
    table.sort(sorted)
    local seen, deduped = {}, {}
    for _, v in ipairs(sorted) do
        if not seen[v] then seen[v] = true; table.insert(deduped, v) end
    end
    return core.safe_file_write(INDEX_PATH, table.concat(deduped, "\n"))
end

local function index_add(filename)
    local files = read_index()
    for _, v in ipairs(files) do if v == filename then return end end
    table.insert(files, filename)
    write_index(files)
end

local function index_remove(filename)
    local files, new = read_index(), {}
    for _, v in ipairs(files) do if v ~= filename then table.insert(new, v) end end
    write_index(new)
end

local migration_done = false
local function maybe_migrate()
    if migration_done then return end
    migration_done = true
    local idx = read_index()
    if #idx > 0 then return end
    local dir = ensure_snippets_dir()
    local candidates = {"untitled.lua","colorstones.lua","test.lua","init.lua","startup.lua"}
    local found = {}
    for _, name in ipairs(candidates) do
        local f = io.open(dir .. "/" .. name, "r")
        if f then f:close(); table.insert(found, name) end
    end
    if #found > 0 then
        write_index(found)
        core.log("action", "[ide_gui] migration: added " .. #found .. " existing snippets to index")
    end
end

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
    local ok = core.safe_file_write(filepath, content)
    if not ok then
        local f, err = io.open(filepath, "w")
        if not f then return false, err end
        f:write(content)
        f:close()
    end
    return true
end

-- ===========================================================================
-- Module helpers
-- ===========================================================================

local unavailable_storage = {
    ensure_session = function(session) session.file_list = session.file_list or {} end,
    list = function() return {} end,
    status = function() return "storage unavailable" end,
    can_switch_backend = function() return false end,
    next_backend = function(_, current) return current end,
    read = function() return nil, "storage unavailable" end,
    read_path = function() return nil, "storage unavailable" end,
    save = function() return false, "storage unavailable" end,
    hot_reload = function() return { ok = false, success = false, message = "storage unavailable", error = "storage unavailable" } end,
    delete = function() return false, "storage unavailable" end,
}

local unavailable_runtime = {
    execute = function() return { ok = false, success = false, message = "runtime unavailable", error = "runtime unavailable" } end,
    execute_with_retry = function() return { ok = false, success = false, message = "runtime unavailable", error = "runtime unavailable" } end,
    precheck = function() return { ok = false, success = false, message = "runtime unavailable", error = "runtime unavailable" } end,
}

local unavailable_api = {
    code = function(_, _, callback) if callback then callback({ success = false, error = "api unavailable" }) end; return false end,
    ask = function(_, _, callback) if callback then callback({ success = false, error = "api unavailable" }) end; return false end,
    request = function(_, callback) if callback then callback({ success = false, error = "api unavailable" }) end; return false end,
}


local function get_executor()
    local root = _G.llm_connect
    local ex = root and (root.runtime or root.core_executor) or _G.code_executor or _G.executor
    return ex or unavailable_runtime
end

local function get_storage()
    return _G.ide_storage or unavailable_storage
end

local function get_api()
    local root = _G.llm_connect
    local api = root and root.api
    return api or unavailable_api
end

local prompts
local function get_prompts()
    if not prompts then
        -- 1.0: path updated to gui/
        local ok, p = pcall(dofile,
            core.get_modpath("llm_connect") .. "/gui/ide_system_prompts.lua")
        if not ok then
            core.log("error", "[ide_gui] failed to load ide_system_prompts: " .. tostring(p))
            prompts = {
                SYNTAX_FIXER      = "Fix syntax errors in this Lua/Minetest code. Return raw Lua only.",
                SEMANTIC_ANALYZER = "Analyze this Minetest Lua code for logic errors.",
                CODE_EXPLAINER    = "Explain this Minetest Lua code simply.",
                CODE_GENERATOR    = "Generate clean Minetest Lua code based on the user request.",
                build_context     = function() return nil end,
            }
        else
            prompts = p
        end
    end
    return prompts
end

-- ===========================================================================
-- Session
-- ===========================================================================

local sessions = {}

local DEFAULT_CODE = [[-- Welcome to Smart Lua IDE!
-- Write your Luanti mod code here.
-- All registrations must use the "llm_connect:" prefix.

-- Example: register a simple node
core.register_node("llm_connect:my_node", {
    description = "My Node",
    tiles = {"default_stone.png"},
    groups = {cracky = 3},
})
]]

local function get_session(name)
    if not sessions[name] then
        sessions[name] = {
            code             = DEFAULT_CODE,
            code_rev         = 0,
            output           = "Ready!\nUse the toolbar buttons or type a prompt and click Generate.",
            filename         = "untitled.lua",
            pending_proposal = nil,
            last_prompt      = "",
            last_modified    = os.time(),
            file_list        = {},
            selected_file    = "",
            guiding_active   = false,
            assets_active    = false,
            api_level        = nil,
            last_run_output  = nil,
            run_failed       = false,
            persist_backend  = "llm_runtime",
            active_modname   = "llm_live_mod",
            current_dir      = "",
        }
        sessions[name].file_list = get_storage().list(name, sessions[name])
    end
    return sessions[name]
end

core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

local function get_policy()
    return _G.llm_connect and _G.llm_connect.policy
end

local function has_priv(name, priv)
    local policy = get_policy()
    if policy and policy.has_priv then return policy.has_priv(name, priv) end
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

local function can_use_ide(name)
    local policy = get_policy()
    return policy and policy.can_ide and policy.can_ide(name) or has_priv(name, "llm_dev")
end

local function can_execute(name)
    local policy = get_policy()
    return policy and policy.can_ide and policy.can_ide(name) or has_priv(name, "llm_dev")
end

local function is_root(name)
    local policy = get_policy()
    return policy and policy.is_root and policy.is_root(name) or has_priv(name, "llm_root")
end

local function get_execution_ctx(name)
    local policy = get_policy()
    return policy and policy.get_context and policy.get_context(name, is_root(name) and "llm_root" or "llm_dev") or nil
end

-- ===========================================================================
-- M.show
-- ===========================================================================

function M.show(name)
    if not can_use_ide(name) then
        core.chat_send_player(name, "[LLM] Missing privilege: llm_dev (or llm_root)")
        return
    end

    local session  = get_session(name)
    local storage = get_storage()
    storage.ensure_session(session)
    session.file_list = storage.list(name, session)

    local code_field = "code_" .. (session.code_rev or 0)
    local code_esc   = core.formspec_escape(session.code or "")
    local output_esc = core.formspec_escape(session.output or "")
    local fn_esc     = core.formspec_escape(session.filename or "untitled.lua")
    local prompt_esc = core.formspec_escape(session.last_prompt or "")

    local W        = 19.2
    local H        = 13.0
    local PAD      = 0.2
    local HEADER_H = 0.8
    local TOOL_H   = 0.9
    local FILE_H   = 0.9
    local CTX_H    = 0.7
    local PROMPT_H = 0.8
    local STATUS_H = 0.6

    local tool_y   = HEADER_H + PAD
    local file_y   = tool_y   + TOOL_H   + PAD
    local ctx_y    = file_y   + FILE_H   + PAD
    local prompt_y = ctx_y    + CTX_H    + PAD
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
    local backend_label = storage.status(session)
    table.insert(fs, "label[" .. 7.4 .. "," .. (HEADER_H/2 - 0.15) .. ";Backend: " .. core.formspec_escape(backend_label) .. "]")
    if storage.can_switch_backend(name) then
        table.insert(fs, "button[" .. 12.7 .. ",0.08;1.7,0.65;backend_switch;Switch]")
        table.insert(fs, "tooltip[backend_switch;Switch persistence backend: LLM Runtime <-> Trusted Worldmod]")
    end
    table.insert(fs, "label[" .. (W - 6.2) .. "," .. (HEADER_H/2 - 0.15) .. ";" .. os.date("%H:%M") .. "]")
    table.insert(fs, "style[close_ide;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, "button[" .. (W - PAD - 2.0) .. ",0.08;2.0,0.65;close_ide;x Close]")

    -- ── Toolbar ───────────────────────────────────────────────
    local bw  = 1.85
    local bp  = 0.12
    local bh  = TOOL_H - 0.05
    local x   = PAD

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
    add_btn("run",     "▶ Run",    can_execute(name) and (((get_execution_ctx(name) or {}).execution_mode == "unrestricted") and "Execute unrestricted (root)" or "Execute in sandbox") or "Needs llm_dev", can_execute(name))
    if is_root(name) and core.settings:get_bool("llm_ide_hot_reload", true) then
        table.insert(fs, "style[hot_reload;bgcolor=#4a3a1a;textcolor=#ffeeaa]")
        add_btn("hot_reload", "↻ Reload", "Save through active backend and hot-reload if runtime-safe", true)
    end

    if session.run_failed then
        table.insert(fs, "style[auto_fix;bgcolor=#3a1a00;textcolor=#ffcc44]")
        local af_iters = tonumber(core.settings:get("llm_ide_auto_fix_iterations")) or 3
        add_btn("auto_fix", "⟳ Auto-Fix", ("AI debug loop: auto-correct and re-run (max %d iters)"):format(af_iters), true)
    else
        add_btn("auto_fix", "Auto-Fix", "Run code first to enable auto-fix on error", false)
    end

    if session.pending_proposal then
        table.insert(fs, "style[apply;bgcolor=#2a6a2a;textcolor=#ffffff]")
        add_btn("apply", "✓ Apply", "Apply AI proposal into editor", true)
    else
        add_btn("apply", "Apply",  "No pending proposal yet", false)
    end

    -- ── File Manager Row ──────────────────────────────────────
    local files  = session.file_list
    local dd_str = #files > 0 and table.concat(files, ",") or "(no files)"
    local dd_idx = 1
    if session.selected_file ~= "" then
        for i, f in ipairs(files) do
            if f == session.selected_file then dd_idx = i; break end
        end
    end

    local DD_W   = 4.3
    local BTN_SM = 1.35
    local FN_W   = W - PAD * 8 - DD_W - BTN_SM * 5
    if FN_W < 3.0 then FN_W = 3.0 end
    local fbh    = FILE_H - 0.05

    table.insert(fs, "dropdown[" .. PAD .. "," .. file_y .. ";" .. DD_W .. "," .. fbh
        .. ";file_dropdown;" .. dd_str .. ";" .. dd_idx .. ";false]")
    table.insert(fs, "tooltip[file_dropdown;Select a saved snippet]")

    local fx = PAD + DD_W + PAD
    table.insert(fs, "button[" .. fx .. "," .. file_y .. ";" .. BTN_SM .. "," .. fbh .. ";file_load;Load]")
    table.insert(fs, "tooltip[file_load;Load selected file into editor]")
    fx = fx + BTN_SM + PAD
    table.insert(fs, "button[" .. fx .. "," .. file_y .. ";" .. BTN_SM .. "," .. fbh .. ";files_open;Files]")
    table.insert(fs, "tooltip[files_open;Open small file manager subformspec]")
    fx = fx + BTN_SM + PAD

    table.insert(fs, "field[" .. fx .. "," .. file_y .. ";" .. FN_W .. "," .. fbh .. ";filename_input;;" .. fn_esc .. "]")
    table.insert(fs, "field_close_on_enter[filename_input;false]")
    table.insert(fs, "style[filename_input;bgcolor=#1e1e1e;textcolor=#e8e8e8]")
    table.insert(fs, "tooltip[filename_input;Filename to save as (auto-appends .lua)]")
    fx = fx + FN_W + PAD

    if is_root(name) then
        table.insert(fs, "style[file_save;bgcolor=#2a4a6a;textcolor=#ffffff]")
        table.insert(fs, "button[" .. fx .. "," .. file_y .. ";" .. BTN_SM .. "," .. fbh .. ";file_save;Save]")
        table.insert(fs, "tooltip[file_save;Save editor content through active persistence backend]")
        fx = fx + BTN_SM + PAD
        table.insert(fs, "button[" .. fx .. "," .. file_y .. ";" .. BTN_SM .. "," .. fbh .. ";file_new;New]")
        table.insert(fs, "tooltip[file_new;Clear editor for a new file]")
    end

    -- ── Context Toggle Row ────────────────────────────────────
    table.insert(fs, "box[0," .. ctx_y .. ";" .. W .. "," .. CTX_H .. ";#161616]")

    local cx     = PAD
    local cy_cb  = ctx_y + (CTX_H - 0.4) / 2

    local guide_on = session.guiding_active == true
    table.insert(fs, "style[guide_toggle;bgcolor=" .. (guide_on and "#1a3a1a" or "#252525") .. ";textcolor=#aaffaa]")
    table.insert(fs, "checkbox[" .. cx .. "," .. cy_cb .. ";guide_toggle;llm_connect: guide;" .. (guide_on and "true" or "false") .. "]")
    table.insert(fs, "tooltip[guide_toggle;Inject naming convention guide into Generate calls]")
    cx = cx + 3.3

    local assets_on  = session.assets_active == true
    local asset_picker = _G.ide_asset_picker
    local asset_count  = asset_picker and asset_picker.get_asset_count(name) or 0
    local assets_label = asset_count > 0 and ("Assets (" .. asset_count .. ")") or "Assets"
    table.insert(fs, "style[assets_toggle;bgcolor=" .. (assets_on and "#1a2a3a" or "#252525") .. ";textcolor=#aaddff]")
    table.insert(fs, "checkbox[" .. cx .. "," .. cy_cb .. ";assets_toggle;" .. assets_label .. ";" .. (assets_on and "true" or "false") .. "]")
    table.insert(fs, "tooltip[assets_toggle;Inject selected asset metadata into Generate calls]")
    cx = cx + 2.8

    table.insert(fs, "style[assets_open;bgcolor=#1a2030;textcolor=#8899cc]")
    table.insert(fs, "button[" .. cx .. "," .. ctx_y .. ";1.3," .. CTX_H .. ";assets_open;▸ Pick]")
    table.insert(fs, "tooltip[assets_open;Open asset picker to select nodes, items, and sounds]")
    cx = cx + 1.3 + PAD + 0.3

    local api_slim_on = session.api_level == "slim"
    table.insert(fs, "style[api_slim_toggle;bgcolor=" .. (api_slim_on and "#2a1a3a" or "#252525") .. ";textcolor=#ccaaff]")
    table.insert(fs, "checkbox[" .. cx .. "," .. cy_cb .. ";api_slim_toggle;API: slim;" .. (api_slim_on and "true" or "false") .. "]")
    table.insert(fs, "tooltip[api_slim_toggle;Inject compact Luanti API reference (~400 tokens) into Generate calls]")
    cx = cx + 2.4

    local api_full_on = session.api_level == "full"
    table.insert(fs, "style[api_full_toggle;bgcolor=" .. (api_full_on and "#3a1a2a" or "#252525") .. ";textcolor=#ffaacc]")
    table.insert(fs, "checkbox[" .. cx .. "," .. cy_cb .. ";api_full_toggle;API: full;" .. (api_full_on and "true" or "false") .. "]")
    table.insert(fs, "tooltip[api_full_toggle;Inject full Luanti API reference (~2000 tokens). ⚠ High token cost.]")

    -- ── Prompt Input ──────────────────────────────────────────
    local gen_w = 3.0
    table.insert(fs, "field[" .. PAD .. "," .. prompt_y .. ";"
        .. (W - PAD*3 - gen_w) .. "," .. PROMPT_H
        .. ";prompt_input;;" .. prompt_esc .. "]")
    table.insert(fs, "field_close_on_enter[prompt_input;false]")
    table.insert(fs, "style[prompt_input;bgcolor=#1e1e1e;textcolor=#e8e8e8]")
    table.insert(fs, "tooltip[prompt_input;Describe what you want to generate]")

    table.insert(fs, "style[generate;bgcolor=#1a3a1a;textcolor=#aaffaa]")
    table.insert(fs, "button[" .. (W - PAD - gen_w) .. "," .. prompt_y .. ";"
        .. gen_w .. "," .. PROMPT_H .. ";generate;★ Generate]")
    table.insert(fs, "tooltip[generate;Send prompt to LLM and receive code proposal]")

    -- ── Editor & Output ───────────────────────────────────────
    table.insert(fs, "style[code;bgcolor=#1e1e1e;textcolor=#e8e8e8;border=true]")
    table.insert(fs, "textarea[" .. PAD .. "," .. work_y .. ";"
        .. (col_w - PAD) .. "," .. work_h .. ";" .. code_field .. ";;" .. code_esc .. "]")

    table.insert(fs, "style[output;bgcolor=#181818;textcolor=#cccccc;border=true]")
    table.insert(fs, "textarea[" .. (PAD + col_w + PAD) .. "," .. work_y .. ";"
        .. (col_w - PAD) .. "," .. work_h .. ";output;;" .. output_esc .. "]")

    -- ── Status Bar ────────────────────────────────────────────
    local sy = H - STATUS_H - PAD
    table.insert(fs, "box[0," .. sy .. ";" .. W .. "," .. STATUS_H .. ";#1e1e1e]")
    local status = "File: " .. fn_esc .. "  |  Backend: " .. core.formspec_escape(storage.status(session)) .. "  |  Modified: " .. os.date("%H:%M", session.last_modified)
    if session.pending_proposal then status = status .. "  |  ★ PROPOSAL READY – click Apply" end
    local ctx_flags = {}
    if session.guiding_active  then ctx_flags[#ctx_flags+1] = "guide" end
    if session.assets_active   then ctx_flags[#ctx_flags+1] = "assets" end
    if session.api_level       then ctx_flags[#ctx_flags+1] = "api:" .. session.api_level end
    if session.last_run_output then ctx_flags[#ctx_flags+1] = "run-output" end
    if #ctx_flags > 0 then status = status .. "  |  ctx: " .. table.concat(ctx_flags, ", ") end
    table.insert(fs, "label[" .. PAD .. "," .. (sy + 0.22) .. ";" .. status .. "]")

    core.show_formspec(name, "llm_connect:ide", table.concat(fs))
end


-- ===========================================================================
-- File manager subformspec
-- ===========================================================================

function M.show_file_manager(name)
    if not can_use_ide(name) then return end
    local fm = _G.ide_file_manager
    if not fm or not fm.show then
        core.chat_send_player(name, "[LLM IDE] File manager module unavailable")
        return
    end
    local session = get_session(name)
    get_storage().ensure_session(session)
    fm.show(name, session)
end

local function handle_file_manager(name, fields)
    local fm = _G.ide_file_manager
    if not fm or not fm.handle_fields then
        core.chat_send_player(name, "[LLM IDE] File manager module unavailable")
        return true
    end
    local session = get_session(name)
    get_storage().ensure_session(session)
    return fm.handle_fields(name, fields, session, {
        show_ide = function(player_name) M.show(player_name) end,
    })
end
-- ===========================================================================
-- M.handle_fields
-- ===========================================================================

function M.handle_fields(name, formname, fields)
    if not can_use_ide(name) then
        core.chat_send_player(name, "[LLM] Missing privilege: llm_dev (or llm_root)")
        return true
    end

    -- Asset picker sub-formspec forwarding
    if formname:match("^llm_connect:ide_asset_picker") then
        local ap = _G.ide_asset_picker
        if ap then
            local result = ap.handle_fields(name, formname, fields)
            if fields.close_picker or fields.close_and_back or fields.quit then
                M.show(name)
            end
            return result
        end
        return false
    end

    if formname == "llm_connect:ide_file_manager" then
        return handle_file_manager(name, fields)
    end

    if not formname:match("^llm_connect:ide") then return false end

    local session = get_session(name)
    get_storage().ensure_session(session)
    local updated = false

    -- ── Code textarea sync ────────────────────────────────────
    local code_field = "code_" .. (session.code_rev or 0)
    if fields[code_field] then
        session.code          = fields[code_field]
        session.last_modified = os.time()
    end

    -- ── Prompt sync ───────────────────────────────────────────
    if fields.prompt_input then
        session.last_prompt = fields.prompt_input
    end

    -- ── Filename sync ─────────────────────────────────────────
    if fields.filename_input then
        session.filename = fields.filename_input
    end

    -- ── Backend / file-manager controls ───────────────────────
    if fields.backend_switch and is_root(name) then
        local storage = get_storage()
        session.persist_backend = storage.next_backend(name, session.persist_backend)
        session.file_list = storage.list(name, session)
        session.output = "Backend switched to: " .. storage.status(session)
        updated = true

    elseif fields.files_open then
        M.show_file_manager(name)
        return true

    -- ── Context toggles ───────────────────────────────────────
    elseif fields.guide_toggle ~= nil then
        session.guiding_active = fields.guide_toggle == "true"
        updated = true

    elseif fields.assets_toggle ~= nil then
        session.assets_active = fields.assets_toggle == "true"
        updated = true

    elseif fields.assets_open then
        local ap = _G.ide_asset_picker
        if ap then ap.show(name) end
        return true

    elseif fields.api_slim_toggle ~= nil then
        local on = fields.api_slim_toggle == "true"
        session.api_level = on and "slim" or nil
        updated = true

    elseif fields.api_full_toggle ~= nil then
        local on = fields.api_full_toggle == "true"
        session.api_level = on and "full" or nil
        updated = true

    -- ── File operations ───────────────────────────────────────
    elseif fields.file_load then
        local dd = fields.file_dropdown
        local target = dd and dd ~= "(no files)" and dd or nil
        if target then
            local content, read_err = get_storage().read(name, session, target)
            if content then
                session.code          = content
                session.code_rev      = (session.code_rev or 0) + 1
                session.filename      = target:match("([^/]+)$") or target
                session.selected_file = target
                session.last_modified = os.time()
                session.output        = "✓ Loaded: " .. target .. "\nBackend: " .. get_storage().status(session)
            else
                session.output = "✗ Could not read: " .. target
                    .. (read_err and ("\nError: " .. tostring(read_err)) or "")
                session.file_list = get_storage().list(name, session)
            end
        end
        updated = true

    elseif fields.file_save and is_root(name) then
        local ok, rel_or_err, classification = get_storage().save(name, session, session.code)
        if ok then
            session.output        = "✓ Saved: " .. tostring(rel_or_err)
                .. "\nBackend: " .. get_storage().status(session)
            local rt = _G.runtime_scripts or (_G.llm_connect and _G.llm_connect.runtime_scripts)
            if rt and rt.format_class_summary and classification then
                session.output = session.output .. "\n\n" .. rt.format_class_summary(classification)
            end
            session.last_modified = os.time()
            session.file_list     = get_storage().list(name, session)
            session.selected_file = tostring(rel_or_err)
        else
            session.output = "✗ Save failed: " .. tostring(rel_or_err)
        end
        updated = true

    elseif fields.file_new and is_root(name) then
        session.code             = DEFAULT_CODE
        session.code_rev         = (session.code_rev or 0) + 1
        session.filename         = "untitled.lua"
        session.last_modified    = os.time()
        session.pending_proposal = nil
        session.output           = "New file ready. Write code and save.\nBackend: " .. get_storage().status(session)
        updated = true

    -- ── Toolbar actions ───────────────────────────────────────
    elseif fields.syntax  then M.check_syntax(name);  return true
    elseif fields.analyze then M.analyze_code(name);  return true
    elseif fields.explain then M.explain_code(name);  return true

    elseif fields.generate and can_execute(name) then
        M.generate_code(name); return true

    elseif fields.run and can_execute(name) then
        M.run_code(name); return true

    elseif fields.hot_reload and is_root(name) and core.settings:get_bool("llm_ide_hot_reload", true) then
        M.hot_reload(name); return true

    elseif fields.auto_fix and can_execute(name) then
        M.auto_fix(name); return true

    elseif fields.apply then
        if session.pending_proposal then
            session.code             = session.pending_proposal
            session.code_rev         = (session.code_rev or 0) + 1
            session.pending_proposal = nil
            session.last_modified    = os.time()
            session.output           = "✓ Applied proposal to editor."
        else
            session.output = "No pending proposal to apply."
        end
        updated = true

    elseif fields.close_ide or fields.quit then
        -- 1.0: return to main_gui (was chat_gui in 0.9.0)
        local gui = _G.llm_connect and _G.llm_connect.gui
        if gui and gui.show then
            gui.show(name, "main")
        elseif _G.main_gui and _G.main_gui.show then
            _G.main_gui.show(name)
        else
            core.chat_send_player(name, "[LLM] Main GUI unavailable. Use /llm_health for details.")
        end
        return true
    end

    if updated then M.show(name) end
    return true
end

-- ===========================================================================
-- AI Actions
-- ===========================================================================

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
    get_api().code(p.SYNTAX_FIXER, session.code, function(result)
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
    get_api().code(p.SEMANTIC_ANALYZER, session.code, function(result)
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
    get_api().code(p.CODE_EXPLAINER, session.code, function(result)
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

    local p = get_prompts()
    local guide_addendum = (session.guiding_active and p.NAMING_GUIDE) and p.NAMING_GUIDE or ""

    local player     = core.get_player_by_name(name)
    local player_pos = player and player:get_pos() or nil
    local mod_list   = nil
    if core.settings:get_bool("llm_ide_context_mod_list", true) then
        local mods = core.get_modnames()
        if mods and #mods > 0 then mod_list = table.concat(mods, ", ") end
    end
    local asset_context = nil
    if session.assets_active then
        local ap = _G.ide_asset_picker
        if ap and ap.build_asset_context then asset_context = ap.build_asset_context(name) end
    end

    local ctx_block = p.build_context({
        filename      = session.filename,
        player_pos    = player_pos,
        mod_list      = mod_list,
        asset_context = asset_context,
        last_output   = session.last_run_output,
        api_level     = session.api_level,
    })

    local sys_msg = p.CODE_GENERATOR .. guide_addendum
    if ctx_block then sys_msg = sys_msg .. "\n\n" .. ctx_block end
    sys_msg = sys_msg .. "\n\nUser request: " .. user_req

    get_api().code(sys_msg, session.code, function(result)
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

    session.output     = "Executing… (please wait)"
    session.run_failed = false
    M.show(name)

    local exec_ctx = get_execution_ctx(name)
    local res = executor.execute(name, session.code, {
        sandbox  = (exec_ctx and exec_ctx.sandbox_enabled) ~= false,
        profile  = exec_ctx and exec_ctx.profile or nil,
        purpose  = "ide",
        precheck = true,
    })
    local pre_warn = res.precheck_warnings or ""

    if res.success then
        local out = "✓ Execution successful."
        if pre_warn ~= "" then out = out .. "\n\n⚠ Pre-check warnings:\n" .. pre_warn end
        out = out .. "\n\nOutput:\n" .. (res.output ~= "" and res.output or "(no output)")
        if res.return_value then out = out .. "\n\nReturn: " .. tostring(res.return_value) end
        if res.persisted    then out = out .. "\n\n→ Startup file updated (restart needed)" end
        session.output          = out
        session.last_run_output = out
        session.run_failed      = false
    else
        local err_out = "✗ Execution failed:\n" .. (res.error or "Unknown error")
        if res.output and res.output ~= "" then
            err_out = err_out .. "\n\nOutput before error:\n" .. res.output
        end
        session.output          = err_out
        session.last_run_output = err_out
        session.run_failed      = true
    end
    M.show(name)
end


function M.hot_reload(name)
    local session = get_session(name)
    local storage = get_storage()
    storage.ensure_session(session)
    session.output = "Saving + hot-reloading…"
    M.show(name)

    local res = storage.hot_reload(name, session, session.code)
    local rt = _G.runtime_scripts or (_G.llm_connect and _G.llm_connect.runtime_scripts)
    local summary = (rt and rt.format_class_summary and res.classification) and ("\n\n" .. rt.format_class_summary(res.classification)) or ""

    if res.success or res.saved then
        local out = "✓ Saved: " .. tostring(res.relpath or session.filename)
        if res.reloaded then
            out = out .. "\n✓ Hot reload executed."
            if res.output and res.output ~= "" then out = out .. "\n\nOutput:\n" .. res.output end
        else
            out = out .. "\n⚠ Not hot-reloaded: " .. tostring(res.message or res.error or "not runtime-safe")
        end
        session.output = out .. summary
        session.last_modified = os.time()
        session.file_list = storage.list(name, session)
        session.last_run_output = session.output
        session.run_failed = false
    else
        session.output = "✗ Hot reload failed:\n" .. tostring(res.error or "Unknown error") .. summary
        session.run_failed = true
    end
    M.show(name)
end

function M.auto_fix(name)
    local session  = get_session(name)
    local executor = get_executor()
    local api  = get_api()

    if not api or not api.is_configured() then
        session.output = "✗ Auto-Fix: LLM not configured"
        M.show(name); return
    end

    local max_iter = tonumber(core.settings:get("llm_ide_auto_fix_iterations")) or 3
    session.output     = ("Auto-Fix running… (max %d iterations)"):format(max_iter)
    session.run_failed = false
    M.show(name)

    local original_code = session.code
    local iter_log      = {}

    local exec_ctx = get_execution_ctx(name)

    executor.execute_with_retry(name, session.code, {
        sandbox        = (exec_ctx and exec_ctx.sandbox_enabled) ~= false,
        profile        = exec_ctx and exec_ctx.profile or nil,
        purpose        = "ide",
        max_iterations = max_iter,
        llm_request    = function(messages, cb)
            api.request(messages, cb, {timeout = api.get_timeout("ide")})
        end,
        on_iteration = function(iter, code, last_err)
            table.insert(iter_log, ("Iteration %d…"):format(iter))
            session.output = table.concat(iter_log, "\n")
            M.show(name)
        end,
        on_done = function(result, final_code)
            if final_code ~= original_code then
                session.code     = final_code
                session.code_rev = (session.code_rev or 0) + 1
            end
            if result.success then
                session.output = "✓ Auto-Fix succeeded!\n\nOutput:\n"
                    .. (result.output ~= "" and result.output or "(no output)")
                session.run_failed = false
            else
                local note = result.debug_loop_aborted and "(LLM stuck — same error repeated)" or ""
                session.output = "✗ Auto-Fix could not resolve the error. " .. note
                    .. "\n\n" .. (result.error or "")
                session.run_failed = true
            end
            session.last_run_output = session.output
            M.show(name)
        end,
    })
end

-- ===========================================================================

core.log("action", "[ide_gui] module loaded")

return M
