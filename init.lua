-- ===========================================================================
--  init.lua — LLM Connect 1.2.0-dev
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  LOAD ORDER:
--    1. Preserve HTTP API handle
--    2. Register privileges
--    3. api/llm_api.lua      — HTTP layer, API configuration
--    4. agent/parser_utils.lua — LLM output parsing / repair
--    5. context/basic_context.lua — base context provider
--    6. skills/registry.lua — skill gateway, set _G.llm_connect
--       └ registry.expose_global()     → expose _G.llm_connect.registry
--    7. context/context_registry.lua — agent self-context / retrieval layer
--       └ registry.load_internal()     → load built-in skills after context exists
--    8. runtime/execution_policy.lua — central root/dev execution policy
--    9. runtime/path_policy.lua — stack-relative filesystem roots
--   10. runtime/storage/storage_backends.lua — filesystem helper layer
--   11. runtime/storage/runtime_scripts.lua — IDE persistence + hot-reload backend
--   12. runtime/storage/trusted_mods.lua — root-only trusted worldmod backend
--   13. runtime/core_executor.lua — Shared Lua Runtime Backend
--   14. agent/agent_runtime.lua — Agent-Orchestrator
--   15. gui/       — first-class frontend, loaded directly
--       └ ide_storage.lua    — backend bridge for IDE persistence
--       └ code_executor.lua  — legacy shim to core_executor
--       └ ide_asset_picker.lua
--       └ ide_file_manager.lua
--       └ ide_gui.lua
--   15. main_gui.lua         — main UI (chat + agent panel)
--   16. config_gui.lua       — settings UI including context-layer picker
--   10. on_mods_loaded:
--       └ registry.discover_external() → validate/report external skills that
--                                         already self-registered as Luanti mods
--   11. Main GUI and config GUI
--   12. Register formspec handlers
--   13. Load llm_startup.lua if present
--
-- ===========================================================================

local mod_name = core.get_current_modname()
local mod_dir  = core.get_modpath(mod_name)
local AGENT_DIR = mod_dir .. "/agent"
local API_DIR   = mod_dir .. "/api"
local CONTEXT_DIR = mod_dir .. "/context"
local RUNTIME_DIR = mod_dir .. "/runtime"
local STORAGE_DIR = RUNTIME_DIR .. "/storage"
local SKILLS_DIR = mod_dir .. "/skills"
local GUI_DIR   = mod_dir .. "/gui"

_G.llm_connect = rawget(_G, "llm_connect") or {}
_G.llm_connect.version = _G.llm_connect.version or "1.2.0-dev"
_G.llm_connect.protocol = _G.llm_connect.protocol or "lua-first"

-- Subsystem health / degraded-mode registry. Loaded before all subsystem
-- loaders so failures can be reported instead of turning into nil crashes.
local health_ok, health_module = pcall(dofile, mod_dir .. "/subsystem_health.lua")
if health_ok and type(health_module) == "table" then
    _G.llm_connect.health = health_module
else
    core.log("warning", "[llm_connect] subsystem_health.lua unavailable: " .. tostring(health_module))
    _G.llm_connect.health = _G.llm_connect.health or {
        status = {},
        mark_ok = function() end,
        mark_failed = function() end,
        mark_degraded = function() end,
        report_text = function() return "subsystem health unavailable" end,
    }
end

local function mark_ok(name, meta)
    local h = _G.llm_connect and _G.llm_connect.health
    if h and h.mark_ok then return h.mark_ok(name, meta) end
end

local function mark_failed(name, err, meta)
    local h = _G.llm_connect and _G.llm_connect.health
    if h and h.mark_failed then return h.mark_failed(name, err, meta) end
end


