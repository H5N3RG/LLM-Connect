-- ===========================================================================
--  smart_lua_ide/ide_storage.lua — persistence backend bridge for Smart Lua IDE
-- ===========================================================================

local core = core
local M = {}

local function get_policy()
    return _G.llm_connect and _G.llm_connect.policy
end

local function is_root(name)
    local p = get_policy()
    if p and p.is_root then return p.is_root(name) end
    local privs = core.get_player_privs(name) or {}
    return privs.llm_root == true
end

local function runtime_backend()
    return _G.llm_connect and _G.llm_connect.runtime_scripts
end

local function trusted_backend()
    return _G.llm_connect and _G.llm_connect.trusted_mods
end

local function normalize_filename(filename)
    filename = tostring(filename or "untitled.lua"):gsub("\\", "/")
    filename = filename:gsub("^/+", ""):gsub("/+$", "")
    filename = filename:gsub("[^%w_%.%-%/]", "_")
    filename = filename:gsub("/+", "/")
    if filename:find("..", 1, true) then filename = "untitled.lua" end
    if filename == "" then filename = "untitled.lua" end
    if not filename:match("%.lua$") and not filename:match("%.conf$") and not filename:match("%.md$") and not filename:match("%.txt$") then
        filename = filename .. ".lua"
    end
    return filename
end

