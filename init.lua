-- ===========================================================================
--  init.lua — LLM Connect 1.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  LOAD ORDER:
--    1. HTTP-API sichern
--    2. Privileges registrieren
--    3. llm_api.lua          — HTTP-Layer, API-Konfiguration
--    4. basic_context.lua    — Basiskontext-Provider (Basis + Erweitert)
--    5. registry.lua         — Addon-Gateway, _G.llm_connect setzen
--       └ registry.expose_global()     → _G.llm_connect.registry bereit
--       └ registry.load_internal()     → addons/ scannen (außer smart_lua_ide)
--    6. agent.lua            — Agent-Orchestrator
--    7. addons/smart_lua_ide/ — First-Class Sub-System, direkt geladen
--       └ code_executor.lua
--       └ ide_asset_picker.lua
--       └ ide_gui.lua
--    8. main_gui.lua         — Haupt-UI (Chat + Agent-Panel)
--    9. config_gui.lua       — Einstellungs-GUI (inkl. Kontext-Layer-Picker)
--   10. on_mods_loaded:
--       └ registry.discover_external() → externe Addon-Mods einbinden
--   11. Chat-Commands registrieren
--   12. Formspec-Handler registrieren
--   13. llm_startup.lua laden (falls vorhanden)
--
-- ===========================================================================

local mod_name = core.get_current_modname()
local mod_dir  = core.get_modpath(mod_name)
local IDE_DIR  = mod_dir .. "/smart_lua_ide"

-- Helper: load a file with error handling
-- fatal=true  → aborts init on error (hard failure)
-- fatal=false → logs a warning, returns nil (optional module)
local function load_module(path, label, fatal)
    local ok, result = pcall(dofile, path)
    if not ok then
        if fatal then
            core.log("error", string.format(
                "[llm_connect] FATAL: %s could not be loaded: %s",
                label, tostring(result)))
            error("[llm_connect] init aborted — " .. label .. " failed")
        else
            core.log("warning", string.format(
                "[llm_connect] %s not loaded: %s", label, tostring(result)))
            return nil
        end
    end
    if result == nil and fatal then
        core.log("error", "[llm_connect] FATAL: " .. label .. " returned nil")
        error("[llm_connect] init aborted — " .. label .. " returned nil")
    end
    core.log("action", "[llm_connect] ✓ " .. label .. " loaded")
    return result
end

-- ===========================================================================
-- 1. Acquire HTTP API
-- ===========================================================================

local http = core.request_http_api()
if not http then
    core.log("error",
        "[llm_connect] HTTP API not available — 'llm_connect' must be listed in" ..
        " secure.http_mods in minetest.conf")
    return
end

-- ===========================================================================
-- 2. Register privileges
-- ===========================================================================

core.register_privilege("llm", {
    description  = "Access to LLM Connect AI chat",
    give_to_singleplayer = true,
})

core.register_privilege("llm_dev", {
    description  = "Access to Smart Lua IDE and sandboxed code execution",
    give_to_singleplayer = false,
    give_to_admin = true,
})

core.register_privilege("llm_agent", {
    description  = "Access to LLM Connect agent mode and addon tools",
    give_to_singleplayer = false,
    give_to_admin = true,
})

core.register_privilege("llm_root", {
    description  = "Full LLM Connect access — implies llm, llm_dev, llm_agent." ..
                   " Config, unrestricted execution, persistent code.",
    give_to_singleplayer = false,
    give_to_admin = true,
})

-- ===========================================================================
-- 3. LLM API
-- ===========================================================================

local llm_api = load_module(mod_dir .. "/llm_api.lua", "llm_api", true)

if not llm_api.init(http) then
    core.log("error", "[llm_connect] LLM API init failed")
    return
end

-- ===========================================================================
-- 4. Basic context
-- ===========================================================================

local basic_context = load_module(mod_dir .. "/basic_context.lua", "basic_context", true)

-- ===========================================================================
-- 5. Registry — addon gateway
-- ===========================================================================

local registry = load_module(mod_dir .. "/registry.lua", "registry", true)

-- Set global namespace: _G.llm_connect.registry ready for external mods
registry.expose_global()

-- Load internal addons immediately (addons/ except smart_lua_ide)
registry.load_internal()

-- ===========================================================================
-- 6. Agent orchestrator
-- ===========================================================================

local agent = load_module(mod_dir .. "/agent.lua", "agent", true)

-- Expose agent in global namespace
_G.llm_connect.agent = agent

-- ===========================================================================
-- 7. Smart Lua IDE — first-class sub-system
--    Loaded directly by init.lua, NOT through the registry.
--    Load order within the IDE matters:
--      code_executor → ide_asset_picker → ide_gui (ide_gui depends on both)
-- ===========================================================================

local code_executor    = load_module(IDE_DIR .. "/code_executor.lua",    "code_executor",    false)
local ide_asset_picker = load_module(IDE_DIR .. "/ide_asset_picker.lua", "ide_asset_picker", false)
local ide_gui          = load_module(IDE_DIR .. "/ide_gui.lua",          "ide_gui",          false)

