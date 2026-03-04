-- code_executor.lua
-- Secure Lua code execution for LLM-Connect / Smart Lua IDE
-- Privileges:
--   llm_dev  → Sandbox + Whitelist, no persistent registrations
--   llm_root → Unrestricted execution + persistent registrations possible

local core = core
local M = {}

M.execution_history = {}  -- per player: {timestamp, code_snippet, success, output/error}

local STARTUP_FILE = core.get_worldpath() .. DIR_DELIM .. "llm_startup.lua"

-- =============================================================
--  Helper functions
-- =============================================================

local function player_has_priv(name, priv)
    local privs = core.get_player_privs(name) or {}
    return privs[priv] == true
end

-- llm_root ist Superrolle: impliziert llm_dev und alle anderen
local function has_llm_priv(name, priv)
    if player_has_priv(name, "llm_root") then return true end
    return player_has_priv(name, priv)
end

local function is_llm_root(name)
    return player_has_priv(name, "llm_root")
end

-- =============================================================
--  Sandbox environment (for normal llm_dev / llm users)
-- =============================================================

local function create_sandbox_env(player_name)
    local safe_core = {
        -- Logging & Chat
        log               = core.log,
        chat_send_player  = core.chat_send_player,

        -- Secure read access
        get_node          = core.get_node,
        get_node_or_nil   = core.get_node_or_nil,
        find_node_near    = core.find_node_near,
        find_nodes_in_area = core.find_nodes_in_area,
        get_meta          = core.get_meta,
        get_player_by_name = core.get_player_by_name,
        get_connected_players = core.get_connected_players,
    }

    -- Block registration functions (require restart)
    local function blocked_registration(name)
        return function(...)
            core.log("warning", ("[code_executor] Blocked registration call: %s by %s"):format(name, player_name))
            core.chat_send_player(player_name, "Registrations are forbidden in sandbox mode.\nOnly llm_root may execute these persistently.")
            return nil
        end
    end

    safe_core.register_node      = blocked_registration("register_node")
    safe_core.register_craftitem = blocked_registration("register_craftitem")
    safe_core.register_tool      = blocked_registration("register_tool")
    safe_core.register_craft     = blocked_registration("register_craft")
    safe_core.register_entity    = blocked_registration("register_entity")

    -- Allowed dynamic registrations (very restricted)
    safe_core.register_chatcommand    = core.register_chatcommand
    safe_core.register_on_chat_message = core.register_on_chat_message

    -- Safe standard libraries (without dangerous functions)
    local env = {
        -- Lua basics
        assert  = assert,
        error   = error,
        pairs   = pairs,
        ipairs  = ipairs,
        next    = next,
        select  = select,
        type    = type,
        tostring = tostring,
        tonumber = tonumber,
        unpack  = table.unpack or unpack,

        -- Safe string/table/math functions
        string  = { byte=string.byte, char=string.char, find=string.find, format=string.format,
                    gmatch=string.gmatch, gsub=string.gsub, len=string.len, lower=string.lower,
                    match=string.match, rep=string.rep, reverse=string.reverse, sub=string.sub,
                    upper=string.upper },
        table   = { concat=table.concat, insert=table.insert, remove=table.remove, sort=table.sort },
        math    = math,

        -- Minetest-safe API
        core    = safe_core,

        -- Redirect print
        print   = function(...) end,   -- will be overwritten later
    }

    -- Output buffer with limit
    local output_buffer = {}
    local output_size = 0
    local MAX_OUTPUT = 100000  -- ~100 KB

    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring(select(i, ...))
        end
        local line = table.concat(parts, "\t")

        if output_size + #line > MAX_OUTPUT then
            table.insert(output_buffer, "\n[OUTPUT TRUNCATED – 100 KB limit reached]")
            return
        end

        table.insert(output_buffer, line)
        output_size = output_size + #line
    end

    return env, output_buffer
end

-- =============================================================
--  Append persistent startup code (llm_root only)
-- =============================================================

local function append_to_startup(code, player_name)
    local f, err = io.open(STARTUP_FILE, "a")
    if not f then
        core.log("error", ("[code_executor] Cannot open startup file: %s"):format(tostring(err)))
        return false, err
    end

    f:write(("\n-- Added by %s at %s\n"):format(player_name, os.date("%Y-%m-%d %H:%M:%S")))
    f:write(code)
    f:write("\n\n")
    f:close()

    core.log("action", ("[code_executor] Appended code to %s by %s"):format(STARTUP_FILE, player_name))
    return true
