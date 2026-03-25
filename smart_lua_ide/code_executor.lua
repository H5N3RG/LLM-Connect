-- ===========================================================================
--  code_executor.lua — LLM Connect / Smart Lua IDE
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Secure Lua code execution for the Smart Lua IDE.
--  Ported from 0.9.0 — no functional changes, path relocation only.
--
--  Privileges:
--    llm_dev  → sandbox execution, no persistent registrations
--    llm_root → unrestricted execution + persistent registrations
--
--  PUBLIC API:
--    M.precheck(code)                  → {ok, issues, registrations}
--    M.execute(player_name, code, opts)→ result table
--    M.execute_with_retry(name, code, opts)  (async, LLM auto-fix loop)
--    M.execution_history               table, per-player
--
-- ===========================================================================

local core = core
local M    = {}

M.execution_history = {}

local STARTUP_FILE = core.get_worldpath() .. DIR_DELIM .. "llm_startup.lua"

-- ===========================================================================
-- Helpers
-- ===========================================================================

local function get_policy()
    return _G.llm_connect and _G.llm_connect.policy
end

local function player_has_priv(name, priv)
    local privs = core.get_player_privs(name) or {}
    return privs[priv] == true
end

local function has_llm_priv(name, priv)
    local policy = get_policy()
    if policy and policy.has_priv then return policy.has_priv(name, priv) end
    if player_has_priv(name, "llm_root") then return true end
    return player_has_priv(name, priv)
end

local function is_llm_root(name)
    local policy = get_policy()
    if policy and policy.is_root then return policy.is_root(name) end
    return player_has_priv(name, "llm_root")
end

-- ===========================================================================
-- Sandbox environment
-- ===========================================================================

local function create_sandbox_env(player_name)
    local safe_core = {
        log                   = core.log,
        chat_send_player      = core.chat_send_player,
        get_node              = core.get_node,
        get_node_or_nil       = core.get_node_or_nil,
        find_node_near        = core.find_node_near,
        find_nodes_in_area    = core.find_nodes_in_area,
        get_meta              = core.get_meta,
        get_player_by_name    = core.get_player_by_name,
        get_connected_players = core.get_connected_players,
    }

    local function blocked_registration(fname)
        return function(...)
            core.log("warning", ("[code_executor] blocked registration call: %s by %s"):format(fname, player_name))
            core.chat_send_player(player_name,
                "Registrations are forbidden in sandbox mode.\nOnly llm_root may execute these persistently.")
        end
    end

    safe_core.register_node      = blocked_registration("register_node")
    safe_core.register_tool      = blocked_registration("register_tool")
    safe_core.register_craftitem = blocked_registration("register_craftitem")
    safe_core.register_entity    = blocked_registration("register_entity")
    safe_core.register_craft     = blocked_registration("register_craft")

    local output_buffer = {}
    local env = {
        core  = safe_core,
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts+1] = tostring(select(i, ...)) end
            table.insert(output_buffer, table.concat(parts, "\t"))
        end,
        tostring = tostring, tonumber = tonumber, type = type,
        pairs = pairs, ipairs = ipairs, next = next,
        table = table, string = string, math = math,
        unpack = unpack, select = select, pcall = pcall, xpcall = xpcall,
        error = error, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable,
        rawget = rawget, rawset = rawset, rawequal = rawequal,
        os = { clock = os.clock, date = os.date, difftime = os.difftime, time = os.time },
    }

    local BLOCKED_GLOBALS = {
        io=true, require=true, dofile=true, loadfile=true,
        load=true, loadstring=true, debug=true, package=true,
        getfenv=true, setfenv=true,
    }

    setmetatable(env, {
        __index = function(_, key)
            if BLOCKED_GLOBALS[key] then return nil end
            return _G[key]
        end
    })

    return env, output_buffer
end

-- ===========================================================================
-- Startup persistence
-- ===========================================================================

local function append_to_startup(code, player_name)
    local f, err = io.open(STARTUP_FILE, "a")
    if not f then
        core.log("error", ("[code_executor] cannot open startup file: %s"):format(tostring(err)))
        return false, err
    end
    f:write(("\n-- Added by %s at %s\n"):format(player_name, os.date("%Y-%m-%d %H:%M:%S")))
    f:write(code)
    f:write("\n\n")
    f:close()
    core.log("action", ("[code_executor] appended code to %s by %s"):format(STARTUP_FILE, player_name))
    return true
end

-- ===========================================================================
-- Pre-executor: syntax + naming + field validation
-- ===========================================================================

local REQUIRED_FIELDS = {
    register_node      = {"tiles"},
    register_tool      = {"inventory_image"},
    register_craftitem = {},
    register_entity    = {"initial_properties"},
}

local VALID_PREFIXES = {
    "llm_connect:", "default:", "stairs:", "doors:",
    "farming:", "fire:", "flowers:", "beds:", "bucket:",
    "vessels:", "wool:", "dye:", "screwdriver:", "xpanes:", "moreblocks:",
}

