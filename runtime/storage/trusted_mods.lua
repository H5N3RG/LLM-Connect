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

local root = rawget(_G, "llm_connect")
local path_policy = (root and root.path_policy) or rawget(_G, "path_policy")
local storage_fs = (root and root.storage_backends) or rawget(_G, "storage_backends")
local WORLD_DIR = path_policy and path_policy.world_path or core.get_worldpath()
local WORLDMODS_DIR = path_policy and path_policy.worldmods_dir() or (WORLD_DIR .. DIR_DELIM .. "worldmods")
local INSECURE_ENV = nil
local INSECURE_ENV_REQUESTED = false

local function get_insecure_env()
    if not INSECURE_ENV_REQUESTED then
        INSECURE_ENV_REQUESTED = true
        if core.request_insecure_environment then
            local ok, env = pcall(core.request_insecure_environment)
            if ok and type(env) == "table" then INSECURE_ENV = env end
        end
    end
    return INSECURE_ENV
end

local function current_modname()
    return core.get_current_modname and core.get_current_modname() or "llm_connect"
end

local function trusted_setting_contains_current()
    local setting = core.settings and core.settings:get("secure.trusted_mods") or ""
    local current = current_modname()
    for token in tostring(setting or ""):gmatch("[^,%s]+") do
        if token == current then return true end
    end
    return false
end

