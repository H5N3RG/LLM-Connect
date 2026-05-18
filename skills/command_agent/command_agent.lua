-- ===========================================================================
--  skills/command_agent/command_agent.lua — LLM Connect Runtime Agent
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  System-facing runtime skill for controlled Luanti actions.
--  Chatcommands remain as a compatibility fallback, but the preferred contract
--  is direct runtime execution through core_executor policy.
-- ===========================================================================

local core = core

local function available()
    return true
end

local function get_player(name)
    if not name or name == "" then return nil end
    return core.get_player_by_name(name)
end

local function effective_player_name(name)
    if type(name) == "string" and name ~= "" then return name end
    local current = rawget(_G, "player_name")
    if type(current) == "string" and current ~= "" then return current end
    return name
end

local function looks_like_command(value)
    if type(value) ~= "string" then return false end
    local text = value:match("^%s*(.-)%s*$")
    if text == "" then return false end
    return text:sub(1, 1) == "/" or text:match("^%S+%s+.+$") ~= nil
end

local function normalize_command(raw)
    raw = tostring(raw or ""):match("^%s*(.-)%s*$")
    if raw == "" then return nil, "command is empty" end
    if raw:sub(1, 1) == "/" then raw = raw:sub(2) end
    local cmd, param = raw:match("^(%S+)%s*(.-)$")
    if not cmd or cmd == "" then return nil, "missing command name" end
    return cmd, param or ""
end