local function check_naming(reg_name)
    if not reg_name:find(":") then
        return ("Name '%s' missing mod prefix (e.g. 'llm_connect:my_node')"):format(reg_name)
    end
    local prefix = reg_name:match("^([^:]+):")
    if prefix and prefix ~= "llm_connect" then
        local known = false
        for _, p in ipairs(VALID_PREFIXES) do
            if reg_name:sub(1, #p) == p then known = true; break end
        end
        if not known then
            return ("Name '%s' uses unknown mod prefix '%s:' – use 'llm_connect:' for new registrations"):format(reg_name, prefix)
        end
    end
    return nil
end

function M.precheck(code)
    local issues = {}

    local func, syntax_err = loadstring(code, "=(precheck)")
    if not func then
        local msg = tostring(syntax_err):gsub("^%[string .-%]:", "line ")
        return { ok = false, issues = {"Syntax error: " .. msg} }
    end

    local registrations = {}

    local function make_stub(reg_type)
        return function(reg_name, def)
            def = def or {}
            local entry = {reg_type = reg_type, name = reg_name, def = def}
            local naming_err = check_naming(tostring(reg_name or ""))
            if naming_err then entry.naming_error = naming_err end
            local required = REQUIRED_FIELDS[reg_type] or {}
            local missing  = {}
            for _, field in ipairs(required) do
                if def[field] == nil then table.insert(missing, field) end
            end
            if #missing > 0 then entry.missing_fields = missing end
            table.insert(registrations, entry)
        end
    end

    local stub_core = {
        register_node      = make_stub("register_node"),
        register_tool      = make_stub("register_tool"),
        register_craftitem = make_stub("register_craftitem"),
        register_craft     = function() end,
        register_entity    = make_stub("register_entity"),
        register_chatcommand              = function() end,
        register_globalstep               = function() end,
        register_on_joinplayer            = function() end,
        register_on_leaveplayer           = function() end,
        register_on_player_receive_fields = function() end,
        register_on_chat_message          = function() end,
        register_on_generated             = function() end,
        register_abm                      = function() end,
        register_lbm                      = function() end,
        log              = function() end,
        chat_send_player = function() end,
        chat_send_all    = function() end,
        after            = function() end,
        sound_play       = function() end,
        show_formspec    = function() end,
    }
    setmetatable(stub_core, {__index = core})

    local stub_env = {print = function() end, core = stub_core}
    setmetatable(stub_env, {__index = _G})

    setfenv(func, stub_env)
    local ok, run_err = pcall(func)

    if not ok then
        local msg = tostring(run_err):gsub("^%[string .-%]:", "line ")
        table.insert(issues, "Runtime error (pre-check): " .. msg)
    end

    for _, entry in ipairs(registrations) do
        if entry.naming_error then
            table.insert(issues, "Naming: " .. entry.naming_error)
        end
        if entry.missing_fields then
            table.insert(issues,
                ("Missing required fields in %s('%s'): %s")
                :format(entry.reg_type, entry.name, table.concat(entry.missing_fields, ", ")))
        end
    end

    return {ok = #issues == 0, issues = issues, registrations = registrations}
end

-- ===========================================================================
-- M.execute
-- ===========================================================================

function M.execute(player_name, code, options)
    options = options or {}
    local result = {success = false}

    if type(code) ~= "string" or code:match("^%s*$") then
        result.error = "No or empty code provided"
        return result
    end

    local policy = get_policy()
    local exec_ctx = policy and policy.resolve_ide_execution and policy.resolve_ide_execution(player_name, options) or nil

    local is_root       = is_llm_root(player_name)
    local use_sandbox   = exec_ctx and exec_ctx.sandbox or (options.sandbox ~= false)
    local allow_persist = (options.allow_persist ~= nil) and options.allow_persist
        or (exec_ctx and exec_ctx.can_persist)
        or is_root

    if not has_llm_priv(player_name, "llm_dev") then
        result.error = "Missing privilege: llm_dev (or llm_root)"
        return result
    end

    -- Pre-check
    if options.precheck ~= false then
        local pre = M.precheck(code)
        result.precheck = pre
        if not pre.ok then
            result.precheck_warnings = table.concat(pre.issues, "\n")
            core.log("warning", ("[code_executor] pre-check issues for %s:\n%s"):format(
                player_name, result.precheck_warnings))
            if pre.issues[1] and pre.issues[1]:match("^Syntax error") then
                result.error = result.precheck_warnings
                return result
            end
        end
    end

    -- Compile
    local func, compile_err = loadstring(code, "=(llm_ide)")
    if not func then
        result.error = "Compile error: " .. tostring(compile_err)
        return result
    end

    local output_buffer = {}
    local env

    if use_sandbox then
        env, output_buffer = create_sandbox_env(player_name)
        setfenv(func, env)
    else
        if not is_root then
            result.error = "Unrestricted execution only allowed for llm_root"
            return result
        end
        local old_print = print
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts+1] = tostring(select(i, ...)) end
            table.insert(output_buffer, table.concat(parts, "\t"))
        end
    end

    local ok, exec_res = pcall(function() return func() end)

    if not use_sandbox then
        print = old_print
    end

    result.output = table.concat(output_buffer, "\n")

    if result.precheck_warnings then
        result.output = "⚠ Pre-check warnings:\n" .. result.precheck_warnings .. "\n\n" .. result.output
    end

    if ok then
        result.success      = true
        result.return_value = exec_res
        core.log("action", ("[code_executor] success by %s (sandbox=%s)"):format(player_name, tostring(use_sandbox)))
    else
        result.error = "Runtime error: " .. tostring(exec_res)
        core.log("warning", ("[code_executor] execution failed for %s: %s"):format(player_name, result.error))
    end

    -- Persistence check
    local has_registration = code:match("register_node%s*%(")
                          or code:match("register_tool%s*%(")
                          or code:match("register_craftitem%s*%(")
                          or code:match("register_entity%s*%(")
                          or code:match("register_craft%s*%(")

    if has_registration then
        if allow_persist and is_root then
            if not result.success then
                local msg = "✗ Code with registrations NOT saved – execution failed. Fix errors first."
                core.chat_send_player(player_name, msg)
                result.output = (result.output or "") .. "\n\n" .. msg
            else
                local saved, save_err = append_to_startup(code, player_name)
                if saved then
                    local msg = "Code with registrations saved to llm_startup.lua.\nWill be active after server restart."
                    core.chat_send_player(player_name, msg)
                    result.output = (result.output or "") .. "\n\n" .. msg
                    result.persisted = true
                else
                    result.error = (result.error or "") .. "\nPersistence failed: " .. tostring(save_err)
                end
            end
        else
            local msg = "Code contains registrations (node/tool/...).\nOnly llm_root can execute these persistently (restart required)."
            core.chat_send_player(player_name, msg)
            result.error   = (result.error or "") .. "\n" .. msg
            result.success = false
        end
    end

    -- Save to execution history
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

-- ===========================================================================
-- M.execute_with_retry — AI auto-fix loop
-- ===========================================================================

local DEFAULT_FIXER_PROMPT = [[You are a Minetest/Luanti Lua code fixer running inside the LLM Connect IDE.
You will receive a code block and the error it produced.
Your task: Fix the code so it runs without errors.

Rules:
- Return ONLY the corrected Lua code – no markdown, no explanation, no preamble
- Preserve all original intent and logic
- Fix naming convention errors: use "llm_connect:" prefix for all registrations
- Fix missing required fields (tiles for nodes, inventory_image for tools)
- Do NOT add os/io/debug/require/dofile/loadfile
]]

function M.execute_with_retry(player_name, code, opts)
    opts = opts or {}
    local max_iter    = opts.max_iterations or 3
    local on_iter     = opts.on_iteration
    local on_done     = opts.on_done
    local llm_req     = opts.llm_request
    local sys_prompt  = opts.system_prompt or DEFAULT_FIXER_PROMPT

    if not on_done or not llm_req then
        core.log("error", "[code_executor] execute_with_retry: on_done and llm_request are required")
        return
    end

    local iteration    = 0
    local last_error   = nil
    local current_code = code

    local function attempt()
        iteration = iteration + 1
        if on_iter then on_iter(iteration, current_code, last_error) end

        local result = M.execute(player_name, current_code, {
            sandbox  = opts.sandbox,
            precheck = true,
        })

        if result.success then
            on_done(result, current_code)
            return
        end

        local err_msg = ""
        if result.precheck_warnings then
            err_msg = "Pre-check warnings:\n" .. result.precheck_warnings .. "\n"
        end
        if result.error   then err_msg = err_msg .. result.error end
        if result.output and result.output ~= "" then
            err_msg = err_msg .. "\nOutput:\n" .. result.output
        end

        if err_msg == last_error then
            result.debug_loop_aborted = true
            on_done(result, current_code)
            return
        end

        last_error = err_msg

        if iteration >= max_iter then
            on_done(result, current_code)
            return
        end

        local messages = {
            {role = "system", content = sys_prompt},
            {role = "user",   content = "Code:\n```lua\n" .. current_code .. "\n```\n\nError:\n" .. err_msg},
        }

        llm_req(messages, function(llm_result)
            if not llm_result.success then
                result.error = "LLM fix request failed: " .. (llm_result.error or "?")
                on_done(result, current_code)
                return
            end
            local fixed = llm_result.content or ""
            fixed = fixed:match("```lua\n(.-)```") or fixed:match("```\n(.-)```") or fixed
            fixed = fixed:match("^%s*(.-)%s*$")
            if fixed == "" then
                result.error = "LLM returned empty fix"
                on_done(result, current_code)
                return
            end
            current_code = fixed
            core.after(0, attempt)
        end)
    end

    core.after(0, attempt)
end

-- ===========================================================================

core.log("action", "[code_executor] module loaded")

return M