-- Expose IDE modules as globals so ide_gui.lua can resolve them at call time
_G.code_executor    = code_executor
_G.ide_asset_picker = ide_asset_picker
_G.ide_gui          = ide_gui

-- ===========================================================================
-- 8. Main GUI (Chat + Agent panel)
-- ===========================================================================

local main_gui = load_module(mod_dir .. "/main_gui.lua", "main_gui", true)

-- ===========================================================================
-- 9. Config GUI
-- ===========================================================================

local config_gui = load_module(mod_dir .. "/config_gui.lua", "config_gui", true)

-- ===========================================================================
-- Expose remaining modules as globals
-- Required by config_gui, main_gui, agent, and addon code that resolves
-- dependencies at call time via _G rather than at load time.
-- ===========================================================================

_G.llm_api       = llm_api        -- used by config_gui, main_gui, agent, IDE
_G.basic_context = basic_context  -- used by agent (do_iteration)
_G.registry      = registry       -- used by agent (get_registry fallback)
_G.main_gui      = main_gui       -- used by config_gui close, ide_gui close
_G.config_gui    = config_gui     -- used by main_gui open_config button

-- ===========================================================================
-- 10. Load external addon mods (after mods_loaded)
--     At this point external mods have already called register() explicitly
--     (if they declared optional_depends = llm_connect).
--     discover_external() additionally scans for llm_connect_addon.lua files.
-- ===========================================================================

core.register_on_mods_loaded(function()
    registry.discover_external()
    core.log("action", string.format(
        "[llm_connect] ready — %d addon(s) registered",
        (function() local n=0; for _ in pairs(registry.addons) do n=n+1 end; return n end)()))
end)

-- ===========================================================================
-- 11. Chat commands
-- ===========================================================================

core.register_chatcommand("llm", {
    description = "Open the LLM Connect chat interface",
    privs       = { llm = true },
    func = function(name, _)
        main_gui.show(name)
        return true
    end,
})

core.register_chatcommand("llm_config", {
    description = "Open LLM Connect configuration",
    privs       = { llm = true },
    func = function(name, _)
        config_gui.show(name)
        return true
    end,
})

core.register_chatcommand("llm_config_reload", {
    description = "Reload LLM Connect settings without server restart",
    privs       = { llm_root = true },
    func = function(name, _)
        local ok, err = pcall(llm_api.reload_config)
        if ok then
            core.chat_send_player(name, "[LLM] ✓ Configuration reloaded")
            return true
        else
            core.chat_send_player(name, "[LLM] ✗ Error: " .. tostring(err))
            return false, tostring(err)
        end
    end,
})

-- Startup-Code manuell neu laden (llm_root)
local startup_file = core.get_worldpath() .. "/llm_startup.lua"

core.register_chatcommand("llm_startup_reload", {
    description = "Re-execute llm_startup.lua at runtime (new registrations will fail — restart required)",
    privs       = { llm_root = true },
    func = function(name, _)
        local f = io.open(startup_file, "r")
        if not f then
            core.chat_send_player(name, "[LLM] ✗ No llm_startup.lua found")
            return false, "file not found"
        end
        f:close()
        core.log("action", "[llm_connect] startup code manually reloaded by " .. name)
        core.chat_send_player(name,
            "[LLM] ⚠ Running startup code — new registrations will fail!")
        local ok, err = pcall(dofile, startup_file)
        if ok then
            core.chat_send_player(name, "[LLM] ✓ Executed (restart for registrations to take effect)")
            return true
        else
            core.chat_send_player(name, "[LLM] ✗ Error: " .. tostring(err))
            return false, tostring(err)
        end
    end,
})

-- ===========================================================================
-- 12. Central formspec handler
-- ===========================================================================

core.register_on_player_receive_fields(function(player, formname, fields)
    if not player then return false end
    local name = player:get_player_name()

    -- Main GUI: chat + agent panel
    if formname:match("^llm_connect:main") or
       formname:match("^llm_connect:chat") or
       formname:match("^llm_connect:agent") then
        return main_gui.handle_fields(name, formname, fields)

    -- Smart Lua IDE
    elseif formname:match("^llm_connect:ide") then
        if _G.ide_gui then
            return _G.ide_gui.handle_fields(name, formname, fields)
        end

    -- Config GUI
    elseif formname:match("^llm_connect:config") then
        return config_gui.handle_fields(name, formname, fields)
    end

    return false
end)

-- ===========================================================================
-- 13. Load startup code (llm_startup.lua in world directory)
-- ===========================================================================

local function load_startup_code()
    local f = io.open(startup_file, "r")
    if not f then return end
    f:close()
    core.log("action", "[llm_connect] loading startup code: " .. startup_file)
    local ok, err = pcall(dofile, startup_file)
    if not ok then
        core.log("error", "[llm_connect] startup code error: " .. tostring(err))
    end
end

load_startup_code()

-- ===========================================================================

core.log("action", "[llm_connect] LLM Connect 1.0.0-dev init complete")
