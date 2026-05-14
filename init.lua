-- ===========================================================================
--  init.lua — LLM Connect 1.1.0-dev
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  LOAD ORDER:
--    1. Preserve HTTP API handle
--    2. Register privileges
--    3. llm_api.lua          — HTTP layer, API configuration
--    4. parser_utils.lua     — LLM output parsing / repair
--    5. basic_context.lua    — base context provider (basic + extended)
--    6. registry.lua         — skill gateway, set _G.llm_connect
--       └ registry.expose_global()     → expose _G.llm_connect.registry
--    7. context_registry.lua — agent self-context / retrieval layer
--       └ registry.load_internal()     → load built-in skills after context exists
--    8. execution_policy.lua — central root/dev execution policy
--    9. path_policy.lua      — stack-relative filesystem roots
--   10. storage_backends.lua — robust dir-list / filesystem helper layer
--   11. runtime_scripts.lua  — IDE persistence + hot-reload backend
--   12. trusted_mods.lua     — root-only trusted worldmod backend
--   13. core_executor.lua    — Shared Lua Runtime Backend
--   14. agent.lua            — Agent-Orchestrator
--   15. smart_lua_ide/       — first-class frontend, loaded directly
--       └ ide_storage.lua    — backend bridge for IDE persistence
--       └ code_executor.lua  — legacy shim to core_executor
--       └ ide_asset_picker.lua
--       └ ide_file_manager.lua
--       └ ide_gui.lua
--   15. main_gui.lua         — main UI (chat + agent panel)
--   16. config_gui.lua       — settings UI including context-layer picker
--   10. on_mods_loaded:
--       └ registry.discover_external() → load external addon mods
--   11. Main GUI and config GUI
--   12. Register formspec handlers
--   13. Load llm_startup.lua if present
--
-- ===========================================================================

local mod_name = core.get_current_modname()
local mod_dir  = core.get_modpath(mod_name)
local IDE_DIR  = mod_dir .. "/smart_lua_ide"

_G.llm_connect = rawget(_G, "llm_connect") or {}

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
-- 3. Optional raw prompt/response trace logger
-- ===========================================================================

local prompt_trace = load_module(mod_dir .. "/prompt_trace.lua", "prompt_trace", false)
_G.llm_connect.prompt_trace = prompt_trace
_G.prompt_trace = prompt_trace

-- ===========================================================================
-- 4. LLM API
-- ===========================================================================

local llm_api = load_module(mod_dir .. "/llm_api.lua", "llm_api", true)

if not llm_api.init(http) then
    core.log("error", "[llm_connect] LLM API init failed")
    return
end

-- ===========================================================================
-- 4. Parser utils
-- ===========================================================================

local parser_utils = load_module(mod_dir .. "/parser_utils.lua", "parser_utils", true)

-- ===========================================================================
-- 5. Basic context
-- ===========================================================================

local basic_context = load_module(mod_dir .. "/basic_context.lua", "basic_context", true)

-- ===========================================================================
-- 6. Registry — addon gateway
-- ===========================================================================

local registry = load_module(mod_dir .. "/registry.lua", "registry", true)

-- Set global namespace: _G.llm_connect.registry ready for external mods
registry.expose_global()

-- ===========================================================================
-- 7. Context registry — Lua-native agent self-context retrieval
-- ===========================================================================

local context_registry = load_module(mod_dir .. "/context_registry.lua", "context_registry", true)
_G.llm_connect.context_registry = context_registry
_G.llm_connect.context = context_registry
_G.context_registry = context_registry

-- Load internal skills after the context layer exists, so skills may register
-- on-demand documentation sections without bloating the system prompt.
registry.load_internal()

-- ===========================================================================
-- 8. Execution policy
-- ===========================================================================

local execution_policy = load_module(mod_dir .. "/execution_policy.lua", "execution_policy", true)
_G.llm_connect.policy = execution_policy
_G.llm_connect.parser_utils = parser_utils
_G.parser_utils = parser_utils

-- ===========================================================================
-- 8. Path policy — stack-relative filesystem roots
-- ===========================================================================

local path_policy = load_module(mod_dir .. "/path_policy.lua", "path_policy", true)
_G.llm_connect.path_policy = path_policy
_G.path_policy = path_policy

-- ===========================================================================
-- 9. IDE persistence / hot-reload backends
-- ===========================================================================

local storage_backends = load_module(mod_dir .. "/storage_backends.lua", "storage_backends", true)
_G.llm_connect.storage_backends = storage_backends
_G.storage_backends = storage_backends

