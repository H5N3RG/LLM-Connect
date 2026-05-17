-- ===========================================================================
--  core_executor.lua — LLM Connect v1.2.0-dev
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Shared execution backend for Smart Lua IDE, Agent runtime and future Skills.
--
--  Public API:
--    M.precheck(code)                  -> {ok, issues, registrations}
--    M.execute(player_name, code, opts)-> result table
--    M.execute_llm_response(name, text, opts) -> parse + execute
--    M.execute_with_retry(name, code, opts)   -> async LLM auto-fix loop
-- ===========================================================================

local core = core
local M = {}

M.execution_history = {}
M.version = "1.2.0-dev"

local function get_parser()
    return _G.parser_utils or (_G.llm_connect and _G.llm_connect.parser_utils)
end

local function get_policy()
    return _G.llm_connect and _G.llm_connect.policy
end

local function get_live_trace()
    return _G.llm_connect and _G.llm_connect.live_trace or rawget(_G, "live_trace")
end

local function live_emit(category, player_name, message, data)
    local trace = get_live_trace()
    if trace and trace.emit then
        pcall(trace.emit, category, player_name, message, data)
    end
end

local function get_runtime_scripts()
    return _G.runtime_scripts or (_G.llm_connect and _G.llm_connect.runtime_scripts)
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

local function root_bypasses_safety_filters(name)
    if not is_llm_root(name) then return false end
    local policy = get_policy()
    if policy and policy.root_bypasses_safety_filters then
        return policy.root_bypasses_safety_filters()
    end
    return core.settings:get_bool("llm_root_bypass_safety_filters", false)
end

local function root_allows_startup_execution(name)
    if not is_llm_root(name) then return false end
    local policy = get_policy()
    if policy and policy.root_allows_startup_execution then
        return policy.root_allows_startup_execution()
    end
    return core.settings:get_bool("llm_root_allow_startup_execution", false)
end

local function can_use_agent_skills(name)
    local policy = get_policy()
    if policy and policy.can_agent then return policy.can_agent(name) end
    return player_has_priv(name, "llm_agent") or player_has_priv(name, "llm_root")
end

local function create_safe_llm_connect(player_name, opts)
    opts = opts or {}
    local root = _G.llm_connect or {}

    -- Do not pass the real _G.llm_connect table into sandboxed code.
    -- It contains policy/executor/agent internals and skill functions.
    -- Skill APIs are exposed only for explicit agent/skill execution.
    local proxy = {
        version = root.version or M.version,
        protocol = root.protocol,
    }

    local allow_skills = (opts.purpose == "agent" or opts.purpose == "skill" or opts.allow_skills == true)
        and can_use_agent_skills(player_name)

    if allow_skills then
        local skills = root.skills or root.skills_subsystem
        if type(skills) == "table" and type(skills.make_sandbox_proxy) == "function" then
            proxy.skills = skills.make_sandbox_proxy(player_name)
        else
            proxy.skills = {}
        end

        local context_registry = root.context_registry or root.context
        if type(context_registry) == "table" then
            if type(context_registry.make_sandbox_proxy) == "function" then
                proxy.context = context_registry.make_sandbox_proxy(player_name)
            else
                proxy.context = context_registry
            end
        end
    end

    return proxy
end

-- ---------------------------------------------------------------------------
-- Sandbox / Shadow-G
-- ---------------------------------------------------------------------------

local function validate_pos(pos, fname)
    if type(pos) ~= "table" then
        error(("%s: position must be a table {x=number,y=number,z=number}, got %s"):format(fname, type(pos)), 3)
    end
    if type(pos.x) ~= "number" or type(pos.y) ~= "number" or type(pos.z) ~= "number" then
        error(("%s: position must contain numeric x/y/z fields"):format(fname), 3)
    end
end