-- Helper: load a file with error handling
-- fatal=true  → aborts init on error (hard failure)
-- fatal=false → logs a warning, returns nil (optional module)
local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function load_module(path, label, fatal)
    if not file_exists(path) then
        local msg = string.format("%s missing at %s", label, tostring(path))
        mark_failed(label, msg, { path = path, fatal = fatal })
        if fatal then
            core.log("error", "[llm_connect] FATAL: " .. msg)
            error("[llm_connect] init aborted — " .. msg)
        end
        core.log("warning", "[llm_connect] optional module missing: " .. msg)
        return nil
    end

    local ok, result = pcall(dofile, path)
    if not ok then
        mark_failed(label, result, { path = path, fatal = fatal })
        if fatal then
            core.log("error", string.format(
                "[llm_connect] FATAL: %s could not be loaded from %s: %s",
                label, tostring(path), tostring(result)))
            error("[llm_connect] init aborted — " .. label .. " failed")
        else
            core.log("warning", string.format(
                "[llm_connect] %s not loaded from %s: %s", label, tostring(path), tostring(result)))
            return nil
        end
    end
    if result == nil and fatal then
        mark_failed(label, "returned nil", { path = path, fatal = fatal })
        core.log("error", "[llm_connect] FATAL: " .. label .. " returned nil")
        error("[llm_connect] init aborted — " .. label .. " returned nil")
    end
    mark_ok(label, { path = path })
    core.log("action", "[llm_connect] ✓ " .. label .. " loaded")
    return result
end

local function require_method(module, method, label)
    if type(module) ~= "table" or type(module[method]) ~= "function" then
        local msg = string.format("%s.%s unavailable", tostring(label), tostring(method))
        mark_failed(label, msg, { fatal = false })
        core.log("warning", "[llm_connect] degraded subsystem: " .. msg)
        return false
    end
    return true
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
    description  = "Access to LLM Connect agent mode and skill tools",
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
-- 3. Agent debugging: raw prompt files and root-only live trace
-- ===========================================================================

local agent_debug = load_module(AGENT_DIR .. "/agent_debug.lua", "agent_debug", false) or {}
local prompt_trace = agent_debug.prompt_trace
_G.llm_connect.prompt_trace = prompt_trace
local live_trace = agent_debug.live_trace
_G.llm_connect.live_trace = live_trace
_G.live_trace = live_trace
_G.prompt_trace = prompt_trace
if prompt_trace then
    core.log("action", "[llm_connect] prompt tracing hook installed (llm_trace_prompt_log controls writes)")
else
    core.log("warning", "[llm_connect] prompt tracing module not available")
end

-- ===========================================================================
-- 4. API subsystem — provider boundary
-- ===========================================================================

local api_modules = load_module(API_DIR .. "/api_init.lua", "api_init", true)
require_method(api_modules, "reload_config", "api")
local llm_api = api_modules.llm_api
require_method(llm_api, "init", "llm_api")

if not llm_api.init(http) then
    core.log("error", "[llm_connect] LLM API init failed")
    return
end

_G.llm_api = llm_api

-- ===========================================================================
-- 5. Parser utils
-- ===========================================================================

local parser_utils = load_module(AGENT_DIR .. "/parser_utils.lua", "parser_utils", true)
_G.llm_connect.parser_utils = parser_utils
_G.parser_utils = parser_utils

-- ===========================================================================
-- 6. Context subsystem — mode-aware context + retrieval API
-- ===========================================================================

local context_modules = load_module(CONTEXT_DIR .. "/context_init.lua", "context_init", true)
require_method(context_modules, "get", "context")
local basic_context = context_modules.basic_context
local context_registry = context_modules.registry
_G.basic_context = basic_context
_G.context_registry = context_registry

-- ===========================================================================
-- 7. Skills subsystem — Lua-first capability registry
-- ===========================================================================

local skills_modules = load_module(SKILLS_DIR .. "/skills_init.lua", "skills_init", true)
require_method(skills_modules, "load_internal", "skills")
local registry = skills_modules.registry
_G.registry = registry

-- Load internal skills after the context layer exists, so skills may register
-- on-demand documentation sections without bloating the system prompt.
skills_modules.load_internal()

-- ===========================================================================
-- 8. Runtime subsystem — policy, paths, storage, executor
-- ===========================================================================

local runtime_modules = load_module(RUNTIME_DIR .. "/runtime_init.lua", "runtime_init", true)
require_method(runtime_modules, "execute", "runtime")
local execution_policy = runtime_modules.execution_policy
local path_policy = runtime_modules.path_policy
local storage_backends = runtime_modules.storage_backends
local runtime_scripts = runtime_modules.runtime_scripts
local trusted_mods = runtime_modules.trusted_mods
local core_executor = runtime_modules.core_executor
_G.execution_policy = execution_policy
_G.path_policy = path_policy
_G.storage_backends = storage_backends
_G.runtime_scripts = runtime_scripts
_G.trusted_mods = trusted_mods
_G.core_executor = core_executor

-- ===========================================================================
-- 9. Agent support modules
-- ===========================================================================