local function path_exists(path)
    if storage_fs and storage_fs.path_exists then
        local ok = storage_fs.path_exists(path, "trusted_mods")
        if ok then return true end
    elseif core.get_dir_list then
        local ok, result = pcall(core.get_dir_list, path, nil)
        if ok and result then return true end
    end
    local env = get_insecure_env()
    local env_io = env and env.io
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
    if path_exists(path) then return true, nil end

    -- First try Luanti's own directory helper under pcall.  On some builds this
    -- is sufficient for world-owned paths even when no insecure environment is
    -- exposed.  A security failure must become a normal backend error, not a
    -- server crash.
    if core.mkdir then
        local ok, result = pcall(core.mkdir, path)
        if ok and result then return true, nil end
        if path_exists(path) then return true, nil end
    end

    local env = get_insecure_env()
    if not (env and env.os and env.os.execute) then
        return false, "trusted write unavailable: request_insecure_environment() returned nil; secure.trusted_mods contains current mod=" .. tostring(trusted_setting_contains_current())
    end
    local ok, result = pcall(function()
        return env.os.execute("mkdir -p " .. shell_quote(path))
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
    if path == "" then return false, "missing path" end
    local sep = DIR_DELIM or "/"
    local base = tostring(WORLDMODS_DIR or ""):gsub("[/\\]+$", "")
    local rel

    if base ~= "" and path == base then
        return mkdir(base)
    elseif base ~= "" and path:sub(1, #base + 1) == base .. sep then
        rel = path:sub(#base + 2)
    elseif path:sub(1, 1) == sep then
        return false, "refusing to create directory outside worldmods root: " .. path
    else
        rel = path
    end

    local ok, err = mkdir(base ~= "" and base or ".")
    if not ok then return false, err end

    local accum = base ~= "" and base or ""
    for part in rel:gmatch("[^" .. sep .. "]+") do
        if accum == "" then accum = part else accum = accum .. sep .. part end
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
    local env = get_insecure_env()
    return env and env.io or nil
end

local function read_file(path)
    local env_io = fs_io() or io
    if not env_io then return nil, "trusted read unavailable: no readable file API" end
    local ok, content_or_err, err2 = pcall(function()
        local f, err = env_io.open(path, "r")
        if not f then return nil, err end
        local content = f:read("*a")
        f:close()
        return content
    end)
    if ok then return content_or_err, err2 end
    return nil, tostring(content_or_err)
end

local function write_file(path, content)
    if not get_insecure_env() and core.safe_file_write then
        local ok, result = pcall(core.safe_file_write, path, content)
        if ok and result then return true end
    end
    local env_io = fs_io()
    if not env_io then return false, "trusted write unavailable: insecure environment unavailable and safe_file_write failed" end
    local ok, result, err2 = pcall(function()
        local f, err = env_io.open(path, "w")
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
            local clean_line = line:match("^%s*(.-)%s*$")
            if clean_line ~= "" then files[#files + 1] = clean_line end
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

local function has_luanti_write_helpers()
    return core.mkdir ~= nil and core.safe_file_write ~= nil
end

function M.capabilities()
    local env = get_insecure_env()
    local has_insecure_env = type(env) == "table"
    local has_mkdir = core.mkdir ~= nil
    local has_safe_write = core.safe_file_write ~= nil
    local worldmods_exists = path_exists(WORLDMODS_DIR)
    local can_attempt_write = has_insecure_env or (has_mkdir and has_safe_write)
    local write_mode = "unavailable"
    local reason = nil

    if has_insecure_env then
        write_mode = "trusted_insecure_env"
    elseif has_mkdir and has_safe_write then
        write_mode = "safe_helper_attempt"
        reason = "Luanti safe write helpers are present; the final engine write decides whether this path is accepted."
    else
        reason = "request_insecure_environment() returned nil and Luanti safe write helpers are unavailable"
    end

    return {
        backend = M.backend_name,
        worldmods_dir = WORLDMODS_DIR,
        worldmods_exists = worldmods_exists,
        current_modname = current_modname(),
        secure_enable_security = core.settings and core.settings:get("secure.enable_security") or nil,
        secure_trusted_mods = core.settings and core.settings:get("secure.trusted_mods") or nil,
        trusted_setting_contains_current = trusted_setting_contains_current(),
        has_insecure_env = has_insecure_env,
        has_mkdir = has_mkdir,
        has_safe_write = has_safe_write,
        luanti_write_helpers = has_luanti_write_helpers(),
        browsable = worldmods_exists or has_insecure_env,
        readable = worldmods_exists or has_insecure_env or io ~= nil,
        can_create_dirs = has_insecure_env or has_mkdir,
        can_attempt_write = can_attempt_write,
        writable = can_attempt_write,
        write_mode = write_mode,
        requires_restart = true,
        hot_reload = false,
        reason = reason,
    }
end

function M.is_writable()
    -- Backwards-compatible hint only.  The authoritative write decision is the
    -- actual write path below, because Luanti may still deny a specific target.
    return M.capabilities().can_attempt_write == true
end

function M.is_browsable()
    -- Browsing existing worldmods is safe/read-only. It should be allowed even
    -- when trusted write access is not granted, so the UI can explain the state
    -- instead of hiding/crashing the backend.
    return M.capabilities().browsable == true
end

function M.is_available()
    -- Backwards-compatible: available means the backend can at least be opened
    -- or can try to initialize its own root through the final storage layer.
    local caps = M.capabilities()
    return caps.browsable == true or caps.can_attempt_write == true
end

function M.mod_exists(modname)
    modname = safe_modname(modname)
    return path_exists(WORLDMODS_DIR .. DIR_DELIM .. modname)
end

function M.active_mod_status(modname)
    modname = safe_modname(modname)
    if M.mod_exists(modname) then
        return true, "Active worldmod exists: " .. modname
    end
    if M.capabilities().can_attempt_write then
        return false, "Active worldmod does not exist yet. Create a file or folder to initialize it: " .. modname
    end
    return false, "Active worldmod does not exist and trusted backend is read-only: " .. modname
end

function M.diagnostics()
    local caps = M.capabilities()
    caps.insecure_env = caps.has_insecure_env
    return caps
end

function M.diagnostics_text()
    local d = M.diagnostics()
    local lines = {
        "Trusted worldmod diagnostics:",
        "worldmods_dir=" .. tostring(d.worldmods_dir),
        "current_modname=" .. tostring(d.current_modname),
        "secure.enable_security=" .. tostring(d.secure_enable_security),
        "secure.trusted_mods=" .. tostring(d.secure_trusted_mods),
        "trusted_setting_contains_current=" .. tostring(d.trusted_setting_contains_current),
        "luanti_write_helpers=" .. tostring(d.luanti_write_helpers),
        "insecure_env=" .. tostring(d.has_insecure_env),
        "browsable=" .. tostring(d.browsable),
        "writable=" .. tostring(d.writable),
        "write_mode=" .. tostring(d.write_mode),
    }
    if d.reason then
        lines[#lines + 1] = "Write note: " .. tostring(d.reason)
    end
    return table.concat(lines, "\n")
end

function M.ensure_mod(modname)
    modname = safe_modname(modname)
    local ok, err = ensure_dir(WORLDMODS_DIR)
    if not ok then
        return nil, (err or "Could not create worldmods directory")
            .. "; worldmods_dir=" .. tostring(WORLDMODS_DIR)
            .. "; create this directory manually if this Luanti profile denies mkdir"
    end
    ok, err = ensure_dir(WORLDMODS_DIR .. DIR_DELIM .. modname)
    if not ok then
        return nil, (err or "Could not create worldmod directory")
            .. "; mod_dir=" .. tostring(WORLDMODS_DIR .. DIR_DELIM .. modname)
            .. "; create this directory manually if this Luanti profile denies mkdir"
    end
    local modconf = WORLDMODS_DIR .. DIR_DELIM .. modname .. DIR_DELIM .. "mod.conf"
    if not read_file(modconf) then
        local wrote, write_err = write_file(modconf, "name = " .. modname .. "\ndescription = LLM-Connect managed trusted worldmod\n")
        if not wrote then return nil, write_err end
    end
    return modname
end

local function collect_files(base, rel, out)
    out = out or {}
    if storage_fs and storage_fs.collect_files then
        local files, diagnostics = storage_fs.collect_files({
            base = base,
            rel = rel or "",
            out = out,
            label = "trusted_mods",
            skip = { ["_llm_connect_index.txt"] = true },
        })
        M.last_fs_diagnostics = diagnostics
        return files
    end
    rel = rel or ""
    local dir = rel == "" and base or (base .. DIR_DELIM .. rel:gsub("/", DIR_DELIM))
    if core.get_dir_list then
        local ok_files, files = pcall(core.get_dir_list, dir, false)
        if ok_files then
            table.sort(files or {})
            for _, name in ipairs(files or {}) do
                if name ~= "_llm_connect_index.txt" then out[#out + 1] = rel == "" and name or (rel .. "/" .. name) end
            end
        else
            core.log("warning", "[trusted_mods] get_dir_list(files) failed for " .. tostring(dir) .. ": " .. tostring(files))
        end
        local ok_dirs, dirs = pcall(core.get_dir_list, dir, true)
        if ok_dirs then
            table.sort(dirs or {})
            for _, name in ipairs(dirs or {}) do
                if name ~= "." and name ~= ".." then collect_files(base, rel == "" and name or (rel .. "/" .. name), out) end
            end
        else
            core.log("warning", "[trusted_mods] get_dir_list(dirs) failed for " .. tostring(dir) .. ": " .. tostring(dirs))
        end
    end
    table.sort(out)
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
    if not path_exists(base) then
        if M.is_writable() then
            M.ensure_mod(modname)
        else
            M.last_fs_diagnostics = {"active worldmod does not exist: " .. modname, "backend is read-only"}
            return {}
        end
    end
    if storage_fs and storage_fs.list_dir then
        local entries, diagnostics = storage_fs.list_dir({
            base = base,
            rel_dir = clean,
            label = "trusted_mods",
            skip = { ["_llm_connect_index.txt"] = true },
        })
        M.last_fs_diagnostics = diagnostics
        return entries
    end
    local out = {}
    if clean ~= "" then out[#out + 1] = {type = "up", name = "..", path = dirname_rel(clean)} end
    return out
end

function M.master_entries(modname)
    modname = safe_modname(modname)
    local base = WORLDMODS_DIR .. DIR_DELIM .. modname
    if storage_fs and storage_fs.master_entries then
        local entries, diagnostics = storage_fs.master_entries({
            base = base,
            label = "trusted_mods",
            skip = { ["_llm_connect_index.txt"] = true },
            include_physical_dirs = true,
        })
        M.last_fs_diagnostics = diagnostics
        return entries
    end
    return {{type = "dir", name = "/", path = ""}}
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

core.log("action", "[trusted_mods] backend loaded: " .. WORLDMODS_DIR
    .. (type(get_insecure_env()) == "table" and " (trusted/insecure env active)"
        or (M.is_writable() and " (safe write helpers only/no insecure env)" or " (read-only/no insecure env)")))
if not M.is_writable() then
    core.log("warning", "[trusted_mods] write disabled. secure.trusted_mods=" .. tostring(core.settings and core.settings:get("secure.trusted_mods") or nil) .. ", current_modname=" .. tostring(current_modname()) .. ", trusted_setting_contains_current=" .. tostring(trusted_setting_contains_current()))
end

return M
