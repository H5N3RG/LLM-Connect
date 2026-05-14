-- ===========================================================================
--  storage_backends.lua — shared filesystem helpers for IDE storage backends
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Centralizes low-level directory access for runtime_scripts.lua and
--  trusted_mods.lua.  core.get_dir_list is useful, but it must never be used
--  raw from multiple backends: failures are pcalled, sorted, logged, and
--  returned with diagnostics so the filemanager does not silently invent empty
--  folders.
-- ===========================================================================

local core = core
local M = {}

M.version = "1.1.0-dev"
M.backend_name = "storage_backends"

local sep = DIR_DELIM or "/"

local function normalize_rel(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    if path == "" then return "" end
    if path:find("..", 1, true) then return nil, "Path traversal is not allowed" end
    if path:match("^/") then return nil, "Absolute paths are not allowed" end
    return path
end

local function join(root, rel)
    root = tostring(root or "")
    local clean, err = normalize_rel(rel or "")
    if not clean then return nil, err end
    if clean == "" then return root end
    return root .. sep .. clean:gsub("/", sep)
end

local function dirname_rel(path)
    path = normalize_rel(path) or ""
    return path:match("^(.*)/[^/]+$") or ""
end

local function rel_join(a, b)
    a = normalize_rel(a or "") or ""
    b = tostring(b or ""):gsub("\\", "/"):gsub("^/+", ""):gsub("/+$", "")
    if a == "" then return b end
    if b == "" then return a end
    return a .. "/" .. b
end

local function sorted_copy(list)
    local out = {}
    for _, value in ipairs(list or {}) do
        value = tostring(value or "")
        if value ~= "" then out[#out + 1] = value end
    end
    table.sort(out)
    return out
end

local function sort_entries(entries)
    local rank = {up = 0, dir = 1, file = 2}
    table.sort(entries, function(a, b)
        if a.type ~= b.type then return (rank[a.type] or 9) < (rank[b.type] or 9) end
        return tostring(a.name) < tostring(b.name)
    end)
    return entries
end

local function log_failure(label, path, kind, err)
    local msg = "[storage_backends] " .. tostring(label or "fs")
        .. " get_dir_list(" .. tostring(kind) .. ") failed for " .. tostring(path)
        .. ": " .. tostring(err)
    if core and core.log then core.log("warning", msg) end
end

function M.normalize_rel(path)
    return normalize_rel(path)
end

function M.dirname_rel(path)
    return dirname_rel(path)
end

function M.join(root, rel)
    return join(root, rel)
end

function M.sort_entries(entries)
    return sort_entries(entries or {})
end

function M.get_dir_list(path, dirs, label)
    if not (core and core.get_dir_list) then
        return {}, "core.get_dir_list unavailable"
    end
    local ok, result = pcall(core.get_dir_list, path, dirs)
    if ok and type(result) == "table" then
        return sorted_copy(result), nil
    end
    local err = ok and "nil/non-table result" or result
    log_failure(label, path, dirs and "dirs" or "files", err)
    return {}, tostring(err)
end

function M.path_exists(path, label)
    if not (core and core.get_dir_list) then return false, "core.get_dir_list unavailable" end
    local ok, result = pcall(core.get_dir_list, path, nil)
    if ok and result ~= nil then return true end
    return false, tostring(ok and "nil result" or result)
end

function M.collect_files(opts)
    opts = opts or {}
    local base = tostring(opts.base or "")
    local label = opts.label or "storage"
    local skip = opts.skip or {}
    local out = opts.out or {}
    local diagnostics = opts.diagnostics or {}

    local function walk(rel)
        rel = normalize_rel(rel or "") or ""
        local dir, join_err = join(base, rel)
        if not dir then
            diagnostics[#diagnostics + 1] = join_err
            return
        end

        local files, file_err = M.get_dir_list(dir, false, label)
        if file_err then diagnostics[#diagnostics + 1] = "files " .. dir .. ": " .. file_err end
        for _, name in ipairs(files) do
            if not skip[name] then out[#out + 1] = rel_join(rel, name) end
        end

        local dirs, dir_err = M.get_dir_list(dir, true, label)
        if dir_err then diagnostics[#diagnostics + 1] = "dirs " .. dir .. ": " .. dir_err end
        for _, name in ipairs(dirs) do
            if name ~= "." and name ~= ".." and not skip[name] then
                walk(rel_join(rel, name))
            end
        end
    end

    walk(opts.rel or "")
    table.sort(out)
    return out, diagnostics
end

function M.list_dir(opts)
    opts = opts or {}
    local base = tostring(opts.base or "")
    local rel_dir, rel_err = normalize_rel(opts.rel_dir or "")
    if not rel_dir then return {}, {rel_err} end

    local label = opts.label or "storage"
    local skip = opts.skip or {}
    local out = {}
    local diagnostics = {}
    local dir, join_err = join(base, rel_dir)
    if not dir then return {}, {join_err} end

    if rel_dir ~= "" and opts.include_up ~= false then
        out[#out + 1] = {type = "up", name = "..", path = dirname_rel(rel_dir)}
    end

    local dirs, dir_err = M.get_dir_list(dir, true, label)
    if dir_err then diagnostics[#diagnostics + 1] = "dirs " .. dir .. ": " .. dir_err end
    for _, name in ipairs(dirs) do
        if name ~= "." and name ~= ".." and not skip[name] then
            out[#out + 1] = {type = "dir", name = name, path = rel_join(rel_dir, name)}
        end
    end

    local files, file_err = M.get_dir_list(dir, false, label)
    if file_err then diagnostics[#diagnostics + 1] = "files " .. dir .. ": " .. file_err end
    for _, name in ipairs(files) do
        if not skip[name] then
            out[#out + 1] = {type = "file", name = name, path = rel_join(rel_dir, name)}
        end
    end

    return sort_entries(out), diagnostics
end

function M.master_entries(opts)
    opts = opts or {}
    local base = tostring(opts.base or "")
    local label = opts.label or "storage"
    local skip = opts.skip or {}
    local out = {{type = "dir", name = "/", path = ""}}
    local diagnostics = {}

    for _, entry in ipairs(opts.static_dirs or {}) do
        out[#out + 1] = {type = "dir", name = entry.name, path = entry.path}
    end

    if opts.include_physical_dirs then
        local dirs, err = M.get_dir_list(base, true, label)
        if err then diagnostics[#diagnostics + 1] = "dirs " .. base .. ": " .. err end
        for _, name in ipairs(dirs) do
            if name ~= "." and name ~= ".." and not skip[name] then
                out[#out + 1] = {type = "dir", name = name, path = name}
            end
        end
    end

    return sort_entries(out), diagnostics
end

core.log("action", "[storage_backends] shared filesystem helpers loaded")

return M