local agent_modules = load_module(AGENT_DIR .. "/agent_init.lua", "agent_init", true)
_G.llm_connect.agent_modules = agent_modules

-- ===========================================================================
-- 10. Agent orchestrator
-- ===========================================================================

local agent = load_module(AGENT_DIR .. "/agent_runtime.lua", "agent", true)
require_method(agent, "run", "agent")
_G.llm_connect.agent = agent

-- ===========================================================================
-- 11. GUI subsystem — frontends only
-- ===========================================================================

local gui_modules = load_module(GUI_DIR .. "/gui_init.lua", "gui_init", true)
require_method(gui_modules, "show", "gui")
require_method(gui_modules, "handle_fields", "gui")
local main_gui = gui_modules.main_gui
local config_gui = gui_modules.config_gui

-- ===========================================================================
-- 10. External skill validation hook (after mods_loaded)
--     External skills are normal Luanti mods with depends=llm_connect. They
--     self-register through llm_connect.registry; this hook only reports on
--     already registered external skills and never loads third-party code.
-- ===========================================================================

core.register_on_mods_loaded(function()
    local external_report
    if registry and type(registry.discover_external) == "function" then
        local ok, report_or_err = pcall(registry.discover_external)
        if not ok then
            mark_failed("skills.discover_external", report_or_err, { fatal = false })
        else
            external_report = report_or_err
        end
    end
    core.log("action", string.format(
        "[llm_connect] ready — %d Lua-first skill(s) registered, external skills: %d discovered / %d valid / %d invalid",
        (function() local n=0; for _ in pairs((registry and registry.skills) or {}) do n=n+1 end; return n end)(),
        tonumber(external_report and external_report.discovered) or 0,
        tonumber(external_report and external_report.valid) or 0,
        tonumber(external_report and external_report.invalid) or 0))
end)

-- ===========================================================================
-- 11. Chat commands
-- ===========================================================================

core.register_chatcommand("llm", {
    description = "Open the LLM Connect chat interface",
    privs       = { llm = true },
    func = function(name, _)
        if gui_modules and gui_modules.show then
            gui_modules.show(name, "main")
        elseif main_gui and main_gui.show then
            main_gui.show(name)
        else
            core.chat_send_player(name, "[LLM] GUI unavailable. Use /llm_health for details.")
        end
        return true
    end,
})

core.register_chatcommand("llm_config", {
    description = "Open LLM Connect configuration",
    privs       = { llm = true },
    func = function(name, _)
        if gui_modules and gui_modules.show then
            gui_modules.show(name, "config")
        elseif config_gui and config_gui.show then
            config_gui.show(name)
        else
            core.chat_send_player(name, "[LLM] Config GUI unavailable. Use /llm_health for details.")
        end
        return true
    end,
})

core.register_chatcommand("llm_config_reload", {
    description = "Reload LLM Connect settings without server restart",
    privs       = { llm_root = true },
    func = function(name, _)
        local ok, err = pcall(api_modules.reload_config)
        if ok then
            core.chat_send_player(name, "[LLM] ✓ Configuration reloaded")
            return true
        else
            core.chat_send_player(name, "[LLM] ✗ Error: " .. tostring(err))
            return false, tostring(err)
        end
    end,
})


core.register_chatcommand("llm_health", {
    description = "Show LLM Connect subsystem health/degraded-mode status",
    privs       = { llm_root = true },
    func = function(name, _)
        local h = _G.llm_connect and _G.llm_connect.health
        local report = h and h.report_text and h.report_text() or "subsystem health unavailable"
        core.chat_send_player(name, "[LLM Health]\n" .. report)
        return true
    end,
})

local function resolve_connected_player_name(target)
    target = tostring(target or ""):match("^%s*(.-)%s*$")
    if target == "" then return nil, "missing player" end
    local folded = target:lower()
    local ci_match
    for _, player in ipairs(core.get_connected_players() or {}) do
        local pname = player:get_player_name()
        if pname == target then return pname end
        if pname:lower() == folded then ci_match = pname end
    end
    if ci_match then
        return nil, "Player not found: " .. target .. ". Did you mean " .. ci_match .. "?"
    end
    return nil, "Player not found: " .. target
end

