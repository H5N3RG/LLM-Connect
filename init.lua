-- ===========================================================================
--  LLM Connect Init v0.9.0-dev
--  author: H5N3RG
--  license: LGPL-3.0-or-later
-- ===========================================================================

local core = core
local mod_dir = core.get_modpath("llm_connect")

-- === HTTP API ===
local http = core.request_http_api()
if not http then
    core.log("error", "[llm_connect] HTTP API not available! Add 'llm_connect' to secure.http_mods in minetest.conf!")
    return
end

-- === Privileges ===
core.register_privilege("llm", {
    description = "LLM Connect: /llm chat interface (chat mode only)",
    give_to_singleplayer = true,
    give_to_admin = true,
})

core.register_privilege("llm_dev", {
    description = "LLM Connect: Smart Lua IDE + sandbox code execution (whitelist limited)",
    give_to_singleplayer = false,
    give_to_admin = false,
})

core.register_privilege("llm_worldedit", {
    description = "LLM Connect: WorldEdit agency (WE Single + WE Loop + material picker)",
    give_to_singleplayer = false,
    give_to_admin = false,
})

core.register_privilege("llm_root", {
    description = "LLM Connect: Full access (implies llm + llm_dev + llm_worldedit). Config, unrestricted execution, persistent code.",
    give_to_singleplayer = false,
    give_to_admin = true,
})

-- === Load central LLM API module ===
local llm_api_ok, llm_api = pcall(dofile, mod_dir .. "/llm_api.lua")
if not llm_api_ok or not llm_api then
    core.log("error", "[llm_connect] Failed to load llm_api.lua: " .. tostring(llm_api))
    return
end
if not llm_api.init(http) then
    core.log("error", "[llm_connect] Failed to initialize llm_api")
    return
end

-- === Load code executor ===
local executor_ok, executor = pcall(dofile, mod_dir .. "/code_executor.lua")
if not executor_ok or not executor then
    core.log("error", "[llm_connect] Failed to load code_executor.lua: " .. tostring(executor))
    return
end

-- === Load GUI modules ===
local chat_gui_ok, chat_gui = pcall(dofile, mod_dir .. "/chat_gui.lua")
if not chat_gui_ok then
    core.log("error", "[llm_connect] Failed to load chat_gui.lua: " .. tostring(chat_gui))
    return
end

local ide_gui_ok, ide_gui = pcall(dofile, mod_dir .. "/ide_gui.lua")
if not ide_gui_ok then
    core.log("error", "[llm_connect] Failed to load ide_gui.lua: " .. tostring(ide_gui))
    return
end

local config_gui_ok, config_gui = pcall(dofile, mod_dir .. "/config_gui.lua")
if not config_gui_ok then
    core.log("error", "[llm_connect] Failed to load config_gui.lua: " .. tostring(config_gui))
    return
end

-- === Load helpers ===
local chat_context_ok, chat_context = pcall(dofile, mod_dir .. "/chat_context.lua")
if not chat_context_ok then
    core.log("warning", "[llm_connect] chat_context.lua not loaded: " .. tostring(chat_context))
    chat_context = nil
end

-- === Load WorldEdit agency module (optional dependency) ===
local we_agency_ok, we_agency = pcall(dofile, mod_dir .. "/llm_worldedit.lua")
if not we_agency_ok then
    core.log("warning", "[llm_connect] llm_worldedit.lua failed to load: " .. tostring(we_agency))
    we_agency = nil
elseif not we_agency.is_available() then
    core.log("warning", "[llm_connect] WorldEdit not detected at load time – agency mode disabled")
    core.log("warning", "[llm_connect] worldedit global type: " .. type(worldedit))
    -- NOTE: we_agency is still set as global – we_available() checks at runtime
    -- so WE buttons may still appear if worldedit loads later (should not happen with optional_depends)
end

-- === Load material picker ===
local picker_ok, material_picker = pcall(dofile, mod_dir .. "/material_picker.lua")
if not picker_ok then
    core.log("warning", "[llm_connect] material_picker.lua not loaded: " .. tostring(material_picker))
    material_picker = nil
end

