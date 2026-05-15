-- ===========================================================================
--  gui_init.lua — GUI subsystem loader for LLM Connect 1.2.0-dev
--
--  Purpose:
--    Load all formspec/front-end modules through one boundary. GUI modules are
--    frontends only; execution and persistence are delegated to runtime/*.
--    Submodule failures are reported through llm_connect.health and converted
--    into small fallback frontends instead of nil-crashing the whole mod.
-- ===========================================================================

local core = core
local M = {}
local health = rawget(_G, "llm_connect") and _G.llm_connect.health or nil

local mod_dir = core.get_modpath(core.get_current_modname())
local GUI_DIR = mod_dir .. "/gui"

local function mark_ok(name, msg)
    if health and health.mark_ok then health.mark_ok("gui." .. tostring(name), { message = msg or "loaded" }) end
end

local function mark_failed(name, err)
    if health and health.mark_failed then health.mark_failed("gui." .. tostring(name), err) end
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function unavailable_module(name, reason)
    local message = tostring(reason or "module unavailable")
    return {
        __unavailable = true,
        __name = name,
        __reason = message,
        show = function(player_name)
            if player_name and core.chat_send_player then
                core.chat_send_player(player_name, "[LLM] GUI module unavailable: " .. tostring(name) .. " — " .. message)
            end
            return false
        end,
        handle_fields = function(player_name)
            if player_name and core.chat_send_player then
                core.chat_send_player(player_name, "[LLM] GUI handler unavailable: " .. tostring(name) .. " — " .. message)
            end
            return true
        end,
    }
end

local function load_gui_module(name, filename, required)
    local path = GUI_DIR .. "/" .. filename
    if not file_exists(path) then
        local msg = "GUI module missing: " .. name .. " (" .. path .. ")"
        core.log("warning", "[gui_init] " .. msg)
        mark_failed(name, msg)
        local fallback = unavailable_module(name, msg)
        M[name] = fallback
        return fallback
    end

    local ok, module = pcall(dofile, path)
    if not ok then
        local msg = (required and "required" or "optional") .. " GUI module failed: " .. name .. " (" .. path .. ") — " .. tostring(module)
        core.log("warning", "[gui_init] " .. msg)
        mark_failed(name, msg)
        local fallback = unavailable_module(name, msg)
        M[name] = fallback
        return fallback
    end
    if module == nil then
        local msg = (required and "required" or "optional") .. " GUI module returned nil: " .. name .. " (" .. path .. ")"
        core.log("warning", "[gui_init] " .. msg)
        mark_failed(name, msg)
        local fallback = unavailable_module(name, msg)
        M[name] = fallback
        return fallback
    end

    M[name] = module
    mark_ok(name)
    return module
end

-- Deterministic dependency order. IDE helpers first, main/config last.
M.ide_storage        = load_gui_module("ide_storage", "ide_storage.lua", false)
M.code_executor      = load_gui_module("code_executor", "code_executor.lua", false)
M.ide_asset_picker   = load_gui_module("ide_asset_picker", "ide_asset_picker.lua", false)
M.ide_file_manager   = load_gui_module("ide_file_manager", "ide_file_manager.lua", false)
M.ide_system_prompts = load_gui_module("ide_system_prompts", "ide_system_prompts.lua", false)
M.ide_gui            = load_gui_module("ide_gui", "ide_gui.lua", false)
M.main_gui           = load_gui_module("main_gui", "main_gui.lua", true)
M.config_gui         = load_gui_module("config_gui", "config_gui.lua", true)

local function module_ok(module, method)
    return type(module) == "table" and not module.__unavailable and type(module[method]) == "function"
end

function M.is_available(name)
    local module = M[name]
    return type(module) == "table" and not module.__unavailable
end

function M.status()
    local out = {}
    for _, name in ipairs({"main_gui", "config_gui", "ide_gui", "ide_storage", "code_executor", "ide_asset_picker", "ide_file_manager", "ide_system_prompts"}) do
        local module = M[name]
        out[name] = {
            ok = type(module) == "table" and not module.__unavailable,
            reason = type(module) == "table" and module.__reason or nil,
        }
    end
    return out
end

function M.show(player_name, view, ...)
    if view == "config" and module_ok(M.config_gui, "show") then return M.config_gui.show(player_name, ...) end
    if view == "ide" and module_ok(M.ide_gui, "show") then return M.ide_gui.show(player_name, ...) end
    if view == "skills" and module_ok(M.main_gui, "show_skills") then return M.main_gui.show_skills(player_name, ...) end
    if module_ok(M.main_gui, "show") then return M.main_gui.show(player_name, ...) end

    core.chat_send_player(player_name, "[LLM] GUI unavailable: main GUI did not load. Use /llm_health for details.")
    return false
end

function M.handle_fields(player_name, formname, fields)
    formname = tostring(formname or "")
    if formname:match("^llm_connect:config") then
        if module_ok(M.config_gui, "handle_fields") then return M.config_gui.handle_fields(player_name, formname, fields) end
        core.chat_send_player(player_name, "[LLM] Config GUI unavailable. Use /llm_health for details.")
        return true
    end
    if formname:match("^llm_connect:ide") then
        if module_ok(M.ide_gui, "handle_fields") then return M.ide_gui.handle_fields(player_name, formname, fields) end
        core.chat_send_player(player_name, "[LLM] IDE GUI unavailable. Use /llm_health for details.")
        return true
    end
    if module_ok(M.main_gui, "handle_fields") then
        return M.main_gui.handle_fields(player_name, formname, fields)
    end
    core.chat_send_player(player_name, "[LLM] GUI unavailable: no handler for " .. tostring(formname))
    return true
end

_G.llm_connect = rawget(_G, "llm_connect") or {}
_G.llm_connect.gui = M

-- Legacy globals kept for old GUI modules and external debug snippets. They may
-- point at fallback modules, but they are never nil after gui_init completes.
_G.ide_storage = M.ide_storage
_G.code_executor = M.code_executor
_G.ide_asset_picker = M.ide_asset_picker
_G.ide_file_manager = M.ide_file_manager
_G.ide_system_prompts = M.ide_system_prompts
_G.ide_gui = M.ide_gui
_G.main_gui = M.main_gui
_G.config_gui = M.config_gui

core.log("action", "[gui_init] GUI subsystem loaded")

return M