local function list_commands(args, player_name)
    player_name = effective_player_name(player_name)
    local player = get_player(player_name)
    if not player then
        return { ok = false, success = false, message = "player not found" }
    end

    local only_allowed = args.only_allowed ~= false
    local cmds = {}
    for name, def in pairs(core.registered_chatcommands or {}) do
        local allowed = true
        if only_allowed and def.privs then
            allowed = core.check_player_privs(player_name, def.privs)
        end
        if allowed then
            table.insert(cmds, {
                name = name,
                description = def.description or "",
            })
        end
    end
    table.sort(cmds, function(a, b) return a.name < b.name end)

    local preview = {}
    for i = 1, math.min(#cmds, 24) do
        preview[#preview + 1] = "/" .. cmds[i].name
    end

    return {
        ok = true,
        success = true,
        message = (#cmds > 0)
            and ("Available chatcommands: " .. table.concat(preview, ", "))
            or "No allowed chatcommands found",
        data = {
            count = #cmds,
            commands = cmds,
        }
    }
end

local function run_chatcommand(args, player_name)
    player_name = effective_player_name(player_name)
    local player = get_player(player_name)
    if not player then
        return { ok = false, success = false, message = "player not found" }
    end

    local cmd, param = normalize_command(args.command)
    if not cmd then
        return { ok = false, success = false, message = param }
    end

    local def = (core.registered_chatcommands or {})[cmd]
    if not def then
        return { ok = false, success = false, message = "unknown chatcommand '/" .. tostring(cmd) .. "'" }
    end

    if def.privs and not core.check_player_privs(player_name, def.privs) then
        return { ok = false, success = false, message = "missing privileges for '/" .. tostring(cmd) .. "'" }
    end

    local ok, success, msg = pcall(def.func, player_name, param)
    if not ok then
        return { ok = false, success = false, message = "chatcommand crashed: " .. tostring(success) }
    end

    local command_success = success ~= false
    return {
        ok = command_success,
        success = command_success,
        message = tostring(msg or ((success == false) and "command failed" or "command executed")),
        data = {
            command = cmd,
            param = param,
            success = command_success,
        }
    }
end

local function get_runtime()
    local root = rawget(_G, "llm_connect")
    return type(root) == "table" and root.runtime or nil
end

local function summarize_runtime_result(result)
    if type(result) ~= "table" then return "runtime returned no result" end
    if result.error and result.error ~= "" then return tostring(result.error) end
    if result.output and result.output ~= "" then return tostring(result.output) end
    if result.return_value ~= nil then return "runtime returned " .. tostring(result.return_value) end
    return result.ok and "runtime execution succeeded" or "runtime execution failed"
end

local function precheck_lua(args, player_name)
    player_name = effective_player_name(player_name)
    args = args or {}
    local code = tostring(args.code or args.lua or "")
    if code:match("^%s*$") then
        return { ok = false, success = false, message = "code is empty" }
    end
    local runtime = get_runtime()
    if not runtime or type(runtime.precheck) ~= "function" then
        return { ok = false, success = false, message = "runtime precheck unavailable" }
    end
    local result = runtime.precheck(player_name, code, {
        purpose = "skill",
        required_priv = "llm_agent",
        bypass_safety_filters = args.bypass_safety_filters == true,
    })
    return {
        ok = result and result.ok == true,
        success = result and result.ok == true,
        message = result and result.ok and "precheck passed"
            or ("precheck failed: " .. table.concat((result and result.issues) or {"unknown issue"}, "; ")),
        data = result,
    }
end

local function execute_lua(args, player_name)
    player_name = effective_player_name(player_name)
    args = args or {}
    local code = tostring(args.code or args.lua or "")
    if code:match("^%s*$") then
        return { ok = false, success = false, message = "code is empty" }
    end
    local max_bytes = tonumber(args.max_bytes or 16000) or 16000
    if #code > max_bytes then
        return { ok = false, success = false, message = "code exceeds max_bytes=" .. tostring(max_bytes) }
    end

    local runtime = get_runtime()
    if not runtime or type(runtime.execute) ~= "function" then
        return { ok = false, success = false, message = "runtime executor unavailable" }
    end

    local result = runtime.execute(player_name, code, {
        purpose = "skill",
        required_priv = "llm_agent",
        sandbox = args.sandbox ~= false,
        allow_skills = args.allow_skills == true,
        precheck = args.precheck ~= false,
        bypass_safety_filters = args.bypass_safety_filters == true,
    })
    local ok = type(result) == "table" and result.ok == true
    return {
        ok = ok,
        success = ok,
        message = summarize_runtime_result(result),
        data = result,
    }
end

local function set_time(args, player_name)
    args = args or {}
    local time = tonumber(args.time or args.timeofday or args.value)
    if not time then
        return { ok = false, success = false, message = "time must be a number from 0 to 24000" }
    end
    time = math.floor(time)
    if time < 0 or time > 24000 then
        return { ok = false, success = false, message = "time must be between 0 and 24000" }
    end
    if time == 24000 then time = 0 end

    if type(core.set_timeofday) == "function" then
        local ok, err = pcall(core.set_timeofday, time / 24000)
        if not ok then
            return { ok = false, success = false, message = "set_timeofday failed: " .. tostring(err) }
        end
        return {
            ok = true,
            success = true,
            message = "Time set to " .. tostring(time),
            data = { time = time, method = "core.set_timeofday" },
        }
    end

    local result = run_chatcommand({ command = "/time " .. tostring(time) }, player_name)
    if result.ok then
        result.message = "Time set to " .. tostring(time)
        result.data = result.data or {}
        result.data.time = time
        result.data.method = "chatcommand_fallback"
    end
    return result
end

local function get_context(player_name)
    local player = get_player(player_name)
    if not player then return "Runtime Agent: player not found" end
    local pos = player:get_pos()
    return table.concat({
        "Runtime Agent skill is active (registered as command_agent for compatibility).",
        "Use it for controlled runtime Lua actions and small direct system operations.",
        string.format("Player position: (%d,%d,%d)", math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)),
        "Preferred: execute_lua({code='return {done=true}'}, player_name) for runtime-safe Lua through core_executor policy.",
        "Use run_chatcommand only when no direct function or runtime-safe Lua covers the task.",
        "Time changes: use set_time({time=18000}, player_name). It uses native core.set_timeofday when available.",
    }, "\n")
end

local function run_tool(tool_name, args, player_name)
    -- Handle common swap: run('tool', 'player', {args})
    if type(player_name) == "table" and type(args) == "string" then
        local temp = args
        args = player_name
        player_name = temp
    end

    args = args or {}
    player_name = effective_player_name(player_name)

    if tool_name == "list_chatcommands" then
        return list_commands(args, player_name)
    elseif tool_name == "run_chatcommand" then
        return run_chatcommand(args, player_name)
    elseif tool_name == "set_time" then
        return set_time(args, player_name)
    elseif tool_name == "precheck_lua" then
        return precheck_lua(args, player_name)
    elseif tool_name == "execute_lua" or tool_name == "run_lua" then
        return execute_lua(args, player_name)
    end
    return { ok = false, success = false, message = "unknown tool '" .. tostring(tool_name) .. "'" }
end

local root = rawget(_G, "llm_connect") or {}
rawset(_G, "llm_connect", root)
root.skills = root.skills or {}
root.skills.command_agent = {
    run = function(tool_name, args, player_name) return run_tool(tool_name, args or {}, player_name) end,
    list_chatcommands = function(args, player_name) return list_commands(args or {}, player_name) end,
    run_chatcommand = function(args, player_name) return run_chatcommand(args or {}, player_name) end,
    set_time = function(args, player_name) return set_time(args or {}, player_name) end,
    precheck_lua = function(args, player_name) return precheck_lua(args or {}, player_name) end,
    execute_lua = function(args, player_name) return execute_lua(args or {}, player_name) end,
    run_lua = function(args, player_name) return execute_lua(args or {}, player_name) end,
    execute = function(a, b)
        -- Compatibility for common model mistakes. The documented API remains
        -- run_chatcommand({ command = "/time 6000" }, player_name).
        if type(a) == "table" then
            return run_chatcommand(a, b or a.player_name or a.player)
        end
        if type(a) == "string" and type(b) == "string" then
            local a_is_player = get_player(a) ~= nil
            local b_is_player = get_player(b) ~= nil
            if b_is_player and (looks_like_command(a) or not a_is_player) then
                return run_chatcommand({ command = a }, b)
            end
            if a_is_player and (looks_like_command(b) or not b_is_player) then
                return run_chatcommand({ command = b }, a)
            end
            if looks_like_command(a) then
                return run_chatcommand({ command = a }, b)
            end
            return run_chatcommand({ command = b }, a)
        end
        return run_chatcommand({ command = tostring(a or "") }, b)
    end,
}


if root.context and type(root.context.register_section) == "function" then
    root.context.register_section({
        id = "skills.command_agent",
        title = "Runtime Agent skill manual",
        summary = "Controlled runtime Lua execution, direct system helpers, and chatcommand fallback.",
        tags = {"skill", "command_agent", "runtime_agent", "lua", "commands"},
        required_priv = "llm_agent",
        provider = function(player_name)
            return table.concat({
                get_context(player_name),
                "",
                "Callable functions:",
                "  llm_connect.skills.command_agent.execute_lua({ code = 'return { done=true, message=\"ok\" }' }, player_name)",
                "  llm_connect.skills.command_agent.precheck_lua({ code = 'return 1' }, player_name)",
                "  llm_connect.skills.command_agent.set_time({ time = 18000 }, player_name)",
                "  llm_connect.skills.command_agent.list_chatcommands({ only_allowed = true }, player_name)",
                "  llm_connect.skills.command_agent.run_chatcommand({ command = '/time 6000' }, player_name)",
                "  llm_connect.skills.command_agent.run('execute_lua', { code = 'print(player_name)' }, player_name)",
                "  llm_connect.skills.command_agent.run('set_time', { time = 18000 }, player_name)",
                "execute_lua routes through llm_connect.runtime/core_executor and respects execution policy, precheck, and sandbox settings.",
                "For time changes, prefer set_time(); it is native when core.set_timeofday exists and falls back to /time only if needed.",
                "Do not call execute(); it is only a fallback compatibility alias.",
                "Use run_chatcommand only when no direct helper or runtime-safe Lua operation covers the task.",
                "Always include player_name as second argument.",
            }, "\n")
        end,
    })
    if type(root.context.register_aliases) == "function" then
        root.context.register_aliases({
            runtime_agent = "skills.command_agent",
            command_agent = "skills.command_agent",
            commands = "skills.command_agent",
        })
    end
end

if not (root.registry and type(root.registry.register_skill) == "function") then
    core.log("warning", "[command_agent] registry unavailable; skill API installed but not registered")
    return root.skills.command_agent
end

root.registry.register_skill({
    id = "command_agent",
    label = "Runtime Agent",
    version = "1.3.0-dev",
    description = "Lua-first runtime primitive skill: controlled Lua execution, direct system helpers, and chatcommand fallback.",
    required_priv = "llm_agent",
    default_enabled = false,
    context_section = "skills.command_agent",
    context_aliases = {"runtime_agent", "command_agent", "commands"},
    get_context = get_context,
    tool_count = 5,
})

core.log("action", "[command_agent] loaded as Lua-first skill")
