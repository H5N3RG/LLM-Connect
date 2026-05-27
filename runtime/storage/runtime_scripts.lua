-- ===========================================================================
--  runtime_scripts.lua — LLM Connect IDE persistence + hot-reload backend
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Owns the safe/default IDE persistence path:
--    world/llm_scripts/<player>/{runtime,sticky,startup,disabled}/...
--
--  This module deliberately contains no formspec code and no LLM orchestration.
--  It classifies code, stores files, and delegates actual execution back to
--  core_executor.lua.
-- ===========================================================================

local core = core
local M = {}

M.version = "1.2.0-dev"
M.backend_name = "llm_runtime"

local root = rawget(_G, "llm_connect")
local path_policy = (root and root.path_policy) or rawget(_G, "path_policy")
local storage_fs = (root and root.storage_backends) or rawget(_G, "storage_backends")
local WORLD_DIR = path_policy and path_policy.world_path or core.get_worldpath()
local BASE_DIR = path_policy and path_policy.runtime_scripts_dir() or (WORLD_DIR .. DIR_DELIM .. "llm_scripts")
local ENABLED_INDEX = (path_policy and path_policy.join(BASE_DIR, "_enabled.txt")) or (BASE_DIR .. DIR_DELIM .. "_enabled.txt")

local function mkdir(path)
    path = tostring(path or "")
    if path == "" then return false, "missing path" end
    local fn = core.mkdir or (minetest and minetest.mkdir)
    if not fn then return false, "mkdir unavailable" end
    local ok, result = pcall(fn, path)
    if not ok then return false, tostring(result) end
    return result ~= false, result == false and "mkdir returned false" or nil
end

local function ensure_dir(path)
    local ok, err = mkdir(path)
    if not ok then
        core.log("warning", "[runtime_scripts] mkdir failed for " .. tostring(path) .. ": " .. tostring(err))
    end
    return ok, err
end

