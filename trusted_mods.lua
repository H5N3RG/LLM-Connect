-- ===========================================================================
--  trusted_mods.lua — root-only trusted worldmod persistence backend (v1 stub)
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  This is intentionally conservative. It provides a storage backend for the
--  IDE switch without pretending full standalone-mod hot reload is safe.
-- ===========================================================================

local core = core
local M = {}

M.backend_name = "trusted_worldmod"

local path_policy = (_G.llm_connect and _G.llm_connect.path_policy) or _G.path_policy
local WORLD_DIR = path_policy and path_policy.world_path or core.get_worldpath()
local WORLDMODS_DIR = path_policy and path_policy.worldmods_dir() or (WORLD_DIR .. DIR_DELIM .. "worldmods")
local INSECURE_ENV = core.request_insecure_environment and core.request_insecure_environment() or nil

local function path_exists(path)
    if core.get_dir_list then
        local ok, result = pcall(core.get_dir_list, path, nil)
        if ok and result then return true end
    end
    local env_io = (INSECURE_ENV and INSECURE_ENV.io) or io
    if env_io then
        local f = env_io.open(path, "r")
        if f then f:close(); return true end
    end
    return false
end

local function shell_quote(path)
    path = tostring(path or "")
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

local function mkdir(path)
    -- Trusted worldmods live outside the normal mod write sandbox.  Never fall
    -- back to core.mkdir() here: with mod security enabled Luanti raises a hard
    -- security error for worldmods, which used to crash the server on browse.
    if not (INSECURE_ENV and INSECURE_ENV.os and INSECURE_ENV.os.execute) then
        return false, "trusted write unavailable: request_insecure_environment() returned nil; check secure.trusted_mods and startup config"
    end
    local ok, result = pcall(function()
        return INSECURE_ENV.os.execute("mkdir -p " .. shell_quote(path))
    end)
    if ok then
        return result == true or result == 0, nil
    end
    return false, tostring(result)
end

local function ensure_dir(path)
    local ok, err = mkdir(path)
    if not ok then return nil, err end
    return path
end

local function ensure_dir_tree(path)
    path = tostring(path or "")
    if path == "" then return false end
    local sep = DIR_DELIM or "/"
    local accum = ""
    if path:sub(1, 1) == sep then accum = sep end
    for part in path:gmatch("[^" .. sep .. "]+") do
        if accum == "" or accum == sep then accum = accum .. part else accum = accum .. sep .. part end
        local ok, err = mkdir(accum)
        if not ok then return false, err end
    end
    return true
end