-- === Make modules globally available ===
_G.chat_gui        = chat_gui
_G.llm_api         = llm_api
_G.executor        = executor
_G.we_agency       = we_agency
_G.material_picker = material_picker
_G.ide_gui         = ide_gui
_G.config_gui      = config_gui

-- === Startup code loader ===
local startup_file = core.get_worldpath() .. "/llm_startup.lua"

local function load_startup_code()
    local f = io.open(startup_file, "r")
    if f then
        f:close()
        core.log("action", "[llm_connect] Loading startup code from " .. startup_file)
        local ok, err = pcall(dofile, startup_file)
        if not ok then
            core.log("error", "[llm_connect] Startup code error: " .. tostring(err))
            core.log("error", "[llm_connect] Fix the error in llm_startup.lua and restart the server")
        else
            core.log("action", "[llm_connect] Startup code loaded successfully")
        end
    else
        core.log("action", "[llm_connect] No llm_startup.lua found (this is normal on first run)")
    end
end

load_startup_code()

-- === Chat Commands ===

core.register_chatcommand("llm", {
    description = "Opens the LLM chat interface",
    privs = {llm = true},
    func = function(name)
        chat_gui.show(name)
        return true, "Opening LLM chat..."
    end,
})

core.register_chatcommand("llm_msg", {
    params = "<message>",
    description = "Send a direct message to the LLM (text-only, no GUI)",
    privs = {llm = true},
    func = function(name, param)
        if not param or param == "" then
            return false, "Usage: /llm_msg <your question>"
        end
        local messages = {{role = "user", content = param}}
        llm_api.request(messages, function(result)
            if result.success then
                core.chat_send_player(name, "[LLM] " .. (result.content or "(no response)"))
            else
                core.chat_send_player(name, "[LLM] Error: " .. (result.error or "unknown error"))
            end
        end, {timeout = llm_api.get_timeout("chat")})
        return true, "Request sent..."
    end,
})

core.register_chatcommand("llm_undo", {
    description = "Undo the last WorldEdit agency operation",
    privs = {llm = true},
    func = function(name)
        if not _G.we_agency then
            return false, "WorldEdit agency module not loaded"
        end
        local res = _G.we_agency.undo(name)
        return res.ok, "[LLM] " .. res.message
    end,
})

core.register_chatcommand("llm_reload_startup", {
    description = "Reload llm_startup.lua (WARNING: Cannot register new items!)",
    privs = {llm_root = true},
    func = function(name)
        core.log("action", "[llm_connect] Manual startup reload triggered by " .. name)
        core.chat_send_player(name, "[LLM] WARNING: Reloading startup code at runtime")
        core.chat_send_player(name, "[LLM] New registrations will FAIL. Restart server for registrations.")
        local f = io.open(startup_file, "r")
        if f then
            f:close()
            local ok, err = pcall(dofile, startup_file)
            if not ok then
                core.chat_send_player(name, "[LLM] x Reload failed: " .. tostring(err))
                return false, "Reload failed"
            else
                core.chat_send_player(name, "[LLM] Reloaded (restart needed for registrations)")
                return true, "Code reloaded"
            end
        else
            core.chat_send_player(name, "[LLM] x No llm_startup.lua found")
            return false, "File not found"
        end
    end,
})

-- === Central formspec handler ===
core.register_on_player_receive_fields(function(player, formname, fields)
    if not player then return false end
    local name = player:get_player_name()

    if formname:match("^llm_connect:chat") or formname:match("^llm_connect:material_picker") then
        return chat_gui.handle_fields(name, formname, fields)
    elseif formname:match("^llm_connect:ide") then
        return ide_gui.handle_fields(name, formname, fields)
    elseif formname:match("^llm_connect:config") then
        return config_gui.handle_fields(name, formname, fields)
    end

    return false
end)

-- === Logging ===
core.log("action", "[llm_connect] LLM Connect v0.9.0 loaded")
if llm_api.is_configured() then
    core.log("action", "[llm_connect] LLM API ready - model: " .. tostring(llm_api.config.model))
else
    core.log("warning", "[llm_connect] LLM API not configured yet - use /llm and open Config button")
end