end

-- =============================================================
--  Main execution function
-- =============================================================

function M.execute(player_name, code, options)
    options = options or {}
    local result = { success = false }

    if type(code) ~= "string" or code:trim() == "" then
        result.error = "No or empty code provided"
        return result
    end

    local is_root = is_llm_root(player_name)
    local use_sandbox   = options.sandbox ~= false
    local allow_persist = options.allow_persist or is_root

    -- Prüfen ob der Player überhaupt Ausführungsrechte hat
    if not has_llm_priv(player_name, "llm_dev") then
        result.error = "Missing privilege: llm_dev (or llm_root)"
        return result
    end

    -- =============================================
    --  1. Compile
    -- =============================================
    local func, compile_err = loadstring(code, "=(llm_ide)")
    if not func then
        result.error = "Compile error: " .. tostring(compile_err)
        core.log("warning", ("[code_executor] Compile failed for %s: %s"):format(player_name, result.error))
        return result
    end

    -- =============================================
    --  2. Prepare environment & print redirection
    -- =============================================
    local output_buffer = {}
    local env

    if use_sandbox then
        env, output_buffer = create_sandbox_env(player_name)
        setfenv(func, env)   -- Lua 5.1 compatibility (Luanti mostly uses LuaJIT)
    else
        -- Unrestricted mode → Careful!
        if not is_root then
            result.error = "Unrestricted execution only allowed for llm_root"
            return result
        end

        -- Redirect print (without overwriting _G)
        local old_print = print
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts+1] = tostring(select(i, ...)) end
            local line = table.concat(parts, "\t")
            table.insert(output_buffer, line)
        end
    end

    -- =============================================
    --  3. Execute (with instruction limit)
    -- =============================================
    local ok, exec_res = pcall(function()
        -- Instruction limit could be added here later (currently dummy)
        return func()
    end)

    -- Reset print (if unrestricted)
    if not use_sandbox then
        print = old_print
    end

    -- =============================================
    --  4. Process result
    -- =============================================
    result.output = table.concat(output_buffer, "\n")

    if ok then
        result.success = true
        result.return_value = exec_res

        core.log("action", ("[code_executor] Success by %s (sandbox=%s)"):format(player_name, tostring(use_sandbox)))
    else
        result.error = "Runtime error: " .. tostring(exec_res)
        core.log("warning", ("[code_executor] Execution failed for %s: %s"):format(player_name, result.error))
    end

    -- =============================================
    --  5. Check for registrations → Persistence?
    -- =============================================
    local has_registration = code:match("register_node%s*%(")     or
                             code:match("register_tool%s*%(")      or
                             code:match("register_craftitem%s*%(") or
                             code:match("register_entity%s*%(")    or
                             code:match("register_craft%s*%(")

    if has_registration then
        if allow_persist and is_root then
            local saved, save_err = append_to_startup(code, player_name)
            if saved then
                local msg = "Code with registrations saved to llm_startup.lua.\nWill be active after server restart."
                core.chat_send_player(player_name, msg)
                result.output = (result.output or "") .. "\n\n" .. msg
                result.persisted = true
            else
                result.error = (result.error or "") .. "\nPersistence failed: " .. tostring(save_err)
            end
        else
            local msg = "Code contains registrations (node/tool/...). \nOnly llm_root can execute these persistently (restart required)."
            core.chat_send_player(player_name, msg)
            result.error = (result.error or "") .. "\n" .. msg
            result.success = false   -- even if execution was ok
        end
    end

    -- Save history
    M.execution_history[player_name] = M.execution_history[player_name] or {}
    table.insert(M.execution_history[player_name], {
        timestamp = os.time(),
        code      = code:sub(1, 200) .. (code:len() > 200 and "..." or ""),
        success   = result.success,
        output    = result.output,
        error     = result.error,
    })

    return result
end

-- =============================================================
--  History functions
-- =============================================================

function M.get_history(player_name, limit)
    limit = limit or 10
    local hist = M.execution_history[player_name] or {}
    local res = {}
    local start = math.max(1, #hist - limit + 1)
    for i = start, #hist do
        res[#res+1] = hist[i]
    end
    return res
end

function M.clear_history(player_name)
    M.execution_history[player_name] = nil
end

-- Cleanup
core.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    M.execution_history[name] = nil
end)

return M