core.register_chatcommand("llm_skill_list", {
    description = "List LLM Connect skills for a player (root)",
    params      = "[player]",
    privs       = { llm_root = true },
    func = function(name, param)
        local target = (param and param:match("^%s*(%S+)%s*$")) or name
        if target == "" then target = name end
        local resolved, perr = resolve_connected_player_name(target)
        if not resolved then return false, perr end
        target = resolved
        local skills = _G.llm_connect and (_G.llm_connect.skills or _G.llm_connect.skills_subsystem)
        if not skills or not skills.get_status then
            core.chat_send_player(name, "[LLM Skills] unavailable")
            return false, "skills unavailable"
        end
        local lines = {"[LLM Skills for " .. target .. "]"}
        for _, s in ipairs(skills.get_status(target) or {}) do
            lines[#lines + 1] = string.format("%s  %s  priv=%s  available=%s",
                s.enabled and "ATTACHED" or "DETACHED",
                tostring(s.id), tostring(s.required_priv), tostring(s.available))
        end
        core.chat_send_player(name, table.concat(lines, "\n"))
        return true
    end,
})

core.register_chatcommand("llm_trace", {
    description = "Open the LLM Connect live trace panel (root)",
    privs       = { llm_root = true },
    func = function(name, _)
        local trace = _G.llm_connect and _G.llm_connect.live_trace
        if trace and trace.show_formspec then
            trace.show_formspec(name)
            return true
        end
        return false, "live trace unavailable"
    end,
})

core.register_chatcommand("llm_skill_attach", {
    description = "Attach or detach an LLM Connect skill for a player (root)",
    params      = "<player> <skill_id> [on|off]",
    privs       = { llm_root = true },
    func = function(name, param)
        local target, skill_id, mode = tostring(param or ""):match("^%s*(%S+)%s+(%S+)%s*(%S*)%s*$")
        if not target or not skill_id then
            return false, "Usage: /llm_skill_attach <player> <skill_id> [on|off]"
        end
        local resolved, perr = resolve_connected_player_name(target)
        if not resolved then return false, perr end
        target = resolved
        local enabled = not (mode == "off" or mode == "false" or mode == "0" or mode == "detach")
        local skills = _G.llm_connect and (_G.llm_connect.skills or _G.llm_connect.skills_subsystem)
        if not skills then return false, "skills unavailable" end
        local ok, err
        if enabled then
            if skills.attach_to_player then ok, err = skills.attach_to_player(target, skill_id, true)
            elseif skills.set_enabled then ok, err = skills.set_enabled(target, skill_id, true) end
        else
            if skills.detach_from_player then ok, err = skills.detach_from_player(target, skill_id)
            elseif skills.set_enabled then ok, err = skills.set_enabled(target, skill_id, false) end
        end
        if ok then
            core.chat_send_player(name, "[LLM Skills] " .. skill_id .. " " .. (enabled and "attached to " or "detached from ") .. target)
            if target ~= name then
                core.chat_send_player(target, "[LLM Skills] " .. skill_id .. " " .. (enabled and "attached" or "detached") .. " by root")
            end
            return true
        end
        return false, tostring(err or "failed")
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
        if gui_modules and gui_modules.handle_fields then
            return gui_modules.handle_fields(name, formname, fields)
        end
        if main_gui and main_gui.handle_fields then
            return main_gui.handle_fields(name, formname, fields)
        end
        core.chat_send_player(name, "[LLM] Main GUI unavailable. Use /llm_health for details.")
        return true

    -- Smart Lua IDE and IDE sub-formspecs
    elseif formname:match("^llm_connect:ide") then
        if not execution_policy.can_ide(name) then
            core.chat_send_player(name, "[LLM] Missing privilege: llm_dev (or llm_root)")
            return true
        end
        if gui_modules and gui_modules.handle_fields then
            return gui_modules.handle_fields(name, formname, fields)
        end
        core.chat_send_player(name, "[LLM] IDE GUI unavailable")
        return true

    -- Config GUI
    elseif formname:match("^llm_connect:config") then
        if not execution_policy.can_config(name) then return true end
        if gui_modules and gui_modules.handle_fields then
            return gui_modules.handle_fields(name, formname, fields)
        end
        if config_gui and config_gui.handle_fields then
            return config_gui.handle_fields(name, formname, fields)
        end
        core.chat_send_player(name, "[LLM] Config GUI unavailable. Use /llm_health for details.")
        return true
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

core.log("action", "[llm_connect] LLM Connect 1.2.0-dev init complete")