local function validate_node_arg(node, fname)
    if type(node) == "string" then
        node = { name = node }
    end
    if type(node) ~= "table" then
        error(("%s: node must be a table {name='mod:node'} or a node name string, got %s"):format(fname, type(node)), 3)
    end
    if type(node.name) ~= "string" or node.name == "" then
        error(("%s: node.name must be a non-empty registered node name string"):format(fname), 3)
    end
    if core.registered_nodes and not core.registered_nodes[node.name] then
        error(("%s: unknown or unavailable node '%s'. Use llm_connect.context.get_section('luanti.registered_nodes.preview', {query='...'}) before placing nodes."):format(fname, node.name), 3)
    end
    return node
end

local function create_safe_core(player_name, opts)
    opts = opts or {}

    local function safe_set_node(pos, node)
        validate_pos(pos, "core.set_node")
        node = validate_node_arg(node, "core.set_node")
        return core.set_node(pos, node)
    end

    local function safe_add_node(pos, node)
        validate_pos(pos, "core.add_node")
        node = validate_node_arg(node, "core.add_node")
        return core.add_node(pos, node)
    end

    local function safe_swap_node(pos, node)
        validate_pos(pos, "core.swap_node")
        node = validate_node_arg(node, "core.swap_node")
        return core.swap_node(pos, node)
    end

    local function safe_remove_node(pos)
        validate_pos(pos, "core.remove_node")
        return core.remove_node(pos)
    end

    local safe_core = {
        -- logging / chat
        log                   = core.log,
        chat_send_player      = core.chat_send_player,
        chat_send_all         = core.chat_send_all,

        -- world reads / controlled writes
        get_node              = core.get_node,
        get_node_or_nil       = core.get_node_or_nil,
        set_node              = safe_set_node,
        swap_node             = safe_swap_node,
        remove_node           = safe_remove_node,
        add_node              = safe_add_node,
        get_meta              = core.get_meta,
        get_node_timer        = core.get_node_timer,
        find_node_near        = core.find_node_near,
        find_nodes_in_area    = core.find_nodes_in_area,

        -- players / objects
        get_player_by_name    = core.get_player_by_name,
        get_connected_players = core.get_connected_players,
        get_objects_inside_radius = core.get_objects_inside_radius,

        -- helpers commonly needed by generated Luanti code
        pos_to_string         = core.pos_to_string,
        string_to_pos         = core.string_to_pos,
        serialize             = core.serialize,
        deserialize           = core.deserialize,
        get_current_modname   = core.get_current_modname,
        get_modpath           = core.get_modpath,
        get_worldpath         = core.get_worldpath,
        after                 = core.after,
        sound_play            = core.sound_play,
        show_formspec         = core.show_formspec,
    }

    local function blocked_registration(fname)
        return function(...)
            core.log("warning", ("[core_executor] blocked registration call: %s by %s"):format(fname, tostring(player_name)))
            if player_name and player_name ~= "" then
                core.chat_send_player(player_name,
                    "Registrations are forbidden in sandbox mode. Only llm_root may execute these persistently.")
            end
            return nil
        end
    end

    safe_core.register_node      = blocked_registration("register_node")
    safe_core.register_tool      = blocked_registration("register_tool")
    safe_core.register_craftitem = blocked_registration("register_craftitem")
    safe_core.register_entity    = blocked_registration("register_entity")
    safe_core.register_craft     = blocked_registration("register_craft")

    return safe_core
end