local runtime_scripts = load_module(mod_dir .. "/runtime_scripts.lua", "runtime_scripts", true)
_G.llm_connect.runtime_scripts = runtime_scripts
_G.runtime_scripts = runtime_scripts

local trusted_mods = load_module(mod_dir .. "/trusted_mods.lua", "trusted_mods", false)
_G.llm_connect.trusted_mods = trusted_mods
_G.trusted_mods = trusted_mods

-- ===========================================================================
-- 9. Core executor — shared Lua runtime backend
-- ===========================================================================

local core_executor = load_module(mod_dir .. "/core_executor.lua", "core_executor", true)
_G.llm_connect.core_executor = core_executor
_G.core_executor = core_executor

-- ===========================================================================
-- 10. Agent orchestrator
-- ===========================================================================

local agent = load_module(mod_dir .. "/agent.lua", "agent", true)

-- Expose agent in global namespace
_G.llm_connect.agent = agent

-- ===========================================================================
-- 11. Smart Lua IDE — first-class sub-system
--    Loaded directly by init.lua, NOT through the registry.
--    Load order within the IDE matters:
--      ide_storage → code_executor → ide_asset_picker → ide_gui
-- ===========================================================================

local ide_storage      = load_module(IDE_DIR .. "/ide_storage.lua",      "ide_storage",      false)
local code_executor    = load_module(IDE_DIR .. "/code_executor.lua",    "code_executor_legacy_shim", false)
local ide_asset_picker = load_module(IDE_DIR .. "/ide_asset_picker.lua", "ide_asset_picker", false)
local ide_file_manager = load_module(IDE_DIR .. "/ide_file_manager.lua", "ide_file_manager", false)
local ide_gui          = load_module(IDE_DIR .. "/ide_gui.lua",          "ide_gui",          false)

-- Expose IDE modules as globals so ide_gui.lua can resolve them at call time
_G.ide_storage      = ide_storage
_G.code_executor    = code_executor
_G.ide_asset_picker = ide_asset_picker
_G.ide_file_manager = ide_file_manager
_G.ide_gui          = ide_gui

-- ===========================================================================
-- 11. Main GUI (Chat + Agent panel)
-- ===========================================================================

local main_gui = load_module(mod_dir .. "/main_gui.lua", "main_gui", true)

-- ===========================================================================
-- 12. Config GUI
-- ===========================================================================

local config_gui = load_module(mod_dir .. "/config_gui.lua", "config_gui", true)

-- ===========================================================================
-- Expose remaining modules as globals
-- Required by config_gui, main_gui, agent, and addon code that resolves
-- dependencies at call time via _G rather than at load time.
-- ===========================================================================

_G.llm_api       = llm_api        -- used by config_gui, main_gui, agent, IDE
_G.parser_utils  = parser_utils   -- used by agent/core_executor
_G.runtime_scripts = runtime_scripts -- used by IDE/core_executor
_G.trusted_mods = trusted_mods    -- optional root-only trusted worldmod backend
_G.core_executor = core_executor  -- shared IDE/Agent/Skill runtime
_G.basic_context = basic_context  -- used by agent.lua
_G.context_registry = context_registry -- used by agent/core_executor/skills
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
        "[llm_connect] ready — %d Lua-first skill(s) registered",
        (function() local n=0; for _ in pairs(registry.skills or {}) do n=n+1 end; return n end)()))
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

-- Manually reload startup code (llm_root)
local startup_file = (_G.llm_connect and _G.llm_connect.path_policy and _G.llm_connect.path_policy.startup_file()) or (core.get_worldpath() .. "/llm_startup.lua")

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
        if not execution_policy.can_chat(name) then return true end
        return main_gui.handle_fields(name, formname, fields)

    -- Smart Lua IDE and IDE sub-formspecs
    elseif formname:match("^llm_connect:ide") then
        if not execution_policy.can_ide(name) then
            core.chat_send_player(name, "[LLM] Missing privilege: llm_dev (or llm_root)")
            return true
        end
        if _G.ide_gui then
            return _G.ide_gui.handle_fields(name, formname, fields)
        end

    -- Config GUI
    elseif formname:match("^llm_connect:config") then
        if not execution_policy.can_config(name) then return true end
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

-- Runtime-script after-load hook (controlled dofile()/loadstring path).
core.after(0, function()
    if runtime_scripts and runtime_scripts.load_enabled_after_start then
        local count = runtime_scripts.load_enabled_after_start()
        if count and count > 0 then
            core.log("action", "[llm_connect] runtime scripts after-load executed: " .. tostring(count))
        end
    end
end)

-- ===========================================================================

core.log("action", "[llm_connect] LLM Connect 1.1.0-dev init complete")
