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

-- Hilfsfunktion: Datei laden mit Fehlerbehandlung
-- fatal=true → bricht init ab bei Fehler (harter Fehler)
-- fatal=false → loggt Warnung, gibt nil zurück (optionales Modul)
local function load_module(path, label, fatal)
    local ok, result = pcall(dofile, path)
    if not ok then
        if fatal then
            core.log("error", string.format(
                "[llm_connect] FATAL: %s konnte nicht geladen werden: %s",
                label, tostring(result)))
            error("[llm_connect] Init abgebrochen — " .. label .. " fehlgeschlagen")
        else
            core.log("warning", string.format(
                "[llm_connect] %s nicht geladen: %s", label, tostring(result)))
            return nil
        end
    end
    if result == nil and fatal then
        core.log("error", "[llm_connect] FATAL: " .. label .. " gab nil zurück")
        error("[llm_connect] Init abgebrochen — " .. label .. " gab nil zurück")
    end
    core.log("action", "[llm_connect] ✓ " .. label .. " geladen")
    return result
end

-- ===========================================================================
-- 1. HTTP-API sichern
-- ===========================================================================

local http = core.request_http_api()
if not http then
    core.log("error",
        "[llm_connect] HTTP-API nicht verfügbar — 'llm_connect' muss in" ..
        " secure.http_mods in der minetest.conf eingetragen sein")
    return
end

-- ===========================================================================
-- 2. Privileges registrieren
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
    core.log("error", "[llm_connect] LLM API init fehlgeschlagen")
    return
end

-- ===========================================================================
-- 4. Basic Context
-- ===========================================================================

local basic_context = load_module(mod_dir .. "/basic_context.lua", "basic_context", true)

-- ===========================================================================
-- 5. Registry — Addon-Gateway
-- ===========================================================================

local registry = load_module(mod_dir .. "/registry.lua", "registry", true)

-- Globalen Namespace setzen: _G.llm_connect.registry bereit für externe Mods
registry.expose_global()

-- Interne Addons sofort laden (addons/ außer smart_lua_ide)
registry.load_internal()

-- ===========================================================================
-- 6. Agent Orchestrator
-- ===========================================================================

local agent = load_module(mod_dir .. "/agent.lua", "agent", true)

-- Agent in globalem Namespace verfügbar machen
_G.llm_connect.agent = agent

-- ===========================================================================
-- 7. Smart Lua IDE — First-Class Sub-System
--    Direkt von init.lua geladen, NICHT über registry.
--    Reihenfolge innerhalb der IDE ist wichtig:
--      code_executor → ide_asset_picker → ide_gui (hängt von beiden ab)
-- ===========================================================================

local code_executor  = load_module(IDE_DIR .. "/code_executor.lua",  "code_executor",  false)
local ide_asset_picker = load_module(IDE_DIR .. "/ide_asset_picker.lua", "ide_asset_picker", false)
local ide_gui        = load_module(IDE_DIR .. "/ide_gui.lua",         "ide_gui",         false)

-- ===========================================================================
-- 8. Haupt-GUI (Chat + Agent-Panel)
-- ===========================================================================

local main_gui = load_module(mod_dir .. "/main_gui.lua", "main_gui", true)

-- ===========================================================================
-- 9. Config-GUI
-- ===========================================================================

local config_gui = load_module(mod_dir .. "/config_gui.lua", "config_gui", true)

-- ===========================================================================
-- 10. Externe Addon-Mods einbinden (nach mods_loaded)
--     Zu diesem Zeitpunkt haben externe Mods bereits explizit register()
--     aufgerufen (wenn sie optional_depends = llm_connect haben).
--     discover_external() findet zusätzlich llm_connect_addon.lua Dateien.
-- ===========================================================================

core.register_on_mods_loaded(function()
    registry.discover_external()
    core.log("action", string.format(
        "[llm_connect] Bereit — %d Addon(s) registriert",
        (function() local n=0; for _ in pairs(registry.addons) do n=n+1 end; return n end)()))
end)

-- ===========================================================================
-- 11. Chat-Commands
-- ===========================================================================

core.register_chatcommand("llm_config", {
    description = "LLM Connect Konfiguration öffnen",
    privs       = { llm = true },
    func = function(name, _)
        config_gui.show(name)
        return true
    end,
})

core.register_chatcommand("llm_config_reload", {
    description = "LLM Connect Einstellungen neu laden (ohne Serverneustart)",
    privs       = { llm_root = true },
    func = function(name, _)
        local ok, err = pcall(llm_api.reload_config)
        if ok then
            core.chat_send_player(name, "[LLM] ✓ Konfiguration neu geladen")
            return true
        else
            core.chat_send_player(name, "[LLM] ✗ Fehler: " .. tostring(err))
            return false, tostring(err)
        end
    end,
})

-- Startup-Code manuell neu laden (llm_root)
local startup_file = core.get_worldpath() .. "/llm_startup.lua"

core.register_chatcommand("llm_startup_reload", {
    description = "llm_startup.lua manuell neu ausführen (Neuregistrierungen schlagen fehl — Neustart nötig)",
    privs       = { llm_root = true },
    func = function(name, _)
        local f = io.open(startup_file, "r")
        if not f then
            core.chat_send_player(name, "[LLM] ✗ Keine llm_startup.lua gefunden")
            return false, "Datei nicht gefunden"
        end
        f:close()
        core.log("action", "[llm_connect] Startup-Code manuell neu geladen von " .. name)
        core.chat_send_player(name,
            "[LLM] ⚠ Startup-Code wird ausgeführt — Neuregistrierungen schlagen fehl!")
        local ok, err = pcall(dofile, startup_file)
        if ok then
            core.chat_send_player(name, "[LLM] ✓ Ausgeführt (Neustart für Registrierungen)")
            return true
        else
            core.chat_send_player(name, "[LLM] ✗ Fehler: " .. tostring(err))
            return false, tostring(err)
        end
    end,
})

-- ===========================================================================
-- 12. Zentraler Formspec-Handler
-- ===========================================================================

core.register_on_player_receive_fields(function(player, formname, fields)
    if not player then return false end
    local name = player:get_player_name()

    -- Haupt-GUI: Chat + Agent-Panel
    if formname:match("^llm_connect:main") or
       formname:match("^llm_connect:chat") or
       formname:match("^llm_connect:agent") then
        return main_gui.handle_fields(name, formname, fields)

    -- Smart Lua IDE
    elseif formname:match("^llm_connect:ide") then
        if ide_gui then
            return ide_gui.handle_fields(name, formname, fields)
        end

    -- Config-GUI (inkl. Kontext-Layer-Picker)
    elseif formname:match("^llm_connect:config") then
        return config_gui.handle_fields(name, formname, fields)
    end

    return false
end)

-- ===========================================================================
-- 13. Startup-Code laden (llm_startup.lua im World-Verzeichnis)
-- ===========================================================================

local function load_startup_code()
    local f = io.open(startup_file, "r")
    if not f then return end
    f:close()
    core.log("action", "[llm_connect] Startup-Code laden: " .. startup_file)
    local ok, err = pcall(dofile, startup_file)
    if not ok then
        core.log("error", "[llm_connect] Startup-Code Fehler: " .. tostring(err))
    end
end

load_startup_code()

-- ===========================================================================

core.log("action", "[llm_connect] LLM Connect 1.0.0-dev init abgeschlossen")
