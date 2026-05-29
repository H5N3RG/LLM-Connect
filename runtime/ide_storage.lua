-- ===========================================================================
--  ide_storage.lua - world-backed IDE/runtime storage service
--
--  Luanti 5.16+ disallows writing into mod directories. LLM-Connect therefore
--  keeps generated/runtime code strictly in the active world directory:
--      <worldpath>/llm_scripts/<player>/scripts
--
--  This module owns persistence only. Execution stays delegated to core_executor.
-- ===========================================================================

local core = core
local M = {}

M.version = "1.2.0-dev"

local root = rawget(_G, "llm_connect") or {}
local path_policy = root.path_policy or rawget(_G, "path_policy")
local classifier = root.code_classifier or rawget(_G, "code_classifier")
local sep = DIR_DELIM or "/"
local diagnostics = {}

local function diag(player_name, message)
    player_name = tostring(player_name or "*")
    diagnostics[player_name] = diagnostics[player_name] or {}
    diagnostics[player_name][#diagnostics[player_name] + 1] = tostring(message)
end

local function clear_diag(player_name)
    diagnostics[tostring(player_name or "*")] = {}
end

local function get_diag(player_name)
    return diagnostics[tostring(player_name or "*")] or {}
end

local function normalize_rel(path)
    if path_policy and path_policy.normalize_rel then return path_policy.normalize_rel(path) end
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    if path:find("..", 1, true) then return nil, "Path traversal is not allowed" end
    if path:match("^/") then return nil, "Absolute paths are not allowed" end
    return path
end

local function safe_rel(path, default)
    if path_policy and path_policy.safe_rel then return path_policy.safe_rel(path, default) end
    local clean, err = normalize_rel(path or default or "")
    if not clean then return nil, err end
    return clean:gsub("[^%w_%.%-%/]", "_")
end

local function dirname_rel(path)
    if path_policy and path_policy.dirname_rel then return path_policy.dirname_rel(path) end
    local clean = normalize_rel(path) or ""
    return clean:match("^(.*)/[^/]+$") or ""
end

local function join(...)
    if path_policy and path_policy.join then return path_policy.join(...) end
    local parts, out = {...}, {}
    for i, part in ipairs(parts) do
        part = tostring(part or "")
        if part ~= "" then
            if i > 1 then part = part:gsub("^[/\\]+", "") end
            part = part:gsub("[/\\]+$", "")
            out[#out + 1] = part
        end
    end
    return table.concat(out, sep)
end

local function stack_path(root_path, relpath)
    if not root_path or root_path == "" then return nil, "Storage root unavailable" end
    if path_policy and path_policy.stack_path then return path_policy.stack_path(root_path, relpath) end
    local clean, err = normalize_rel(relpath or "")
    if not clean then return nil, err end
    if clean == "" then return root_path end
    return join(root_path, clean:gsub("/", sep))
end

local function safe_player_name(player_name)
    local clean = safe_rel(player_name or "singleplayer", "singleplayer") or "singleplayer"
    clean = clean:gsub("/", "_")
    if clean == "" then clean = "singleplayer" end
    return clean
end

local function editable_path(path)
    local clean, err = safe_rel(path or "untitled.lua", "untitled.lua")
    if not clean then return nil, err end
    if clean == "" then clean = "untitled.lua" end
    return clean
end

local function sort_entries(entries)
    table.sort(entries, function(a, b)
        if a.type ~= b.type then
            local order = {up = 0, dir = 1, file = 2}
            return (order[a.type] or 9) < (order[b.type] or 9)
        end
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return entries
end

local function classify(code, context)
    local c = classifier or (_G.llm_connect and _G.llm_connect.code_classifier)
    if c and c.classify then return c.classify(code, context) end
    return {class = "unknown", hot_reloadable = false, persistable = true, issues = {"code_classifier unavailable"}}
end

local function read_file(path)
    if not io or not io.open then return nil, "read API unavailable" end
    local ok, content = pcall(function()
        local f, err = io.open(path, "rb")
        if not f then return nil, err end
        local data = f:read("*a")
        f:close()
        return data
    end)
    if ok then return content end
    return nil, tostring(content)
end

local function write_file(path, content)
    if not io or not io.open then return false, "write API unavailable" end
    local ok, result = pcall(function()
        local f, err = io.open(path, "wb")
        if not f then return false, err end
        f:write(tostring(content or ""))
        f:close()
        return true
    end)
    if ok then return result == true, result == true and nil or tostring(result) end
    return false, tostring(result)
end

local function mkdir_one(path)
    if core.mkdir then
        local ok, result = pcall(core.mkdir, path)
        if ok and result ~= false then return true end
    end
    return false, "mkdir failed: " .. tostring(path)
end

local function mkdir_tree(root_path, relpath)
    local clean, err = normalize_rel(relpath or "")
    if not clean then return false, err end
    local ok, mk_err = mkdir_one(root_path)
    if not ok then return false, mk_err end
    local accum = root_path
    for part in clean:gmatch("[^/]+") do
        accum = join(accum, part)
        ok, mk_err = mkdir_one(accum)
        if not ok then return false, mk_err end
    end
    return true
end

local function get_dir_list(path, is_dir)
    if not core.get_dir_list then return nil, "core.get_dir_list unavailable" end
    local ok, result = pcall(core.get_dir_list, path, is_dir)
    if ok then return result end
    return nil, tostring(result)
end

local function path_exists(path)
    if core.path_exists then
        local ok, exists = pcall(core.path_exists, path)
        if ok then return exists == true end
    end
    local dirs = get_dir_list(path, true)
    local files = get_dir_list(path, false)
    return type(dirs) == "table" or type(files) == "table"
end

local function list_dir_physical(_player_name, root_path, relpath)
    local entries, diags = {}, {}
    local clean, err = normalize_rel(relpath or "")
    if not clean then return nil, err end
    local full, path_err = stack_path(root_path, clean)
    if not full then return nil, path_err end

    local dirs, dir_err = get_dir_list(full, true)
    local files, file_err = get_dir_list(full, false)
    if dir_err then diags[#diags + 1] = "runtime dirs " .. full .. ": " .. dir_err end
    if file_err then diags[#diags + 1] = "runtime files " .. full .. ": " .. file_err end
    if not dirs and not files then return nil, table.concat(diags, "\n") end

    if clean ~= "" then entries[#entries + 1] = {type = "up", name = "..", path = dirname_rel(clean)} end
    for _, name in ipairs(dirs or {}) do
        if name ~= "." and name ~= ".." then entries[#entries + 1] = {type = "dir", name = name, path = clean == "" and name or (clean .. "/" .. name)} end
    end
    for _, name in ipairs(files or {}) do
        entries[#entries + 1] = {type = "file", name = name, path = clean == "" and name or (clean .. "/" .. name)}
    end
    return sort_entries(entries), nil, diags
end

local function collect_files(root_path, relpath, out)
    out = out or {}
    local entries = list_dir_physical("*", root_path, relpath or "")
    if type(entries) ~= "table" then return out end
    for _, entry in ipairs(entries) do
        if entry.type == "file" then out[#out + 1] = entry.path
        elseif entry.type == "dir" then collect_files(root_path, entry.path, out) end
    end
    table.sort(out)
    return out
end

local function storage_root()
    if path_policy and path_policy.ide_storage_root_dir then return path_policy.ide_storage_root_dir() end
    local world = core.get_worldpath and core.get_worldpath() or nil
    return world and join(world, "llm_scripts") or nil
end

local function runtime_base(player_name)
    if path_policy and path_policy.runtime_player_scripts_dir then return path_policy.runtime_player_scripts_dir(player_name) end
    local base = storage_root()
    return base and join(base, safe_player_name(player_name), "scripts") or nil
end

local function ensure_runtime_root(player_name)
    local base = storage_root()
    if not base then return false, "world path unavailable" end
    local user = safe_player_name(player_name)
    local ok, err = mkdir_one(base)
    if not ok then return false, err end
    ok, err = mkdir_one(join(base, user)); if not ok then return false, err end
    ok, err = mkdir_one(join(base, user, "scripts")); if not ok then return false, err end
    return true
end

local function runtime_enabled_index()
    local base = storage_root()
    return base and join(base, "_enabled.txt") or nil
end

local function add_enabled(player_name, relpath)
    local index = runtime_enabled_index()
    if not index then return false, "world path unavailable" end
    local content = read_file(index) or ""
    local entry = safe_player_name(player_name) .. "/scripts/" .. relpath
    for line in content:gmatch("([^\n]+)") do
        if line == entry then return true end
    end
    if content ~= "" and not content:match("\n$") then content = content .. "\n" end
    return write_file(index, content .. entry .. "\n")
end

local function is_root(player_name)
    local policy = _G.llm_connect and _G.llm_connect.policy
    if policy and policy.is_root then return policy.is_root(player_name) end
    local privs = core.get_player_privs(player_name) or {}
    return privs.llm_root == true
end

function M.ensure_session(session)
    session = session or {}
    session.persist_backend = "in_runtime"
    session.current_dir = session.current_dir or ""
    session.filename = session.filename or "untitled.lua"
    return session
end

function M.get_backend(_player_name, session)
    if session then session.persist_backend = "in_runtime" end
    return "in_runtime"
end

function M.default_backend() return "in_runtime" end
function M.can_switch_backend(_player_name) return false end
function M.next_backend(_player_name, _current) return "in_runtime" end
function M.backend_label(_backend) return "world/llm_scripts/[player]/scripts" end

function M.list_dir(player_name, session, relpath)
    clear_diag(player_name)
    M.ensure_session(session)
    local ok, root_err = ensure_runtime_root(player_name)
    if not ok then diag(player_name, root_err); return {} end
    local root_path = runtime_base(player_name)
    if not root_path then diag(player_name, "Runtime storage root unavailable"); return {} end
    local entries, err, diags = list_dir_physical(player_name, root_path, relpath or "")
    for _, item in ipairs(diags or {}) do diag(player_name, item) end
    if err then diag(player_name, err); return {} end
    return entries or {}
end

function M.read_file(player_name, session, relpath)
    M.ensure_session(session)
    local clean, err = normalize_rel(relpath or "")
    if not clean or clean == "" then return nil, err or "Invalid path" end
    local full, path_err = stack_path(runtime_base(player_name), clean)
    if not full then return nil, path_err end
    return read_file(full)
end

function M.save_file(player_name, session, relpath, content)
    M.ensure_session(session)
    local clean, err = editable_path(relpath or (session and session.filename) or "untitled.lua")
    if not clean then return false, err end
    local root_path = runtime_base(player_name)
    if not root_path then return false, "Runtime storage root unavailable" end
    local ok, root_err = ensure_runtime_root(player_name)
    if not ok then return false, root_err end

    local parent = dirname_rel(clean)
    local mk_ok, mk_err = mkdir_tree(root_path, parent)
    if not mk_ok then return false, mk_err end

    local class = classify(content, {mode = "in_runtime"})
    local full, path_err = stack_path(root_path, clean)
    if not full then return false, path_err, class end
    local written, write_err = write_file(full, content)
    if written and session then session.filename = clean end
    return written, write_err or clean, class
end

function M.make_dir(player_name, session, relpath)
    M.ensure_session(session)
    local clean, err = safe_rel(relpath or "")
    if not clean or clean == "" then return false, err or "Invalid directory" end
    local ok, root_err = ensure_runtime_root(player_name)
    if not ok then return false, root_err end
    return mkdir_tree(runtime_base(player_name), clean)
end

function M.delete_file(player_name, session, relpath)
    M.ensure_session(session)
    local clean, err = normalize_rel(relpath or "")
    if not clean or clean == "" then return false, err or "Invalid path" end
    local full, path_err = stack_path(runtime_base(player_name), clean)
    if not full then return false, path_err end
    local ok, rm_err = os.remove(full)
    return ok == true, rm_err
end

function M.hot_reload(player_name, session, relpath, content)
    if content == nil and session and relpath ~= nil then content = relpath; relpath = session.filename end
    M.ensure_session(session)
    local code = content or M.read_file(player_name, session, relpath)
    local class = classify(code, {mode = "in_runtime"})
    local saved, rel_or_err, saved_class = M.save_file(player_name, session, relpath, code)
    class = saved_class or class
    if not saved then return {ok = false, success = false, error = rel_or_err, classification = class} end

    local root_reload = is_root(player_name)
    if class.hot_reloadable ~= true and not root_reload then
        return {ok = true, success = true, saved = true, reloaded = false, relpath = rel_or_err, classification = class, message = class.requires_restart and "Saved; restart required for registration/startup code." or "Saved; classifier blocked hot reload."}
    end

    local executor = _G.core_executor or (_G.llm_connect and _G.llm_connect.core_executor)
    if not executor or type(executor.execute) ~= "function" then
        return {ok = false, success = false, saved = true, reloaded = false, relpath = rel_or_err, classification = class, error = "core_executor unavailable"}
    end
    local run = executor.execute(player_name, code, {
        purpose = "ide",
        precheck = true,
        persist = false,
        allow_dangerous = root_reload,
        allow_startup_execution = root_reload,
        bypass_safety_filters = root_reload,
        chunk_name = "=(llm_scripts/" .. tostring(rel_or_err) .. ")",
        mode = "in_runtime",
    })
    run.saved = true
    run.reloaded = run.success == true
    run.relpath = rel_or_err
    run.classification = class
    if run.reloaded then add_enabled(player_name, rel_or_err) end
    return run
end

function M.get_diagnostics(player_name, session)
    M.ensure_session(session or {})
    return {
        backend = "in_runtime",
        root = runtime_base(player_name),
        world = core.get_worldpath and core.get_worldpath() or nil,
        diagnostics = get_diag(player_name),
    }
end

function M.diagnostics_text(player_name, session)
    local d = M.get_diagnostics(player_name, session or {})
    local lines = {"Backend: in_runtime", "Root: " .. tostring(d.root), "World: " .. tostring(d.world)}
    for _, item in ipairs(d.diagnostics or {}) do lines[#lines + 1] = tostring(item) end
    return table.concat(lines, "\n")
end

function M.load_enabled_after_start()
    local index = runtime_enabled_index()
    local content = index and read_file(index) or nil
    if not content then return 0 end
    local count = 0
    for line in content:gmatch("([^\n]+)") do
        local player, rel = line:match("^([^/]+)/scripts/(.+)$")
        if player and rel then
            local full = stack_path(runtime_base(player), rel)
            local code = full and read_file(full) or nil
            if code then
                local ok, err = pcall(function()
                    local fn, compile_err = loadstring(code, "=(llm_enabled/" .. line .. ")")
                    if not fn then error(compile_err) end
                    fn()
                end)
                if ok then count = count + 1; core.log("action", "[ide_storage] after-load executed: " .. line)
                else core.log("error", "[ide_storage] after-load failed for " .. line .. ": " .. tostring(err)) end
            end
        end
    end
    return count
end

function M.list(player_name, session)
    local root_path = runtime_base(player_name)
    if not root_path or not path_exists(root_path) then return {} end
    return collect_files(root_path, "", {})
end
function M.read(player_name, session, entry) return M.read_file(player_name, session, entry) end
function M.read_path(player_name, session, relpath) return M.read_file(player_name, session, relpath) end
function M.save(player_name, session, code) M.ensure_session(session); return M.save_file(player_name, session, session.filename, code) end
function M.delete(player_name, session, entry) return M.delete_file(player_name, session, entry) end

function M.master_entries(player_name, session)
    M.ensure_session(session)
    local entries = {{type = "dir", name = "/", path = ""}}
    local root_path = runtime_base(player_name)
    if root_path and path_exists(root_path) then
        local dirs = get_dir_list(root_path, true) or {}
        for _, name in ipairs(dirs) do
            if name ~= "." and name ~= ".." then entries[#entries + 1] = {type = "dir", name = name, path = name} end
        end
    end
    return sort_entries(entries)
end

function M.status(session)
    M.ensure_session(session)
    return M.backend_label("in_runtime")
end

core.log("action", "[ide_storage] world-backed IDE storage loaded; root=" .. tostring(storage_root()))

return M
