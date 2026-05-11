-- ===========================================================================
--  smart_lua_ide/ide_file_manager.lua — Smart Lua IDE file manager subformspec
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Three-panel textlist browser, intentionally modelled after the IDE asset
--  picker UX:
--    - master panel (left): backend roots / top-level anchors
--    - slave panel  (mid): current directory entries
--    - file view    (right): read-only preview + metadata
--
--  The backing storage is expected to use physical directory discovery
--  (core.get_dir_list where available) instead of only synthetic indexes.
-- ===========================================================================

local core = core
local M = {}

local MAX_PREVIEW_CHARS = 7000
local fm_sessions = {}

local function esc(s)
    return core.formspec_escape(tostring(s or ""))
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function get_storage()
    local st = _G.ide_storage
    if not st then error("[ide_file_manager] ide_storage unavailable") end
    return st
end

local function norm_path(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", "")
    path = path:gsub("/+$", "")
    path = path:gsub("/+", "/")
    if path:find("..", 1, true) then return "" end
    return path
end

local function join_path(a, b)
    a = norm_path(a)
    b = tostring(b or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
    if b == "" or b == "." then return a end
    if b == ".." then
        local p = a:match("^(.*)/[^/]+$")
        return p or ""
    end
    if a == "" then return b end
    return a .. "/" .. b
end

local function dirname(path)
    path = norm_path(path)
    local p = path:match("^(.*)/[^/]+$")
    return p or ""
end

local function basename(path)
    path = tostring(path or "")
    return path:match("([^/]+)$") or path
end

local function short_label(s, max)
    s = tostring(s or "")
    max = max or 32
    if #s <= max then return s end
    return s:sub(1, max - 1) .. "…"
end

local function file_type(path)
    local lower = tostring(path or ""):lower()
    if lower:match("%.lua$") then return "Lua" end
    if lower:match("%.conf$") then return "Conf" end
    if lower:match("%.md$") then return "Markdown" end
    if lower:match("%.txt$") then return "Text" end
    return "File"
end

local function get_fm(name)
    if not fm_sessions[name] then
        fm_sessions[name] = {
            dir = "",
            selected_path = nil,
            selected_type = nil,
            preview = "Select a file to preview it.",
            status = "Ready.",
            master_idx = 1,
            slave_idx = 1,
            filter = "",
        }
    end
    return fm_sessions[name]
end

core.register_on_leaveplayer(function(player)
    fm_sessions[player:get_player_name()] = nil
end)

local function textlist_event(value)
    value = tostring(value or "")
    local action, idx = value:match("^([A-Z]+):(%d+)")
    return action, tonumber(idx or "0") or 0
end

local function textlist_items(entries, selected_path)
    local out = {}
    for _, entry in ipairs(entries or {}) do
        local prefix
        if entry.type == "up" then prefix = "↩ "
        elseif entry.type == "dir" then prefix = "▸ "
        else prefix = "  " end
        local suffix = entry.type == "file" and ("  [" .. file_type(entry.name) .. "]") or ""
        local label = prefix .. short_label(entry.name or entry.path or "?", 42) .. suffix
        if selected_path and selected_path == entry.path then label = "● " .. label else label = "  " .. label end
        out[#out + 1] = esc(label)
    end
    if #out == 0 then out[#out + 1] = esc("  (empty)") end
    return table.concat(out, ",")
end

local function master_entries(name, ide_session)
    local storage = get_storage()
    local roots = storage.master_entries and storage.master_entries(name, ide_session) or nil
    if roots and #roots > 0 then return roots end

    if ide_session.persist_backend == "llm_runtime" then
        return {
            {type = "dir", name = "/", path = ""},
            {type = "dir", name = "runtime", path = "runtime"},
            {type = "dir", name = "sticky", path = "sticky"},
            {type = "dir", name = "startup", path = "startup"},
            {type = "dir", name = "disabled", path = "disabled"},
        }
    end
    return {{type = "dir", name = "/", path = ""}}
end

local function filtered_entries(entries, filter)
    filter = trim(filter):lower()
    if filter == "" then return entries end
    local out = {}
    for _, e in ipairs(entries or {}) do
        local hay = (tostring(e.name or "") .. " " .. tostring(e.path or "")):lower()
        if e.type == "up" or hay:find(filter, 1, true) then out[#out + 1] = e end
    end
    return out
end

local function load_entries(name, ide_session, fm)
    local storage = get_storage()
    local entries = storage.list_dir and storage.list_dir(name, ide_session, fm.dir) or {}
    entries = filtered_entries(entries, fm.filter)
    fm._master = master_entries(name, ide_session)
    fm._entries = entries
    return entries
end

local function preview_file(name, ide_session, fm, relpath)
    local storage = get_storage()
    local content, err = storage.read_path and storage.read_path(name, ide_session, relpath)
        or storage.read(name, ide_session, relpath)
    if not content then
        fm.preview = "Could not read file:\n" .. tostring(err or "unknown error")
        return nil, err
    end
    local p = tostring(content)
    if #p > MAX_PREVIEW_CHARS then
        p = p:sub(1, MAX_PREVIEW_CHARS) .. "\n\n-- [preview truncated]"
    end
    fm.preview = p
    return content
end

local function select_entry(name, ide_session, fm, entry, open_now)
    if not entry then return end
    if entry.type == "up" then
        fm.dir = norm_path(entry.path)
        ide_session.current_dir = fm.dir
        fm.selected_path = nil
        fm.selected_type = nil
        fm.preview = "Directory: /" .. fm.dir
        fm.status = "Directory: /" .. fm.dir
        return
    end

    fm.selected_path = entry.path
    fm.selected_type = entry.type
    if entry.type == "dir" then
        fm.preview = "Folder: /" .. entry.path .. "\n\nDouble-click or press Open to enter."
        fm.status = "Selected folder: /" .. entry.path
        if open_now then
            fm.dir = norm_path(entry.path)
            ide_session.current_dir = fm.dir
            fm.selected_path = nil
            fm.selected_type = nil
            fm.preview = "Directory: /" .. fm.dir
            fm.status = "Directory: /" .. fm.dir
        end
    else
        preview_file(name, ide_session, fm, entry.path)
        fm.status = "Selected file: /" .. entry.path
    end
end

local function open_selected(name, ide_session, fm)
    if not fm.selected_path then
        fm.status = "No entry selected."
        return "stay"
    end
    if fm.selected_type == "dir" then
        fm.dir = norm_path(fm.selected_path)
        ide_session.current_dir = fm.dir
        fm.selected_path = nil
        fm.selected_type = nil
        fm.preview = "Directory: /" .. fm.dir
        fm.status = "Opened directory."
        return "stay"
    end
    local content, err = preview_file(name, ide_session, fm, fm.selected_path)
    if not content then
        fm.status = "Open failed: " .. tostring(err)
        return "stay"
    end
    ide_session.code = content
    ide_session.code_rev = (ide_session.code_rev or 0) + 1
    ide_session.filename = fm.selected_path
    ide_session.selected_file = fm.selected_path
    ide_session.current_dir = dirname(fm.selected_path)
    ide_session.output = "✓ Loaded from file manager: " .. fm.selected_path .. "\nBackend: " .. get_storage().status(ide_session)
    fm.status = "Opened into IDE."
    return "ide"
end

local function attach_selected(name, ide_session, fm)
    if not fm.selected_path or fm.selected_type ~= "file" then
        fm.status = "Select a file before attaching to IDE."
        return "stay"
    end
    local content, err = preview_file(name, ide_session, fm, fm.selected_path)
    if not content then
        fm.status = "Attach failed: " .. tostring(err)
        return "stay"
    end
    ide_session.code = content
    ide_session.code_rev = (ide_session.code_rev or 0) + 1
    ide_session.filename = fm.selected_path
    ide_session.selected_file = fm.selected_path
    ide_session.current_dir = dirname(fm.selected_path)
    ide_session.output = "✓ Attached: " .. fm.selected_path .. "\nBackend: " .. get_storage().status(ide_session)
    fm.status = "Attached to IDE."
    return "ide"
end

local function build_header(fs, name, ide_session, storage)
    table.insert(fs, "box[0,0;18.4,0.9;#1a1a2e]")
    table.insert(fs, "label[0.35,0.35;File Manager — Smart Lua IDE]")
    table.insert(fs, "label[10.6,0.35;Backend: " .. esc(storage.status(ide_session)) .. "]")
    if ide_session.persist_backend == "trusted_worldmod" then
        table.insert(fs, "field[15.15,0.22;2.05,0.55;fm_modname;;" .. esc(ide_session.active_modname or "llm_live_mod") .. "]")
        table.insert(fs, "field_close_on_enter[fm_modname;false]")
    end
end

function M.show(name, ide_session)
    local storage = get_storage()
    storage.ensure_session(ide_session)
    local fm = get_fm(name)
    fm.dir = norm_path(fm.dir or ide_session.current_dir or "")
    local entries = load_entries(name, ide_session, fm)
    local masters = fm._master or {}

    local selected_slave = 1
    for i, e in ipairs(entries) do
        if e.path == fm.selected_path then selected_slave = i; break end
    end
    local selected_master = 1
    for i, e in ipairs(masters) do
        if e.path == fm.dir then selected_master = i; break end
    end
    fm.master_idx = selected_master
    fm.slave_idx = selected_slave

    local fs = {
        "formspec_version[6]",
        "size[18.4,10.4]",
        "bgcolor[#0d0d0d;both]",
        "style_type[*;bgcolor=#181818;textcolor=#e0e0e0;font=mono]",
        "style_type[button;border=true]",
        "style_type[textlist;bgcolor=#101018;textcolor=#e8e8e8]",
    }

    build_header(fs, name, ide_session, storage)

    table.insert(fs, "label[0.35,1.12;Master Browse]")
    table.insert(fs, "label[4.35,1.12;Folder: /" .. esc(fm.dir) .. "]")
    table.insert(fs, "label[10.8,1.12;File View]")

    table.insert(fs, "textlist[0.35,1.45;3.65,7.25;fm_master_list;" .. textlist_items(masters, fm.dir) .. ";" .. selected_master .. ";false]")
    table.insert(fs, "field[4.35,1.20;4.25,0.55;fm_filter;;" .. esc(fm.filter or "") .. "]")
    table.insert(fs, "field_close_on_enter[fm_filter;false]")
    table.insert(fs, "button[8.75,1.20;1.55,0.55;fm_apply_filter;Search]")
    table.insert(fs, "textlist[4.35,1.85;6.05,6.85;fm_slave_list;" .. textlist_items(entries, fm.selected_path) .. ";" .. selected_slave .. ";false]")

    local title = fm.selected_path and (basename(fm.selected_path) .. "  [" .. tostring(fm.selected_type) .. "]") or "No file selected"
    table.insert(fs, "box[10.75,1.45;7.25,7.25;#111111]")
    table.insert(fs, "label[11.0,1.72;" .. esc(short_label(title, 70)) .. "]")
    table.insert(fs, "textarea[11.0,2.10;6.75,6.15;fm_preview;;" .. esc(fm.preview or "") .. "]")
    local info = fm.selected_path and ("/" .. fm.selected_path .. " — " .. file_type(fm.selected_path)) or "Select a file or folder from the middle panel."
    table.insert(fs, "label[11.0,8.35;" .. esc(short_label(info, 82)) .. "]")

    table.insert(fs, "label[0.35,8.92;" .. esc(fm.status or "Ready.") .. "]")
    table.insert(fs, "button[0.35,9.35;1.45,0.55;fm_up;Up]")
    table.insert(fs, "button[2.0,9.35;1.45,0.55;fm_open;Open]")
    table.insert(fs, "style[fm_attach;bgcolor=#2a4a6a;textcolor=#ffffff]")
    table.insert(fs, "button[3.65,9.35;2.20,0.55;fm_attach;Attach to IDE]")
    table.insert(fs, "button[6.05,9.35;1.75,0.55;fm_new_file;New File]")
    table.insert(fs, "button[8.0,9.35;1.90,0.55;fm_new_folder;New Folder]")
    table.insert(fs, "button[10.10,9.35;1.50,0.55;fm_rename;Rename]")
    table.insert(fs, "button[11.80,9.35;1.50,0.55;fm_delete;Delete]")
    table.insert(fs, "button[13.50,9.35;2.35,0.55;fm_diag;Diagnostics]")
    table.insert(fs, "button[16.25,9.35;1.50,0.55;fm_back;Back]")

    core.show_formspec(name, "llm_connect:ide_file_manager", table.concat(fs))
end

function M.handle_fields(name, fields, ide_session, callbacks)
    callbacks = callbacks or {}
    local storage = get_storage()
    storage.ensure_session(ide_session)
    local fm = get_fm(name)

    if fields.fm_modname and ide_session.persist_backend == "trusted_worldmod" then
        ide_session.active_modname = trim(fields.fm_modname):gsub("[^%w_]", "_")
        if ide_session.active_modname == "" then ide_session.active_modname = "llm_live_mod" end
        fm.dir = ""
        fm.selected_path = nil
        fm.selected_type = nil
        fm.preview = "Switched active worldmod."
        fm.status = "Active mod: " .. ide_session.active_modname
    end

    if fields.fm_filter then fm.filter = fields.fm_filter end

    if fields.fm_back or fields.quit then
        if callbacks.show_ide then callbacks.show_ide(name) end
        return true
    end

    if fields.fm_apply_filter then
        fm.status = fm.filter ~= "" and ("Filter: " .. fm.filter) or "Filter cleared."
        M.show(name, ide_session)
        return true
    end

    if fields.fm_diag then
        local tm = _G.llm_connect and _G.llm_connect.trusted_mods
        if ide_session.persist_backend == "trusted_worldmod" and tm and tm.diagnostics_text then
            fm.preview = tm.diagnostics_text()
            fm.status = "Trusted backend diagnostics shown."
        else
            fm.preview = "Backend: " .. tostring(storage.status(ide_session)) .. "\nNo trusted diagnostics for this backend."
            fm.status = "Backend diagnostics shown."
        end
        M.show(name, ide_session)
        return true
    end

    if fields.fm_up then
        fm.dir = dirname(fm.dir)
        ide_session.current_dir = fm.dir
        fm.selected_path = nil
        fm.selected_type = nil
        fm.preview = "Directory: /" .. fm.dir
        fm.status = "Directory: /" .. fm.dir
        M.show(name, ide_session)
        return true
    end

    if fields.fm_master_list then
        local action, idx = textlist_event(fields.fm_master_list)
        if idx > 0 and fm._master and fm._master[idx] then
            local entry = fm._master[idx]
            fm.dir = norm_path(entry.path)
            ide_session.current_dir = fm.dir
            fm.selected_path = nil
            fm.selected_type = nil
            fm.preview = "Directory: /" .. fm.dir
            fm.status = "Directory: /" .. fm.dir
            M.show(name, ide_session)
            return true
        end
    end

    if fields.fm_slave_list then
        local action, idx = textlist_event(fields.fm_slave_list)
        if idx > 0 and fm._entries and fm._entries[idx] then
            select_entry(name, ide_session, fm, fm._entries[idx], action == "DCL")
            M.show(name, ide_session)
            return true
        end
    end

    if fields.fm_open then
        local result = open_selected(name, ide_session, fm)
        if result == "ide" and callbacks.show_ide then callbacks.show_ide(name) else M.show(name, ide_session) end
        return true
    elseif fields.fm_attach then
        local result = attach_selected(name, ide_session, fm)
        if result == "ide" and callbacks.show_ide then callbacks.show_ide(name) else M.show(name, ide_session) end
        return true
    elseif fields.fm_new_file then
        local target = join_path(fm.dir, "untitled.lua")
        ide_session.code = "-- New Lua file\n"
        ide_session.code_rev = (ide_session.code_rev or 0) + 1
        ide_session.filename = target
        ide_session.current_dir = fm.dir
        ide_session.output = "New file staged from file manager. Edit in IDE, then Save."
        if callbacks.show_ide then callbacks.show_ide(name) end
        return true
    elseif fields.fm_new_folder then
        local ok, err = storage.make_dir and storage.make_dir(name, ide_session, join_path(fm.dir, "new_folder"))
        if ok then
            fm.status = "Created folder: /" .. join_path(fm.dir, "new_folder")
        else
            fm.status = "New folder failed: " .. tostring(err or "backend does not support mkdir")
        end
        M.show(name, ide_session)
        return true
    elseif fields.fm_rename then
        fm.status = "Rename UI placeholder: select file, then save under a new filename in IDE."
        M.show(name, ide_session)
        return true
    elseif fields.fm_delete then
        if not fm.selected_path or fm.selected_type ~= "file" then
            fm.status = "Select a file to delete."
        else
            local ok, err = storage.delete(name, ide_session, fm.selected_path)
            fm.status = ok and ("Deleted: /" .. fm.selected_path) or ("Delete failed: " .. tostring(err))
            if ok then
                fm.selected_path = nil
                fm.selected_type = nil
                fm.preview = "Deleted."
            end
        end
        M.show(name, ide_session)
        return true
    end

    return false
end

core.log("action", "[ide_file_manager] textlist module loaded")

return M
