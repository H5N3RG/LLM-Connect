-- ===========================================================================
--  path_policy.lua — Luanti-stack-relative path roots for LLM Connect
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Centralizes all filesystem roots.  Backends must derive paths from Luanti's
--  own runtime API (world/mod/game paths), never from host-specific constants.
-- ===========================================================================

local core = core
local M = {}

local sep = DIR_DELIM or "/"

local mod_name = core.get_current_modname and core.get_current_modname() or "llm_connect"
local mod_path = core.get_modpath and core.get_modpath(mod_name) or nil
local world_path = core.get_worldpath and core.get_worldpath() or nil
local game_info = core.get_game_info and core.get_game_info() or nil
local game_path = game_info and game_info.path or nil

local function join(...)
    local parts = {...}
    local out = {}
    for i, part in ipairs(parts) do
        part = tostring(part or "")
        if part ~= "" then
            if i > 1 then part = part:gsub("^[" .. sep .. "/\\]+", "") end
            part = part:gsub("[" .. sep .. "/\\]+$", "")
            out[#out + 1] = part
        end
    end
    return table.concat(out, sep)
end

local function normalize_rel(path)
    path = tostring(path or ""):gsub("\\", "/")
    path = path:gsub("^/+", ""):gsub("/+$", ""):gsub("/+", "/")
    if path == "" then return "" end
    if path:find("..", 1, true) then return nil, "Path traversal is not allowed" end
    if path:match("^/") then return nil, "Absolute paths are not allowed" end
    return path
end

local function stack_path(root, rel)
    local clean, err = normalize_rel(rel or "")
    if not clean then return nil, err end
    if clean == "" then return root end
    return join(root, clean:gsub("/", sep))
end

M.sep = sep
M.mod_name = mod_name
M.mod_path = mod_path
M.world_path = world_path
M.game_path = game_path

M.roots = {
    world = world_path,
    mod = mod_path,
    game = game_path,
    runtime_scripts = world_path and join(world_path, "llm_scripts") or nil,
    worldmods = world_path and join(world_path, "worldmods") or nil,
    snippets = world_path and join(world_path, "llm_snippets") or nil,
    startup_file = world_path and join(world_path, "llm_startup.lua") or nil,
}

function M.join(...)
    return join(...)
end

function M.normalize_rel(path)
    return normalize_rel(path)
end

function M.runtime_scripts_dir()
    return M.roots.runtime_scripts
end

function M.worldmods_dir()
    return M.roots.worldmods
end

function M.snippets_dir()
    return M.roots.snippets
end

function M.startup_file()
    return M.roots.startup_file
end

function M.world_child(rel)
    return stack_path(world_path, rel)
end

function M.mod_child(rel)
    return stack_path(mod_path, rel)
end

function M.game_child(rel)
    return stack_path(game_path, rel)
end

function M.describe()
    return {
        mod_name = mod_name,
        world = world_path,
        mod = mod_path,
        game = game_path,
        runtime_scripts = M.roots.runtime_scripts,
        worldmods = M.roots.worldmods,
    }
end

core.log("action", "[path_policy] stack roots: world=" .. tostring(world_path) .. ", mod=" .. tostring(mod_path) .. ", game=" .. tostring(game_path))

return M
