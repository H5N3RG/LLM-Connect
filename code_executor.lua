-- code_executor.lua
-- Secure Lua code execution for LLM-Connect / Smart Lua IDE
-- Privileges:
--   llm_dev  → Sandbox + Whitelist, no persistent registrations
--   llm_root → Unrestricted execution + persistent registrations possible
--
-- v0.9.0-dev additions:
--   M.precheck(code)              → Pre-executor: syntax + naming + field validation
--   M.execute_with_retry(...)     → Debug-loop: auto-fix via LLM on failure (max N iters)

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

    -- ── _G fallback: mod globals (default, stairs, vector, etc.) ──
    -- Blocked: dangerous stdlib (io, os.execute, debug, require, etc.)
    -- Everything else falls through to the real game environment.
    local BLOCKED_GLOBALS = {
        io = true, require = true, dofile = true, loadfile = true,
        load = true, loadstring = true, rawget = true, rawset = true,
        rawequal = true, getfenv = true, setfenv = true,
        debug = true,   -- debug library
        package = true,
    }
    -- Partially allow os (only safe subset)
    local safe_os = { clock = os.clock, date = os.date,
                      difftime = os.difftime, time = os.time }

    setmetatable(env, {
        __index = function(_, key)
            if BLOCKED_GLOBALS[key] then return nil end
            if key == "os" then return safe_os end
            return _G[key]
        end
    })

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
--  PRE-EXECUTOR: Syntax + Naming + Field Validation
--  Runs in a stub sandbox – no real registrations happen.
--  Returns: { ok=bool, issues={string,...} }
--  Issues are human-readable and LLM-friendly (can be injected
--  directly as last_run_output for the debug loop).
-- =============================================================

-- Required fields per registration type (engine enforces these)
local REQUIRED_FIELDS = {
    register_node      = { "tiles" },
    register_tool      = { "inventory_image" },
    register_craftitem = {},   -- description is optional, nothing strictly required
    register_entity    = { "initial_properties" },
}

-- Known naming convention prefixes that are always valid
local VALID_PREFIXES = { "llm_connect:", "default:", "stairs:", "doors:",
                         "farming:", "fire:", "flowers:", "beds:", "bucket:",
                         "vessels:", "wool:", "dye:", "screwdriver:",
                         "xpanes:", "moreblocks:" }