local function dirname_rel(path)
    path = tostring(path or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
    return path:match("^(.*)/[^/]+$") or ""
end

local function safe_modname(modname)
    modname = tostring(modname or "llm_live_mod")
    modname = modname:gsub("[^%w_]", "_")
    if modname == "" then modname = "llm_live_mod" end
    return modname
end

local function safe_rel(path, default)
    path = tostring(path or default or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("/+$", "")
    path = path:gsub("/+", "/")
    if path:find("..", 1, true) then return nil, "Path traversal is not allowed" end
    if path:match("^/") then return nil, "Absolute paths are not allowed" end
    path = path:gsub("[^%w_%.%-%/]", "_")
    return path
end

local function safe_path(path)
    local clean, err = safe_rel(path, "init.lua")
    if not clean then return nil, err end
    if clean == "" then clean = "init.lua" end
    if not clean:match("%.lua$") and not clean:match("%.conf$") and not clean:match("%.md$") and not clean:match("%.txt$") then
        return nil, "Only .lua, .conf, .md, and .txt files are editable in trusted worldmod mode"
    end
    return clean
end
local function fs_io()
    return (INSECURE_ENV and INSECURE_ENV.io) or io
end

local function read_file(path)
    local ok, content_or_err, err2 = pcall(function()
        local f, err = fs_io().open(path, "r")
        if not f then return nil, err end
        local content = f:read("*a")
        f:close()
        return content
    end)
    if ok then return content_or_err, err2 end
    return nil, tostring(content_or_err)
end

local function write_file(path, content)
    if not INSECURE_ENV and core.safe_file_write then
        local ok, result = pcall(core.safe_file_write, path, content)
        if ok and result then return true end
    end
    local ok, result, err2 = pcall(function()
        local f, err = fs_io().open(path, "w")
        if not f then return false, err end
        f:write(content or "")
        f:close()
        return true
    end)
    if ok then return result, err2 end
    return false, tostring(result)
end

local function read_index(modname)
    local content = read_file(WORLDMODS_DIR .. DIR_DELIM .. modname .. DIR_DELIM .. "_llm_connect_index.txt")
    local files = {}
    if content then
        for line in content:gmatch("([^\n]+)") do
            line = line:match("^%s*(.-)%s*$")
            if line ~= "" then files[#files + 1] = line end
        end
    end
    if #files == 0 then files = {"init.lua", "mod.conf"} end
    table.sort(files)
    return files
end

local function write_index(modname, entries)
    local seen, out = {}, {}
    for _, entry in ipairs(entries or {}) do
        if entry ~= "" and not seen[entry] then seen[entry] = true; out[#out + 1] = entry end
    end
    table.sort(out)
    return write_file(WORLDMODS_DIR .. DIR_DELIM .. modname .. DIR_DELIM .. "_llm_connect_index.txt", table.concat(out, "\n"))
end

local function add_index(modname, relpath)
    local entries = read_index(modname)
    for _, entry in ipairs(entries) do if entry == relpath then return true end end
    entries[#entries + 1] = relpath
    return write_index(modname, entries)
end

function M.is_writable()
    return INSECURE_ENV ~= nil
end

function M.is_browsable()
    -- Browsing existing worldmods is safe/read-only. It should be allowed even
    -- when trusted write access is not granted, so the UI can explain the state
    -- instead of hiding/crashing the backend.
    if path_exists(WORLDMODS_DIR) then return true end
    return INSECURE_ENV ~= nil
end

function M.is_available()
    -- Backwards-compatible: available means the backend can at least be opened.
    return M.is_browsable()
end

function M.diagnostics()
    return {
        backend = M.backend_name,
        worldmods_dir = WORLDMODS_DIR,
        insecure_env = INSECURE_ENV ~= nil,
        browsable = M.is_browsable(),
        writable = M.is_writable(),
        secure_enable_security = core.settings and core.settings:get("secure.enable_security") or nil,
        secure_trusted_mods = core.settings and core.settings:get("secure.trusted_mods") or nil,
        current_modname = core.get_current_modname and core.get_current_modname() or nil,
    }
end

function M.diagnostics_text()
    local d = M.diagnostics()
    local lines = {
        "Trusted worldmod diagnostics:",
        "worldmods_dir=" .. tostring(d.worldmods_dir),
        "current_modname=" .. tostring(d.current_modname),
        "secure.enable_security=" .. tostring(d.secure_enable_security),
        "secure.trusted_mods=" .. tostring(d.secure_trusted_mods),
        "insecure_env=" .. tostring(d.insecure_env),
        "browsable=" .. tostring(d.browsable),
        "writable=" .. tostring(d.writable),
    }
    if not d.writable then
        lines[#lines + 1] = "Write disabled: add the real mod name to secure.trusted_mods and restart Luanti; browsing remains read-only."
    end
    return table.concat(lines, "\n")
end

function M.ensure_mod(modname)
    modname = safe_modname(modname)
    local ok, err = ensure_dir(WORLDMODS_DIR)
    if not ok then return nil, err or "Could not create worldmods directory" end
    ok, err = ensure_dir(WORLDMODS_DIR .. DIR_DELIM .. modname)
    if not ok then return nil, err or "Could not create worldmod directory" end
    local modconf = WORLDMODS_DIR .. DIR_DELIM .. modname .. DIR_DELIM .. "mod.conf"
    if not read_file(modconf) then
        local wrote, write_err = write_file(modconf, "name = " .. modname .. "\ndescription = LLM-Connect managed trusted worldmod\n")
        if not wrote then return nil, write_err end
    end
    return modname
end

local function collect_files(base, rel, out)
    out = out or {}
    rel = rel or ""
    local dir = rel == "" and base or (base .. DIR_DELIM .. rel:gsub("/", DIR_DELIM))
    if core.get_dir_list then
        for _, name in ipairs(core.get_dir_list(dir, false) or {}) do
            if name ~= "_llm_connect_index.txt" then
                out[#out + 1] = rel == "" and name or (rel .. "/" .. name)
            end
        end
        for _, name in ipairs(core.get_dir_list(dir, true) or {}) do
            if name ~= "." and name ~= ".." then
                collect_files(base, rel == "" and name or (rel .. "/" .. name), out)
            end
        end
    end
    return out
end

function M.list_files(modname)
    modname = safe_modname(modname)
    local base = WORLDMODS_DIR .. DIR_DELIM .. modname
    local files = collect_files(base, "", {})
    if #files > 0 then table.sort(files); return files end
    return read_index(modname)
end

function M.list_dir(modname, rel_dir)
    modname = safe_modname(modname)
    local clean, err = safe_rel(rel_dir or "")
    if not clean then return {} end
    local base = WORLDMODS_DIR .. DIR_DELIM .. modname
    local dir = clean == "" and base or (base .. DIR_DELIM .. clean:gsub("/", DIR_DELIM))
    local out = {}
    if clean ~= "" then out[#out + 1] = {type = "up", name = "..", path = dirname_rel(clean)} end
    if core.get_dir_list then
        for _, name in ipairs(core.get_dir_list(dir, true) or {}) do
            if name ~= "." and name ~= ".." then
                out[#out + 1] = {type = "dir", name = name, path = clean == "" and name or (clean .. "/" .. name)}
            end
        end
        for _, name in ipairs(core.get_dir_list(dir, false) or {}) do
            if name ~= "_llm_connect_index.txt" then
                out[#out + 1] = {type = "file", name = name, path = clean == "" and name or (clean .. "/" .. name)}
            end
        end
    end
    table.sort(out, function(a, b)
        local rank = {up = 0, dir = 1, file = 2}
        if a.type ~= b.type then return (rank[a.type] or 9) < (rank[b.type] or 9) end
        return tostring(a.name) < tostring(b.name)
    end)
    return out
end

function M.master_entries(modname)
    modname = safe_modname(modname)
    local out = {{type = "dir", name = "/", path = ""}}
    local base = WORLDMODS_DIR .. DIR_DELIM .. modname
    if core.get_dir_list then
        for _, name in ipairs(core.get_dir_list(base, true) or {}) do
            if name ~= "." and name ~= ".." then out[#out + 1] = {type = "dir", name = name, path = name} end
        end
    end
    return out
end

function M.make_dir(modname, rel_dir)
    local ensured, ensure_err = M.ensure_mod(modname)
    if not ensured then return false, ensure_err or "trusted_worldmod backend unavailable; add llm_connect to secure.trusted_mods" end
    modname = ensured
    local clean, err = safe_rel(rel_dir or "")
    if not clean or clean == "" then return false, err or "Invalid directory" end
    local full = WORLDMODS_DIR .. DIR_DELIM .. modname .. DIR_DELIM .. clean:gsub("/", DIR_DELIM)
    local ok, mk_err = ensure_dir_tree(full)
    if not ok then return false, mk_err end
    return true, clean
end

function M.read_file(modname, relpath)
    modname = safe_modname(modname)
    local clean, err = safe_path(relpath)
    if not clean then return nil, err end
    return read_file(WORLDMODS_DIR .. DIR_DELIM .. modname .. DIR_DELIM .. clean:gsub("/", DIR_DELIM))
end

function M.write_file(modname, relpath, content)
    local ensured, ensure_err = M.ensure_mod(modname)
    if not ensured then return false, ensure_err or "trusted_worldmod backend unavailable; add llm_connect to secure.trusted_mods" end
    modname = ensured
    local clean, err = safe_path(relpath)
    if not clean then return false, err end
    local full = WORLDMODS_DIR .. DIR_DELIM .. modname .. DIR_DELIM .. clean:gsub("/", DIR_DELIM)
    local parent = full:match("^(.*)" .. DIR_DELIM .. "[^" .. DIR_DELIM .. "]+$")
    if parent then
        local ok, mk_err = ensure_dir_tree(parent)
        if not ok then return false, mk_err end
    end
    local ok, write_err = write_file(full, content)
    if ok then add_index(modname, clean) end
    return ok, write_err or clean
end

function M.classify(modname, code)
    local runtime_scripts = _G.llm_connect and _G.llm_connect.runtime_scripts
    if runtime_scripts and runtime_scripts.classify then
        return runtime_scripts.classify(code, {mode = "trusted_worldmod", modname = safe_modname(modname)})
    end
    return {class = "unknown", hot_reloadable = false, persistable = true, requires_restart = true, issues = {"runtime_scripts classifier unavailable"}}
end

function M.reload_experimental(modname, relpath)
    return false, "Trusted worldmod hot-reload is intentionally disabled in v1. Save + restart is the supported path."
end

core.log("action", "[trusted_mods] backend loaded: " .. WORLDMODS_DIR .. (INSECURE_ENV and " (trusted/insecure env active)" or " (read-only/no insecure env)"))
if not INSECURE_ENV then
    core.log("warning", "[trusted_mods] write disabled. secure.trusted_mods=" .. tostring(core.settings and core.settings:get("secure.trusted_mods") or nil) .. ", current_modname=" .. tostring(core.get_current_modname and core.get_current_modname() or nil))
end

return M