local function ensure_dir_tree(path)
    path = tostring(path or "")
    if path == "" then return false, "missing path" end
    local sep = DIR_DELIM or "/"
    local base = tostring(BASE_DIR or ""):gsub("[/\\]+$", "")
    local rel

    if base ~= "" and path == base then
        return ensure_dir(base)
    elseif base ~= "" and path:sub(1, #base + 1) == base .. sep then
        rel = path:sub(#base + 2)
    elseif path:sub(1, 1) == sep then
        return false, "refusing to create directory outside runtime script root: " .. path
    else
        rel = path
    end

    local ok, err = ensure_dir(base ~= "" and base or ".")
    if not ok then return false, err end

    local accum = base ~= "" and base or ""
    for part in rel:gmatch("[^" .. sep .. "]+") do
        if accum == "" then accum = part else accum = accum .. sep .. part end
        ok, err = ensure_dir(accum)
        if not ok then return false, err end
    end
    return true
end

local function normalize_relpath(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("/+$", "")
    path = path:gsub("/+", "/")
    if path:find("..", 1, true) then return nil end
    local out = {}
    for part in path:gmatch("[^/]+") do
        local clean_part = tostring(part or ""):gsub("[^%w_%.%-]", "_"):gsub("%.%.", "__")
        if clean_part ~= "" then out[#out + 1] = clean_part end
    end
    return table.concat(out, "/")
end

local function dirname_rel(path)
    path = normalize_relpath(path) or ""
    return path:match("^(.*)/[^/]+$") or ""
end

local function safe_name(value, fallback)
    value = tostring(value or fallback or "untitled")
    value = value:gsub("[^%w_%.%-]", "_")
    value = value:gsub("%.%.", "__")
    if value == "" then value = fallback or "untitled" end
    return value
end

local function safe_player_name(name)
    return safe_name(name, "singleplayer")
end

local function normalize_filename(filename)
    filename = safe_name(filename, "untitled.lua")
    filename = filename:match("([^/\\]+)$") or filename
    if not filename:match("%.lua$") then filename = filename .. ".lua" end
    return filename
end

local function read_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil, err end
    local content = f:read("*a")
    f:close()
    return content
end

local function write_file(path, content)
    if core.safe_file_write then
        local ok = core.safe_file_write(path, content)
        if ok then return true end
    end
    local f, err = io.open(path, "w")
    if not f then return false, err end
    f:write(content or "")
    f:close()
    return true
end

local function append_file(path, line)
    local f, err = io.open(path, "a")
    if not f then return false, err end
    f:write(line)
    f:write("\n")
    f:close()
    return true
end

local function split_lines(content)
    local out = {}
    for line in tostring(content or ""):gmatch("([^\n]*)\n?") do
        local clean_line = line:match("^%s*(.-)%s*$")
        if clean_line ~= "" then out[#out + 1] = clean_line end
    end
    return out
end

local function read_index(path)
    local content = read_file(path)
    if not content then return {} end
    local lines = split_lines(content)
    table.sort(lines)
    return lines
end

local function write_index(path, entries)
    local seen, sorted = {}, {}
    for _, entry in ipairs(entries or {}) do
        entry = tostring(entry or ""):match("^%s*(.-)%s*$")
        if entry ~= "" and not seen[entry] then
            seen[entry] = true
            sorted[#sorted + 1] = entry
        end
    end
    table.sort(sorted)
    return write_file(path, table.concat(sorted, "\n"))
end

local function index_add(path, entry)
    local entries = read_index(path)
    for _, existing in ipairs(entries) do
        if existing == entry then return true end
    end
    entries[#entries + 1] = entry
    return write_index(path, entries)
end

local function index_remove(path, entry)
    local entries, out = read_index(path), {}
    for _, existing in ipairs(entries) do
        if existing ~= entry then out[#out + 1] = existing end
    end
    return write_index(path, out)
end

function M.get_user_dir(player_name)
    local user = safe_player_name(player_name)
    local dir = BASE_DIR .. DIR_DELIM .. user
    ensure_dir(BASE_DIR)
    ensure_dir(dir)
    ensure_dir(dir .. DIR_DELIM .. "runtime")
    ensure_dir(dir .. DIR_DELIM .. "sticky")
    ensure_dir(dir .. DIR_DELIM .. "startup")
    ensure_dir(dir .. DIR_DELIM .. "disabled")
    return dir
end

local function index_path(player_name)
    return M.get_user_dir(player_name) .. DIR_DELIM .. "_index.txt"
end

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

    local result = {
        class = "runtime_safe",
        mode = context.mode or "llm_runtime",
        hot_reloadable = true,
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
        result.hot_reloadable = false
        result.persistable = false
        result.dangerous = true
        result.hits = dangerous_hits
        result.issues[#result.issues + 1] = "Dangerous host access: " .. table.concat(dangerous_hits, ", ")
        return result
    end

    local startup_hits = collect_hits(code, STARTUP_PATTERNS)
    local sticky_hits = collect_hits(code, STICKY_PATTERNS)

    local allowed_prefix = "llm_connect"
    if context.mode == "trusted_worldmod" and context.modname then
        allowed_prefix = context.modname
    end

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

    if #startup_hits > 0 then
        result.class = "startup_preferred"
        result.hot_reloadable = false
        result.requires_restart = true
        result.hits = startup_hits
    elseif #sticky_hits > 0 then
        result.class = "sticky_runtime"
        result.hot_reloadable = false
        result.requires_restart = false
        result.sticky = true
        result.hits = sticky_hits
        result.issues[#result.issues + 1] = "Sticky runtime registration may duplicate callbacks on reload."
    end

    return result
end

local function folder_for_class(class)
    if class == "startup_preferred" then return "startup" end
    if class == "sticky_runtime" then return "sticky" end
    if class == "dangerous" then return "disabled" end
    return "runtime"
end

function M.save_script(player_name, filename, code, meta)
    meta = meta or {}
    filename = tostring(filename or "untitled.lua"):gsub("\\", "/")
    local explicit_folder = meta.folder
    if filename:find("/", 1, true) then
        local first, rest = filename:match("^([^/]+)/(.+)$")
        if first == "runtime" or first == "sticky" or first == "startup" or first == "disabled" then
            explicit_folder = explicit_folder or first
            filename = rest
        end
    end
    filename = normalize_relpath(filename) or "untitled.lua"
    if filename == "" then filename = "untitled.lua" end
    if not filename:match("%.lua$") and not filename:match("%.conf$") and not filename:match("%.md$") and not filename:match("%.txt$") then
        filename = filename .. ".lua"
    end

    local classification = meta.classification or M.classify(code, {mode = "llm_runtime"})
    if classification.class == "dangerous" and not meta.allow_dangerous then
        return false, "Refusing to save dangerous script: " .. table.concat(classification.issues or {}, "; "), classification
    end

    local folder = explicit_folder or folder_for_class(classification.class)
    local user_dir = M.get_user_dir(player_name)
    local rel = folder .. "/" .. filename
    local path = user_dir .. DIR_DELIM .. rel:gsub("/", DIR_DELIM)
    local parent = path:match("^(.*)" .. DIR_DELIM .. "[^" .. DIR_DELIM .. "]+$")
    if parent then
        local ok, dir_err = ensure_dir_tree(parent)
        if not ok then return false, dir_err, classification end
    end

    local header = "-- LLM-Connect managed script\n"
        .. "-- owner: " .. tostring(player_name or "?") .. "\n"
        .. "-- class: " .. tostring(classification.class) .. "\n"
        .. "-- saved: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n"

    local ok, err = write_file(path, header .. tostring(code or ""))
    if not ok then return false, err, classification end

    index_add(index_path(player_name), rel)
    if meta.enabled then index_add(ENABLED_INDEX, safe_player_name(player_name) .. "/" .. rel) end

    return true, rel, classification
end

function M.read_script(player_name, relpath)
    relpath = tostring(relpath or "")
    relpath = relpath:gsub("\\", "/")
    relpath = relpath:gsub("^/+", "")
    if relpath:find("%.%.", 1, true) then return nil, "Invalid path" end
    local path = M.get_user_dir(player_name) .. DIR_DELIM .. relpath:gsub("/", DIR_DELIM)
    return read_file(path)
end

local function collect_files(base, rel, out)
    out = out or {}
    if storage_fs and storage_fs.collect_files then
        local files, diagnostics = storage_fs.collect_files({
            base = base,
            rel = rel or "",
            out = out,
            label = "runtime_scripts",
            skip = { ["_index.txt"] = true },
        })
        M.last_fs_diagnostics = diagnostics
        return files
    end
    -- Fallback for very old load orders; intentionally pcalled to avoid
    -- phantom-empty filemanager states caused by raw get_dir_list failures.
    rel = rel or ""
    local dir = rel == "" and base or (base .. DIR_DELIM .. rel:gsub("/", DIR_DELIM))
    if core.get_dir_list then
        local ok_files, files = pcall(core.get_dir_list, dir, false)
        if ok_files then
            table.sort(files or {})
            for _, name in ipairs(files or {}) do
                if name ~= "_index.txt" then out[#out + 1] = rel == "" and name or (rel .. "/" .. name) end
            end
        else
            core.log("warning", "[runtime_scripts] get_dir_list(files) failed for " .. tostring(dir) .. ": " .. tostring(files))
        end
        local ok_dirs, dirs = pcall(core.get_dir_list, dir, true)
        if ok_dirs then
            table.sort(dirs or {})
            for _, name in ipairs(dirs or {}) do
                if name ~= "." and name ~= ".." then collect_files(base, rel == "" and name or (rel .. "/" .. name), out) end
            end
        else
            core.log("warning", "[runtime_scripts] get_dir_list(dirs) failed for " .. tostring(dir) .. ": " .. tostring(dirs))
        end
    end
    table.sort(out)
    return out
end

function M.list_scripts(player_name)
    local physical = collect_files(M.get_user_dir(player_name), "", {})
    if #physical > 0 then
        table.sort(physical)
        return physical
    end
    return read_index(index_path(player_name))
end

function M.list_dir(player_name, rel_dir)
    rel_dir = normalize_relpath(rel_dir or "") or ""
    local base = M.get_user_dir(player_name)
    if storage_fs and storage_fs.list_dir then
        local entries, diagnostics = storage_fs.list_dir({
            base = base,
            rel_dir = rel_dir,
            label = "runtime_scripts",
            skip = { ["_index.txt"] = true },
        })
        M.last_fs_diagnostics = diagnostics
        return entries
    end
    local out = {}
    if rel_dir ~= "" then out[#out + 1] = {type = "up", name = "..", path = dirname_rel(rel_dir)} end
    return out
end

function M.master_entries(player_name)
    M.get_user_dir(player_name)
    local static = {
        {name = "runtime", path = "runtime"},
        {name = "sticky", path = "sticky"},
        {name = "startup", path = "startup"},
        {name = "disabled", path = "disabled"},
    }
    if storage_fs and storage_fs.master_entries then
        local entries, diagnostics = storage_fs.master_entries({
            base = M.get_user_dir(player_name),
            label = "runtime_scripts",
            static_dirs = static,
            include_physical_dirs = false,
        })
        M.last_fs_diagnostics = diagnostics
        return entries
    end
    return {
        {type = "dir", name = "/", path = ""},
        {type = "dir", name = "runtime", path = "runtime"},
        {type = "dir", name = "sticky", path = "sticky"},
        {type = "dir", name = "startup", path = "startup"},
        {type = "dir", name = "disabled", path = "disabled"},
    }
end

function M.make_dir(player_name, rel_dir)
    rel_dir = normalize_relpath(rel_dir or "") or ""
    if rel_dir == "" then return false, "Invalid directory" end
    local path = M.get_user_dir(player_name) .. DIR_DELIM .. rel_dir:gsub("/", DIR_DELIM)
    ensure_dir_tree(path)
    return true, rel_dir
end

function M.delete_script(player_name, relpath)
    -- Lua 5.1 / Luanti has os.remove available in normal mod scope.
    relpath = tostring(relpath or "")
    if relpath == "" or relpath:find("%.%.", 1, true) then return false, "Invalid path" end
    local path = M.get_user_dir(player_name) .. DIR_DELIM .. relpath:gsub("/", DIR_DELIM)
    local ok, err = os.remove(path)
    if ok then
        index_remove(index_path(player_name), relpath)
        index_remove(ENABLED_INDEX, safe_player_name(player_name) .. "/" .. relpath)
        return true
    end
    return false, err
end

function M.run_script(player_name, relpath, opts)
    opts = opts or {}
    local code, err = M.read_script(player_name, relpath)
    if not code then return {ok = false, success = false, error = err or "Could not read script"} end
    local executor = _G.core_executor or (_G.llm_connect and _G.llm_connect.core_executor)
    if not executor then return {ok = false, success = false, error = "core_executor unavailable"} end
    opts.purpose = opts.purpose or "ide"
    opts.persist = false
    opts.precheck = opts.precheck ~= false
    opts.chunk_name = opts.chunk_name or ("=(llm_scripts/" .. tostring(relpath) .. ")")
    return executor.execute(player_name, code, opts)
end

function M.hot_reload(player_name, filename, code, opts)
    opts = opts or {}
    local classification = M.classify(code, {mode = "llm_runtime"})
    local saved, rel_or_err = M.save_script(player_name, filename, code, {
        classification = classification,
        enabled = opts.enabled == true,
        folder = opts.folder,
    })
    if not saved then
        return {ok = false, success = false, error = rel_or_err, classification = classification}
    end

    if classification.class ~= "runtime_safe" then
        return {
            ok = true,
            success = true,
            saved = true,
            reloaded = false,
            relpath = rel_or_err,
            classification = classification,
            message = classification.class == "startup_preferred"
                and "Saved for startup. Restart recommended/required for registrations."
                or "Saved, but not hot-reloaded because this code is sticky or not reload-safe.",
        }
    end

    local run = M.run_script(player_name, rel_or_err, opts)
    run.saved = true
    run.reloaded = run.success == true
    run.relpath = rel_or_err
    run.classification = classification
    return run
end

function M.load_enabled_after_start()
    ensure_dir(BASE_DIR)
    local entries = read_index(ENABLED_INDEX)
    if #entries == 0 then return 0 end

    local count = 0
    for _, entry in ipairs(entries) do
        local player, rel = entry:match("^([^/]+)/(.+)$")
        if player and rel then
            local code, err = M.read_script(player, rel)
            if code then
                local ok, run_err = pcall(function()
                    local fn, compile_err = loadstring(code, "=(llm_enabled/" .. entry .. ")")
                    if not fn then error(compile_err) end
                    fn()
                end)
                if ok then
                    count = count + 1
                    core.log("action", "[runtime_scripts] after-load executed: " .. entry)
                else
                    core.log("error", "[runtime_scripts] after-load failed for " .. entry .. ": " .. tostring(run_err))
                end
            else
                core.log("warning", "[runtime_scripts] enabled script missing: " .. entry .. " — " .. tostring(err))
            end
        end
    end
    return count
end

function M.format_class_summary(classification)
    classification = classification or {class = "unknown"}
    local parts = {"Class: " .. tostring(classification.class)}
    parts[#parts + 1] = "Hot reload: " .. (classification.hot_reloadable and "yes" or "no")
    if classification.requires_restart then parts[#parts + 1] = "Restart: recommended" end
    if classification.sticky then parts[#parts + 1] = "Sticky: yes" end
    if classification.issues and #classification.issues > 0 then
        parts[#parts + 1] = "Issues: " .. table.concat(classification.issues, " | ")
    end
    return table.concat(parts, "\n")
end

core.log("action", "[runtime_scripts] backend loaded: " .. BASE_DIR)

return M