local function check_naming(reg_name)
    -- Must contain a colon
    if not reg_name:find(":") then
        return ("Name '%s' missing mod prefix (e.g. 'llm_connect:my_node')"):format(reg_name)
    end
    -- Warn if not llm_connect: prefix (other mods are fine to READ but not register under)
    local prefix = reg_name:match("^([^:]+):")
    if prefix and prefix ~= "llm_connect" then
        -- Only an issue if it looks like they invented a modname
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

    -- ── 1. Syntax check via loadstring ──────────────────────
    local func, syntax_err = loadstring(code, "=(precheck)")
    if not func then
        -- Normalise the error: strip the chunk name prefix
        local msg = tostring(syntax_err):gsub("^%[string .-%]:", "line ")
        return { ok = false, issues = { "Syntax error: " .. msg } }
    end

    -- ── 2. Stub environment – intercepts registration calls ─
    local registrations = {}   -- collect all attempted registrations

    local function make_stub(reg_type)
        return function(reg_name, def)
            def = def or {}
            local entry = { reg_type = reg_type, name = reg_name, def = def }

            -- Naming convention check
            local naming_err = check_naming(tostring(reg_name or ""))
            if naming_err then
                entry.naming_error = naming_err
            end

            -- Required fields check
            local required = REQUIRED_FIELDS[reg_type] or {}
            local missing = {}
            for _, field in ipairs(required) do
                if def[field] == nil then
                    table.insert(missing, field)
                end
            end
            if #missing > 0 then
                entry.missing_fields = missing
            end

            table.insert(registrations, entry)
        end
    end

    -- The stub_env intercepts registration calls for validation but falls
    -- back to _G for everything else (all loaded mods, vector, ItemStack, etc.)
    -- This way default.node_sound_*(), stairs, doors, any mod API all work
    -- without needing to be listed explicitly.
    local stub_core = {
        -- Intercept registrations → validate, don't execute
        register_node      = make_stub("register_node"),
        register_tool      = make_stub("register_tool"),
        register_craftitem = make_stub("register_craftitem"),
        register_craft     = function() end,
        register_entity    = make_stub("register_entity"),
        -- Silence noisy callbacks (they'd schedule real game hooks)
        register_chatcommand              = function() end,
        register_globalstep               = function() end,
        register_on_joinplayer            = function() end,
        register_on_leaveplayer           = function() end,
        register_on_player_receive_fields = function() end,
        register_on_chat_message          = function() end,
        register_on_generated             = function() end,
        register_abm                      = function() end,
        register_lbm                      = function() end,
        -- Silence side-effect calls
        log              = function() end,
        chat_send_player = function() end,
        chat_send_all    = function() end,
        after            = function() end,
        sound_play       = function() end,
        show_formspec    = function() end,
    }
    -- Forward any other core.* access to the real core (read-only ops, registered_nodes, etc.)
    setmetatable(stub_core, { __index = core })

    local stub_env = { print = function() end, core = stub_core }
    -- Fall back to _G for everything not explicitly set:
    -- default, stairs, doors, vector, ItemStack, math, string, table, etc.
    setmetatable(stub_env, { __index = _G })

    setfenv(func, stub_env)
    local ok, run_err = pcall(func)

    -- ── 3. Collect runtime issues from stub run ──────────────
    if not ok then
        -- Runtime errors in precheck: likely a logic error or missing global
        local msg = tostring(run_err):gsub("^%[string .-%]:", "line ")
        table.insert(issues, "Runtime error (pre-check): " .. msg)
    end

    -- ── 4. Evaluate registration results ────────────────────
    for _, entry in ipairs(registrations) do
        if entry.naming_error then
            table.insert(issues, "Naming: " .. entry.naming_error)
        end
        if entry.missing_fields then
            table.insert(issues,
                ("Missing required fields in %s('%s'): %s")
                :format(entry.reg_type, entry.name,
                        table.concat(entry.missing_fields, ", ")))
        end
    end

    return {
        ok           = #issues == 0,
        issues       = issues,
        registrations = registrations,   -- for debug output if needed
    }
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
    --  0. Pre-check (optional, default: on)
    -- =============================================
    if options.precheck ~= false then
        local pre = M.precheck(code)
        result.precheck = pre
        if not pre.ok then
            -- Surface issues but don't hard-block – let user decide
            result.precheck_warnings = table.concat(pre.issues, "\n")
            core.log("warning", ("[code_executor] Pre-check issues for %s:\n%s")
                :format(player_name, result.precheck_warnings))
            -- Hard-block on syntax errors (there's no point running)
            if pre.issues[1] and pre.issues[1]:match("^Syntax error") then
                result.error = result.precheck_warnings
                return result
            end
        end
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
        setfenv(func, env)
    else
        -- Unrestricted mode → Careful!
        if not is_root then
            result.error = "Unrestricted execution only allowed for llm_root"
            return result
        end

        local old_print = print
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts+1] = tostring(select(i, ...)) end
            local line = table.concat(parts, "\t")
            table.insert(output_buffer, line)
        end
    end

    -- =============================================
    --  3. Execute
    -- =============================================
    local ok, exec_res = pcall(function()
        return func()
    end)

    if not use_sandbox then
        print = old_print
    end

    -- =============================================
    --  4. Process result
    -- =============================================
    result.output = table.concat(output_buffer, "\n")

    -- Prepend any precheck warnings to output so they're visible in the IDE
    if result.precheck_warnings then
        local warn_block = "⚠ Pre-check warnings:\n" .. result.precheck_warnings .. "\n\n"
        result.output = warn_block .. (result.output or "")
    end

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
            if not result.success then
                -- Do NOT persist broken code
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
            result.error = (result.error or "") .. "\n" .. msg
            result.success = false
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
--  DEBUG LOOP: execute → on failure → LLM auto-fix → retry
--
--  opts:
--    max_iterations  int     max fix attempts (default: 3)
--    on_iteration    func(i, code, error)   callback per attempt
--    on_done         func(result, code)     final callback
--    llm_request     func(messages, cb)     LLM call (from llm_api)
--    system_prompt   string  override default fixer prompt
--    sandbox         bool    passed through to execute()
-- =============================================================

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
    local max_iter   = opts.max_iterations or 3
    local on_iter    = opts.on_iteration   -- optional: fn(iter, code, err_msg)
    local on_done    = opts.on_done        -- required: fn(result, final_code)
    local llm_req    = opts.llm_request    -- required: fn(messages, callback)
    local sys_prompt = opts.system_prompt or DEFAULT_FIXER_PROMPT

    if not on_done or not llm_req then
        core.log("error", "[code_executor] execute_with_retry: on_done and llm_request are required")
        return
    end

    local iteration   = 0
    local last_error  = nil
    local current_code = code

    local function attempt()
        iteration = iteration + 1

        if on_iter then
            on_iter(iteration, current_code, last_error)
        end

        local result = M.execute(player_name, current_code, {
            sandbox  = opts.sandbox,
            precheck = true,
        })

        if result.success then
            -- Done – no fix needed
            on_done(result, current_code)
            return
        end

        -- Collect error message (precheck warnings + runtime error)
        local err_msg = ""
        if result.precheck_warnings then
            err_msg = "Pre-check warnings:\n" .. result.precheck_warnings .. "\n"
        end
        if result.error then
            err_msg = err_msg .. result.error
        end
        if result.output and result.output ~= "" then
            err_msg = err_msg .. "\nOutput:\n" .. result.output
        end

        -- Abort if same error repeats (LLM is stuck)
        if err_msg == last_error then
            result.debug_loop_aborted = true
            result.debug_loop_reason  = "Repeated identical error – LLM stuck, aborting"
            core.log("warning", ("[code_executor] Debug loop aborted for %s: repeated error"):format(player_name))
            on_done(result, current_code)
            return
        end
        last_error = err_msg

        -- Max iterations reached
        if iteration >= max_iter then
            result.debug_loop_aborted = true
            result.debug_loop_reason  = ("Max iterations (%d) reached"):format(max_iter)
            on_done(result, current_code)
            return
        end

        -- Ask LLM to fix the code
        core.log("action", ("[code_executor] Debug loop iter %d for %s"):format(iteration, player_name))

        local messages = {
            { role = "system", content = sys_prompt },
            { role = "user",   content =
                "Code:\n```lua\n" .. current_code .. "\n```\n\n" ..
                "Error:\n" .. err_msg .. "\n\n" ..
                "Return the fixed Lua code only." },
        }

        llm_req(messages, function(llm_result)
            if not llm_result.success or not llm_result.content then
                -- LLM request failed – abort loop
                local r = { success = false,
                             error = "LLM fix request failed: " .. (llm_result.error or "unknown"),
                             debug_loop_aborted = true,
                             debug_loop_reason  = "LLM unavailable" }
                on_done(r, current_code)
                return
            end

            -- Strip any accidental markdown fences the LLM may add
            local fixed = llm_result.content
                :gsub("^%s*```%w*%s*\n", "")
                :gsub("\n```%s*$", "")
                :gsub("^%s*```%s*\n", "")

            current_code = fixed
            attempt()   -- recurse into next iteration
        end)
    end

    attempt()
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
