-- ===========================================================================
--  skills/command_agent/command_agent.lua — LLM Connect 1.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Baseline agent skill for controlled chatcommand execution.
--  This addon acts as the explicit on/off gate for agent mode in main_gui:
--    - enabled  => send dispatches through agent.lua
--    - disabled => send stays plain chat
--
--  It also exposes a very small chatcommand bridge so the agent can inspect
--  and execute registered chatcommands when the player deliberately enables
--  this skill for the current session.
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

    local result = run_chatcommand({ command = "/time " .. tostring(time) }, player_name)
    if result.ok then
        result.message = "Time set to " .. tostring(time)
        result.data = result.data or {}
        result.data.time = time
    end
    return result
end

local function get_context(player_name)
    local player = get_player(player_name)
    if not player then return "Command Agent: player not found" end
    local pos = player:get_pos()
    return table.concat({
        "Command Agent skill is active.",
        "Use it for chatcommand-driven actions when appropriate.",
        string.format("Player position: (%d,%d,%d)", math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)),
        "Important: Prefer the most specific command_agent function available. Use run_chatcommand only when no direct function covers the task.",
        "Time changes: use set_time({time=18000}, player_name). Do not call core.set_time; it is not part of the safe runtime API.",
    }, "\n")
end

local function run_tool(tool_name, args, player_name)
    args = args or {}

    if tool_name == "list_chatcommands" then
        return list_commands(args, player_name)
    elseif tool_name == "run_chatcommand" then
        return run_chatcommand(args, player_name)
    elseif tool_name == "set_time" then
        return set_time(args, player_name)
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
        title = "Command Agent skill manual",
        summary = "Controlled chatcommand discovery and execution API.",
        tags = {"skill", "command_agent", "chatcommand", "commands"},
        required_priv = "llm_agent",
        provider = function(player_name)
            return table.concat({
                get_context(player_name),
                "",
                "Callable functions:",
                "  llm_connect.skills.command_agent.set_time({ time = 18000 }, player_name)",
                "  llm_connect.skills.command_agent.list_chatcommands({ only_allowed = true }, player_name)",
                "  llm_connect.skills.command_agent.run_chatcommand({ command = '/time 6000' }, player_name)",
                "  llm_connect.skills.command_agent.run('set_time', { time = 18000 }, player_name)",
                "For time changes, prefer set_time(). Do not call core.set_time; it is not available in the safe runtime.",
                "Do not call execute(); it is only a fallback compatibility alias.",
                "Use this skill only when there is no more specific direct skill for the task.",
                "Always include player_name as second argument.",
            }, "\n")
        end,
    })
end

if not (root.registry and type(root.registry.register_skill) == "function") then
    core.log("warning", "[command_agent] registry unavailable; skill API installed but not registered")
    return root.skills.command_agent
end

root.registry.register_skill({
    id = "command_agent",
    label = "Command Agent",
    version = "1.2.0-dev",
    description = "Lua-first skill for controlled chatcommand discovery and execution.",
    required_priv = "llm_agent",
    default_enabled = false,
    context_section = "skills.command_agent",
    get_context = get_context,
    tool_count = 3,
})

core.log("action", "[command_agent] loaded as Lua-first skill")