local function create_sandbox_env(player_name, opts)
    local output_buffer = {}
    local env = {
        core = create_safe_core(player_name, opts),
        minetest = nil, -- filled below as alias
        llm_connect = create_safe_llm_connect(player_name, opts),
        player_name = player_name,

        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
            output_buffer[#output_buffer + 1] = table.concat(parts, "\t")
        end,

        tostring = tostring, tonumber = tonumber, type = type,
        pairs = pairs, ipairs = ipairs, next = next,
        table = table, string = string, math = math,
        unpack = unpack, select = select,
        pcall = pcall, xpcall = xpcall,
        error = error, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable,
        rawget = rawget, rawset = rawset, rawequal = rawequal,
        os = { clock = os.clock, date = os.date, difftime = os.difftime, time = os.time },
    }
    env.minetest = env.core

    local BLOCKED_GLOBALS = {
        io=true, require=true, dofile=true, loadfile=true,
        load=true, loadstring=true, debug=true, package=true,
        getfenv=true, setfenv=true,
    }

    setmetatable(env, {
        __index = function(_, key)
            if BLOCKED_GLOBALS[key] then return nil end
            return nil
        end,
        __newindex = function(t, key, value)
            rawset(t, key, value)
        end,
    })

    return env, output_buffer
end

-- ---------------------------------------------------------------------------
-- Precheck
-- ---------------------------------------------------------------------------

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

local function compile_lua(code, chunk_name)
    return loadstring(code, chunk_name or "=(llm_connect)")
end

function M.precheck(code, player_name, options)
    options = options or {}
    local issues = {}

    local parser = get_parser()
    local bypass_filters = options.bypass_safety_filters == true or root_bypasses_safety_filters(player_name)
    if parser and parser.contains_forbidden_patterns and not bypass_filters then
        local forbidden, hits = parser.contains_forbidden_patterns(code)
        if forbidden then
            issues[#issues + 1] = "Forbidden host-access pattern(s): " .. table.concat(hits, ", ")
        end
    end

    local func, syntax_err = compile_lua(code, "=(precheck)")
    if not func then
        local msg = tostring(syntax_err):gsub("^%[string .-%]:", "line ")
        issues[#issues + 1] = "Syntax error: " .. msg
        return { ok = false, issues = issues, registrations = {} }
    end

    -- IMPORTANT:
    -- Precheck must never execute the submitted chunk. The previous implementation
    -- installed a stub env and pcall(func) to discover registration calls. That made
    -- every agent/IDE execution run once during precheck and once during real execute,
    -- which doubled side effects such as set_node(), sound_play(), skill calls, timers,
    -- and chat output whenever they slipped through the stub layer.
    --
    -- Registration diagnostics below are intentionally static and conservative. They
    -- only inspect literal registrations that can be recognized safely from source text.
    local registrations = {}

    local function find_matching_paren(src, open_pos)
        local depth = 0
        local quote = nil
        local escape = false
        local long_string = false
        local i = open_pos
        while i <= #src do
            local ch = src:sub(i, i)
            local next2 = src:sub(i, i + 1)
            if quote then
                if escape then
                    escape = false
                elseif ch == "\\" and quote ~= "]]" then
                    escape = true
                elseif quote == "]]" and next2 == "]]" then
                    quote = nil
                    i = i + 1
                elseif ch == quote then
                    quote = nil
                end
            else
                if next2 == "[[" then
                    quote = "]]"
                    i = i + 1
                elseif ch == '"' or ch == "'" then
                    quote = ch
                elseif ch == "(" then
                    depth = depth + 1
                elseif ch == ")" then
                    depth = depth - 1
                    if depth == 0 then return i end
                end
            end
            i = i + 1
        end
        return nil
    end

    local function split_first_arg(call_src)
        local inner = call_src:match("^%s*%((.*)%)%s*$") or call_src
        local quote = nil
        local escape = false
        local depth = 0
        for i = 1, #inner do
            local ch = inner:sub(i, i)
            if quote then
                if escape then
                    escape = false
                elseif ch == "\\" then
                    escape = true
                elseif ch == quote then
                    quote = nil
                end
            else
                if ch == '"' or ch == "'" then
                    quote = ch
                elseif ch == "{" or ch == "(" or ch == "[" then
                    depth = depth + 1
                elseif ch == "}" or ch == ")" or ch == "]" then
                    if depth > 0 then depth = depth - 1 end
                elseif ch == "," and depth == 0 then
                    return inner:sub(1, i - 1), inner:sub(i + 1)
                end
            end
        end
        return inner, ""
    end

    local function static_registration_scan(src)
        for reg_type, _ in pairs(REQUIRED_FIELDS) do
            local search_from = 1
            local pattern = "[%.:]" .. reg_type .. "%s*%("
            while true do
                local call_start, open_pos = src:find(pattern, search_from)
                if not call_start then break end
                local close_pos = find_matching_paren(src, open_pos)
                if not close_pos then break end

                local call_src = src:sub(open_pos, close_pos)
                local first_arg, def_src = split_first_arg(call_src)
                local reg_name = first_arg and first_arg:match("^%s*['\"]([^'\"]+)['\"]%s*$") or nil
                local entry = {reg_type = reg_type, name = reg_name or "<dynamic>", static = true}

                if reg_name then
                    local naming_err = check_naming(reg_name)
                    if naming_err then entry.naming_error = naming_err end
                else
                    entry.dynamic_name = true
                end

                local missing = {}
                for _, field in ipairs(REQUIRED_FIELDS[reg_type] or {}) do
                    local has_field = def_src and (
                        def_src:find(field .. "%s*=", 1) or
                        def_src:find("%[\"" .. field .. "\"%]%s*=", 1) or
                        def_src:find("%['" .. field .. "'%]%s*=", 1)
                    )
                    if not has_field then missing[#missing + 1] = field end
                end
                if #missing > 0 then entry.missing_fields = missing end

                registrations[#registrations + 1] = entry
                search_from = close_pos + 1
            end
        end
    end

    static_registration_scan(code)

    for _, entry in ipairs(registrations) do
        if entry.naming_error then issues[#issues + 1] = "Naming: " .. entry.naming_error end
        if entry.dynamic_name then
            issues[#issues + 1] = ("Dynamic name in %s() cannot be fully validated statically"):format(entry.reg_type)
        end
        if entry.missing_fields then
            issues[#issues + 1] = ("Missing required fields in %s('%s'): %s")
                :format(entry.reg_type, tostring(entry.name), table.concat(entry.missing_fields, ", "))
        end
    end

    return { ok = #issues == 0, issues = issues, registrations = registrations }
end

-- ---------------------------------------------------------------------------
-- Execute
-- ---------------------------------------------------------------------------

function M.execute(player_name, code, options)
    options = options or {}
    local result = { success = false, ok = false }
    live_emit("executor", player_name, "execute requested", {
        purpose = options.purpose,
        sandbox = options.sandbox,
        required_priv = options.required_priv,
        bytes = type(code) == "string" and #code or 0,
    })

    if type(code) ~= "string" or code:match("^%s*$") then
        result.error = "No or empty code provided"
        return result
    end

    local parser = get_parser()
    if parser and options.skip_repair ~= true then
        code = parser.auto_repair_lua(code)
    end

    local root = is_llm_root(player_name)
    local root_bypass_filters = root_bypasses_safety_filters(player_name)
    local root_allow_startup = root_allows_startup_execution(player_name)

    if root_bypass_filters then
        options.bypass_safety_filters = true
        options.allow_dangerous = true
    end
    if root_allow_startup then
        options.allow_startup_execution = true
    end

    local runtime_scripts = get_runtime_scripts()
    local classification = runtime_scripts and runtime_scripts.classify
        and runtime_scripts.classify(code, {mode = options.mode or "llm_runtime", modname = options.modname})
        or {class = "unknown", hot_reloadable = false, persistable = false, issues = {"runtime_scripts classifier unavailable"}}
    result.classification = classification
    result.script_class = classification.class
    result.hot_reloadable = classification.hot_reloadable
    result.requires_restart = classification.requires_restart

    if classification.class == "dangerous" and options.allow_dangerous ~= true then
        result.error = "Blocked dangerous code: " .. table.concat(classification.issues or {}, "; ")
        live_emit("precheck", player_name, result.error, { class = classification.class })
        return result
    end

    if classification.class == "startup_preferred" and options.allow_startup_execution ~= true then
        result.error = "Code contains startup-preferred registrations and was not executed transiently. Save it for startup or use root experimental execution."
        result.requires_restart = true
        live_emit("precheck", player_name, result.error, { class = classification.class })
        return result
    end

    local policy = get_policy()
    local required_priv = options.required_priv or "llm_dev"
    local purpose = options.purpose
        or ((required_priv == "llm_agent") and "agent" or "ide")

    local exec_ctx
    if policy and policy.resolve_execution then
        exec_ctx = policy.resolve_execution(player_name, purpose, options)
    elseif policy and policy.resolve_ide_execution then
        exec_ctx = policy.resolve_ide_execution(player_name, options)
    end

    if exec_ctx and exec_ctx.bypass_safety_filters then
        options.bypass_safety_filters = true
        options.allow_dangerous = true
    end
    if exec_ctx and exec_ctx.allow_startup_execution then
        options.allow_startup_execution = true
    end

    local use_sandbox
    if exec_ctx and exec_ctx.sandbox ~= nil then
        use_sandbox = exec_ctx.sandbox
    else
        use_sandbox = options.sandbox ~= false
    end
    local allow_persist = ((options.allow_persist ~= nil) and options.allow_persist)
        or (exec_ctx and exec_ctx.can_persist)
        or false

    if not has_llm_priv(player_name, required_priv) then
        result.error = "Missing privilege: " .. required_priv .. " (or llm_root)"
        return result
    end

    if exec_ctx and exec_ctx.execution_mode == "denied" then
        result.error = "Execution denied by policy for purpose: " .. tostring(purpose)
        return result
    end

    if allow_persist and not root then
        allow_persist = false
    end

    if options.precheck ~= false then
        local pre = M.precheck(code, player_name, options)
        result.precheck = pre
        if not pre.ok then
            result.precheck_warnings = table.concat(pre.issues, "\n")
            core.log("warning", ("[core_executor] pre-check issues for %s:\n%s"):format(tostring(player_name), result.precheck_warnings))
            if result.precheck_warnings:match("Syntax error") or result.precheck_warnings:match("Forbidden host%-access") then
                result.error = result.precheck_warnings
                return result
            end
        end
    end

    local func, compile_err = compile_lua(code, options.chunk_name or "=(llm_connect_runtime)")
    if not func then
        result.error = "Compile error: " .. tostring(compile_err)
        return result
    end

    local output_buffer = {}
    local old_print
    local old_player_name = rawget(_G, "player_name")

    if use_sandbox then
        local env
        env, output_buffer = create_sandbox_env(player_name, options)
        setfenv(func, env)
    else
        if not root then
            result.error = "Unrestricted execution only allowed for llm_root"
            return result
        end
        old_print = print
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
            output_buffer[#output_buffer + 1] = table.concat(parts, "\t")
        end
        -- Root can opt agent actions out of the sandbox, but the agent contract
        -- still promises player_name. Keep this scoped to the executed chunk so
        -- direct llm_connect.context.load('...') calls can resolve privileges.
        rawset(_G, "player_name", player_name)
    end

    local ok, exec_res = xpcall(function() return func() end, debug.traceback)
    if not use_sandbox then
        if old_print then print = old_print end
        rawset(_G, "player_name", old_player_name)
    end

    result.code = code
    result.output = table.concat(output_buffer, "\n")
    if result.precheck_warnings then
        result.output = "⚠ Pre-check warnings:\n" .. result.precheck_warnings .. "\n\n" .. result.output
    end

    if ok then
        result.success = true
        result.ok = true
        result.return_value = exec_res
        core.log("action", ("[core_executor] success by %s (sandbox=%s)"):format(tostring(player_name), tostring(use_sandbox)))
        live_emit("executor", player_name, "execution success", {
            sandbox = use_sandbox,
            class = result.script_class,
            output = result.output,
        })
    else
        result.error = "Runtime error: " .. tostring(exec_res)
        result.traceback = tostring(exec_res)
        core.log("warning", ("[core_executor] execution failed for %s: %s"):format(tostring(player_name), result.error))
        live_emit("runtime", player_name, result.error, {
            sandbox = use_sandbox,
            class = result.script_class,
        })
    end

    if classification and classification.class and classification.class ~= "runtime_safe" then
        local summary = "\n\n" .. (runtime_scripts and runtime_scripts.format_class_summary
            and runtime_scripts.format_class_summary(classification)
            or ("Class: " .. tostring(classification.class)))
        result.output = (result.output or "") .. summary
    end

    M.execution_history[player_name] = M.execution_history[player_name] or {}
    table.insert(M.execution_history[player_name], {
        timestamp = os.time(),
        code = code:sub(1, 200) .. (code:len() > 200 and "..." or ""),
        success = result.success,
        output = result.output,
        error = result.error,
    })

    return result
end

function M.execute_llm_response(player_name, response_text, opts)
    opts = opts or {}
    local parser = get_parser()
    if not parser or not parser.parse_llm_response then
        return { success = false, ok = false, error = "parser_utils not available" }
    end
    local parsed = parser.parse_llm_response(response_text, opts)
    if not parsed.ok then
        return { success = false, ok = false, parse = parsed, error = "Could not extract executable Lua: " .. tostring(parsed.reason) }
    end
    local result = M.execute(player_name, parsed.code, opts)
    result.parse = parsed
    return result
end

-- ---------------------------------------------------------------------------
-- Retry loop
-- ---------------------------------------------------------------------------

local DEFAULT_FIXER_PROMPT = [[You are a Luanti Lua code fixer running inside LLM Connect.
You will receive a code block and the error it produced.
Return ONLY corrected Lua code, no markdown, no explanation.
Preserve intent. Prefer the core.* namespace. Do not add os/io/debug/require/dofile/loadfile/package.]]

function M.execute_with_retry(player_name, code, opts)
    opts = opts or {}
    local max_iter = opts.max_iterations or 3
    local on_iter = opts.on_iteration
    local on_done = opts.on_done
    local llm_req = opts.llm_request
    local sys_prompt = opts.system_prompt or DEFAULT_FIXER_PROMPT

    if not on_done or not llm_req then
        core.log("error", "[core_executor] execute_with_retry: on_done and llm_request are required")
        return
    end

    local iteration = 0
    local last_error = nil
    local current_code = code

    local function attempt()
        iteration = iteration + 1
        if on_iter then on_iter(iteration, current_code, last_error) end

        local result = M.execute(player_name, current_code, {
            sandbox = opts.sandbox,
            precheck = true,
            allow_persist = opts.allow_persist,
            required_priv = opts.required_priv,
            purpose = opts.purpose,
            profile = opts.profile,
        })

        if result.success then on_done(result, current_code); return end

        local err_msg = ""
        if result.precheck_warnings then err_msg = "Pre-check warnings:\n" .. result.precheck_warnings .. "\n" end
        if result.error then err_msg = err_msg .. result.error end
        if result.output and result.output ~= "" then err_msg = err_msg .. "\nOutput:\n" .. result.output end

        if err_msg == last_error or iteration >= max_iter then
            result.debug_loop_aborted = (err_msg == last_error)
            on_done(result, current_code)
            return
        end
        last_error = err_msg

        local messages = {
            {role = "system", content = sys_prompt},
            {role = "user", content = "Code:\n```lua\n" .. current_code .. "\n```\n\nError:\n" .. err_msg},
        }

        llm_req(messages, function(llm_result)
            if not llm_result.success then
                result.error = "LLM fix request failed: " .. (llm_result.error or "?")
                on_done(result, current_code)
                return
            end
            local parser = get_parser()
            local fixed = llm_result.content or ""
            if parser and parser.extract_best_lua then
                local parsed = parser.extract_best_lua(fixed)
                fixed = parsed.ok and parsed.code or fixed
            end
            fixed = parser and parser.auto_repair_lua and parser.auto_repair_lua(fixed) or fixed:match("^%s*(.-)%s*$")
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

core.log("action", "[core_executor] module loaded")

return M