local function normalize_relpath(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("/+$", "")
    path = path:gsub("[^%w_%.%-%/]", "_")
    if path:find("%.%.", 1, true) then return "" end
    return path
end

local function dirname(path)
    path = normalize_relpath(path)
    return path:match("^(.*)/[^/]+$") or ""
end

local function basename(path)
    path = tostring(path or "")
    return path:match("([^/\\]+)$") or path
end

local function split_first(path)
    path = normalize_relpath(path)
    local first, rest = path:match("^([^/]+)/(.+)$")
    return first or path, rest
end

local function sort_entries(entries)
    table.sort(entries, function(a, b)
        if a.type ~= b.type then return a.type == "dir" end
        return tostring(a.name) < tostring(b.name)
    end)
    return entries
end

function M.default_backend()
    return "llm_runtime"
end

function M.can_switch_backend(player_name)
    if not is_root(player_name) then return false end
    if not core.settings:get_bool("llm_ide_trusted_worldmod_backend", true) then return false end
    local tm = trusted_backend()
    if not tm then return false end
    if tm.is_browsable then return tm.is_browsable() end
    return tm.is_available and tm.is_available()
end

function M.next_backend(player_name, current)
    if not M.can_switch_backend(player_name) then return "llm_runtime" end
    if current == "trusted_worldmod" then return "llm_runtime" end
    return "trusted_worldmod"
end

function M.backend_label(backend)
    if backend == "trusted_worldmod" then return "Trusted Worldmod" end
    return "LLM Runtime"
end

function M.ensure_session(session)
    session.persist_backend = session.persist_backend or "llm_runtime"
    session.active_modname = session.active_modname or "llm_live_mod"
    session.current_dir = session.current_dir or ""
    session.filename = session.filename or "untitled.lua"
    return session
end

function M.list(player_name, session)
    M.ensure_session(session)
    if session.persist_backend == "trusted_worldmod" then
        if not is_root(player_name) then return {} end
        local tm = trusted_backend()
        if not tm or (tm.is_browsable and not tm.is_browsable()) or (not tm.is_browsable and tm.is_available and not tm.is_available()) then return {} end
        return tm.list_files(session.active_modname)
    end
    local rt = runtime_backend()
    if not rt then return {} end
    return rt.list_scripts(player_name)
end

function M.read(player_name, session, entry)
    M.ensure_session(session)
    if session.persist_backend == "trusted_worldmod" then
        if not is_root(player_name) then return nil, "Trusted worldmod backend is root-only" end
        local tm = trusted_backend()
        if not tm or (tm.is_browsable and not tm.is_browsable()) or (not tm.is_browsable and tm.is_available and not tm.is_available()) then return nil, "trusted_worldmod backend unavailable or worldmods missing" end
        return tm.read_file(session.active_modname, entry)
    end
    local rt = runtime_backend()
    if not rt then return nil, "runtime_scripts backend unavailable" end
    return rt.read_script(player_name, entry)
end

function M.save(player_name, session, code)
    M.ensure_session(session)
    local raw_filename = session.filename or "untitled.lua"
    local filename = normalize_filename(raw_filename)
    session.filename = filename

    if session.persist_backend == "trusted_worldmod" then
        if not is_root(player_name) then return false, "Trusted worldmod backend is root-only" end
        local tm = trusted_backend()
        if not tm or not tm.is_writable or not tm.is_writable() then
            local diag = tm and tm.diagnostics_text and tm.diagnostics_text() or "trusted_worldmod write unavailable"
            return false, diag
        end
        local ok, err_or_path = tm.write_file(session.active_modname, filename, code)
        local classification = tm.classify(session.active_modname, code)
        return ok, err_or_path, classification
    end

    local rt = runtime_backend()
    if not rt then return false, "runtime_scripts backend unavailable" end

    local folder = nil
    local raw = normalize_relpath(raw_filename or filename)
    local first, rest = split_first(raw)
    if first == "runtime" or first == "sticky" or first == "startup" or first == "disabled" then
        folder = first
        filename = normalize_filename(rest or filename)
    elseif session.current_dir == "runtime" or session.current_dir == "sticky"
        or session.current_dir == "startup" or session.current_dir == "disabled" then
        folder = session.current_dir
    end

    return rt.save_script(player_name, filename, code, {enabled = false, folder = folder})
end

function M.hot_reload(player_name, session, code)
    M.ensure_session(session)
    local raw_filename = session.filename or "untitled.lua"
    local filename = normalize_filename(raw_filename)
    session.filename = filename

    if session.persist_backend == "trusted_worldmod" then
        return {
            ok = false,
            success = false,
            error = "Trusted worldmod hot-reload is disabled in v1. Save the file and restart the world/server.",
            classification = trusted_backend() and trusted_backend().classify(session.active_modname, code) or nil,
        }
    end

    local rt = runtime_backend()
    if not rt then return {ok = false, success = false, error = "runtime_scripts backend unavailable"} end

    local folder = nil
    local raw = normalize_relpath(raw_filename or filename)
    local first, rest = split_first(raw)
    if first == "runtime" or first == "sticky" or first == "startup" or first == "disabled" then
        folder = first
        filename = normalize_filename(rest or filename)
    elseif session.current_dir == "runtime" or session.current_dir == "sticky"
        or session.current_dir == "startup" or session.current_dir == "disabled" then
        folder = session.current_dir
    end

    return rt.hot_reload(player_name, filename, code, {enabled = true, purpose = "ide", folder = folder})
end

function M.delete(player_name, session, entry)
    M.ensure_session(session)
    if session.persist_backend == "trusted_worldmod" then
        return false, "Delete is disabled for trusted worldmods in v1"
    end
    local rt = runtime_backend()
    if not rt then return false, "runtime_scripts backend unavailable" end
    return rt.delete_script(player_name, entry)
end


function M.read_path(player_name, session, relpath)
    return M.read(player_name, session, relpath)
end

function M.list_dir(player_name, session, dir)
    M.ensure_session(session)
    dir = normalize_relpath(dir)

    if session.persist_backend == "trusted_worldmod" then
        if not is_root(player_name) then return {} end
        local tm = trusted_backend()
        if tm and tm.list_dir and ((tm.is_browsable and tm.is_browsable()) or (tm.is_available and tm.is_available())) then
            return tm.list_dir(session.active_modname, dir)
        end
    else
        local rt = runtime_backend()
        if rt and rt.list_dir then return rt.list_dir(player_name, dir) end
    end

    local flat = M.list(player_name, session) or {}
    local entries, seen_dirs, seen_files = {}, {}, {}

    local function add_dir(name, path)
        if name == "" or seen_dirs[path] then return end
        seen_dirs[path] = true
        entries[#entries + 1] = {type = "dir", name = name, path = path}
    end

    local function add_file(name, path)
        if name == "" or seen_files[path] then return end
        seen_files[path] = true
        entries[#entries + 1] = {type = "file", name = name, path = path}
    end

    if dir ~= "" then
        add_dir("..", dirname(dir))
    elseif session.persist_backend == "llm_runtime" then
        -- Show the physical/class buckets even before any file exists.
        add_dir("runtime", "runtime")
        add_dir("sticky", "sticky")
        add_dir("startup", "startup")
        add_dir("disabled", "disabled")
    end

    for _, rel in ipairs(flat) do
        rel = normalize_relpath(rel)
        local parent = dirname(rel)
        if parent == dir then
            add_file(basename(rel), rel)
        elseif dir == "" then
            local first = rel:match("^([^/]+)/")
            if first then add_dir(first, first) end
        elseif rel:sub(1, #dir + 1) == dir .. "/" then
            local rest = rel:sub(#dir + 2)
            local child = rest:match("^([^/]+)/")
            if child then add_dir(child, dir .. "/" .. child) end
        end
    end

    return sort_entries(entries)
end

function M.tree_entries(player_name, session)
    M.ensure_session(session)
    local flat = M.list(player_name, session) or {}
    local out = {{label = "/", path = "", depth = 0, icon = "[D]"}}
    local seen = { [""] = true }

    local function add(path)
        path = normalize_relpath(path)
        if path == "" or seen[path] then return end
        seen[path] = true
        local depth = 0
        for _ in path:gmatch("/") do depth = depth + 1 end
        out[#out + 1] = {label = basename(path) .. "/", path = path, depth = depth + 1, icon = "[D]"}
    end

    if session.persist_backend == "llm_runtime" then
        add("runtime"); add("sticky"); add("startup"); add("disabled")
    end

    for _, rel in ipairs(flat) do
        rel = normalize_relpath(rel)
        local accum = ""
        for part in rel:gmatch("[^/]+") do
            if rel:match("/" .. part .. "$") or rel == part then break end
            accum = accum == "" and part or (accum .. "/" .. part)
            add(accum)
        end
    end

    table.sort(out, function(a, b)
        if a.path == "" then return true end
        if b.path == "" then return false end
        return a.path < b.path
    end)
    return out
end

function M.master_entries(player_name, session)
    M.ensure_session(session)
    if session.persist_backend == "trusted_worldmod" then
        if not is_root(player_name) then return {} end
        local tm = trusted_backend()
        if tm and tm.master_entries and ((tm.is_browsable and tm.is_browsable()) or (tm.is_available and tm.is_available())) then
            return tm.master_entries(session.active_modname)
        end
        return {{type = "dir", name = "/", path = ""}}
    end
    local rt = runtime_backend()
    if rt and rt.master_entries then return rt.master_entries(player_name) end
    return {{type = "dir", name = "/", path = ""}}
end

function M.make_dir(player_name, session, rel_dir)
    M.ensure_session(session)
    rel_dir = normalize_relpath(rel_dir)
    if rel_dir == "" then return false, "Invalid directory" end
    if session.persist_backend == "trusted_worldmod" then
        if not is_root(player_name) then return false, "Trusted worldmod backend is root-only" end
        local tm = trusted_backend()
        if not tm or not tm.is_writable or not tm.is_writable() then
            return false, tm and tm.diagnostics_text and tm.diagnostics_text() or "trusted_worldmod write unavailable"
        end
        if tm and tm.make_dir then return tm.make_dir(session.active_modname, rel_dir) end
        return false, "trusted_worldmod backend does not support mkdir"
    end
    local rt = runtime_backend()
    if rt and rt.make_dir then return rt.make_dir(player_name, rel_dir) end
    return false, "runtime_scripts backend does not support mkdir"
end

function M.status(session)
    M.ensure_session(session)
    local label = M.backend_label(session.persist_backend)
    if session.persist_backend == "trusted_worldmod" then
        local tm = trusted_backend()
        local mode = (tm and tm.is_writable and tm.is_writable()) and "rw" or "ro"
        return label .. " / " .. tostring(session.active_modname or "llm_live_mod") .. " [" .. mode .. "]"
    end
    return label
end

return M
