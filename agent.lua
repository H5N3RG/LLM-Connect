-- ===========================================================================
--  agent.lua — LLM Connect v1.1.0-dev Dual-Channel Agent Orchestrator
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  ROLE:
--    One visible chat channel + one hidden Lua action channel.
--
--  FLOW:
--    main_gui.lua -> agent.run()
--    agent.lua -> llm_api.lua
--    parser_utils.lua splits visible text from ```lua_action blocks
--    core_executor.lua executes only explicit action blocks
--
--  RULE:
--    Normal chat must stay normal. Lua only runs when the model explicitly
--    emits a marked lua_action block and at least one skill is active.
-- ===========================================================================

local core = core
local M = {}

M.version = "1.1.0-dev"
M.protocol = "dual-channel-lua-action"

local agent_state = {}

local function get_state(name)
    if not agent_state[name] then
        agent_state[name] = {
            running = false,
            cancelled = false,
            iteration = 0,
            max_iterations = 1,
            message = "",
            tool_history = {},
        }
    end
    return agent_state[name]
end

local function get_llm_api()
    if not _G.llm_api then error("[agent] llm_api not available — check init.lua load order") end
    return _G.llm_api
end

local function get_root()
    return rawget(_G, "llm_connect")
end

local function get_parser()
    local root = get_root()
    return rawget(_G, "parser_utils") or (type(root) == "table" and root.parser_utils or nil)
end

local function get_executor()
    local root = get_root()
    return rawget(_G, "core_executor") or (type(root) == "table" and root.core_executor or nil)
end

local function get_registry()
    local root = get_root()
    return (type(root) == "table" and root.registry or nil) or rawget(_G, "registry")
end

local function get_basic_context()
    local root = get_root()
    return rawget(_G, "basic_context") or (type(root) == "table" and root.basic_context or nil)
end

local function get_policy()
    local root = get_root()
    return type(root) == "table" and root.policy or nil
end

local function can_agent(player_name)
    local policy = get_policy()
    if policy and policy.can_agent then return policy.can_agent(player_name) end
    local privs = core.get_player_privs(player_name) or {}
    return privs.llm_agent == true or privs.llm_root == true
end

local function cfg_timeout()
    local llm_api = rawget(_G, "llm_api")
    if llm_api and llm_api.get_timeout then return llm_api.get_timeout("agent") end
    return tonumber(core.settings:get("llm_timeout_agent")) or tonumber(core.settings:get("llm_timeout")) or 120
end

local function cfg_max_iterations(options)
    local srv_max = tonumber(core.settings:get("llm_agent_max_iterations")) or 4
    local req = options and tonumber(options.max_iterations)
    if req and req >= 1 then return math.min(math.floor(req), srv_max) end
    return srv_max
end

local function reset_state(name, message, options)
    agent_state[name] = {
        running = true,
        cancelled = false,
        iteration = 0,
        max_iterations = cfg_max_iterations(options),
        message = message,
        visible_parts = {},
        action_results = {},
        tool_history = {},
        failure_retries = 0,
        last_failure_signature = nil,
        options = options or {},
    }
    return agent_state[name]
end

core.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    if agent_state[name] then
        agent_state[name].cancelled = true
        agent_state[name].running = false
    end
end)

local function trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function one_line(s, max_len)
    s = tostring(s or "")
    s = s:gsub("\n+", " "):gsub("%s+", " ")
    max_len = max_len or 120
    if #s > max_len then return s:sub(1, max_len - 3) .. "..." end
    return s
end

local function collect_basic_context(player_name)
    local basic_context = get_basic_context()
    if not basic_context then return "" end

    local fn = basic_context.get_agent or basic_context.get
    if type(fn) == "function" then
        local ok, ctx = pcall(fn, player_name)
        if ok and ctx and ctx ~= "" then return tostring(ctx) end
        if not ok then core.log("warning", "[agent] basic_context failed: " .. tostring(ctx)) end
    end
    return ""
end

local function collect_skill_context(player_name, options)
    local registry = get_registry()
    if not registry then return "" end
    local parts = {}
    if registry.describe_for_agent then
        local ok, text = pcall(registry.describe_for_agent, player_name, options and options.skill_filter)
        if ok and text and text ~= "" then parts[#parts + 1] = tostring(text) end
    end
    -- Do not inject full skill/API manuals here. Since 1.2-prep, detailed
    -- context is fetched on demand through llm_connect.context.* from lua_action.
    return table.concat(parts, "\n\n")
end

local function active_skill_count(player_name)
    local registry = get_registry()
    if not registry or not registry.get_status then return 0 end
    local ok, status = pcall(registry.get_status, player_name)
    if not ok or type(status) ~= "table" then return 0 end
    local n = 0
    for _, s in ipairs(status) do
        if s.effective then n = n + 1 end
    end
    return n
end

local function build_system_prompt(player_name, options)
    local basic = collect_basic_context(player_name)
    local skills = collect_skill_context(player_name, options)

    local lines = {
        "You are LLM Connect inside a Luanti server.",
        "You have two output channels:",
        "1) Visible chat text: normal natural language shown to the player.",
        "2) Hidden action blocks: executable Lua enclosed in exactly ```lua_action fences.",
        "",
        "Default behavior: answer normally in visible chat text.",
        "Only use a lua_action block when an active skill/context makes an in-game action necessary.",
        "Never wrap normal explanations in Lua. Keep visible chat text outside action blocks.",
        "Text outside lua_action is visible to the player. lua_action content is hidden and executed by core_executor.lua.",
        "The prompt is intentionally compact. Do not guess missing APIs, node names, server state, or skill details.",
        "When details are needed, first request focused context through llm_connect.context.* inside lua_action.",
        "",
        "Action block format:",
        "```lua_action",
        "-- Lua code here",
        "return { done = true, message = \"short result\" }",
        "```",
        "",
        "Lua action rules:",
        "- player_name is available in the sandbox.",
        "- core is available as the safe Luanti API namespace.",
        "- Prefer small, reversible steps.",
        "- Do not register nodes/items/entities/crafts during runtime.",
        "- If no action is needed, do not emit any lua_action block.",
        "- For multi-step work, including context lookup before acting, return {done=false, continue=true, message=\"...\"}; otherwise stop.",
        "- Self-context API: llm_connect.context.list_sections(), llm_connect.context.search(query), llm_connect.context.get_section(id).",
    }

    if basic ~= "" then
        lines[#lines + 1] = "\n[BASIC SERVER CONTEXT]\n" .. basic
    end
    if skills ~= "" then
        lines[#lines + 1] = "\n[ACTIVE SKILL CONTEXT]\n" .. skills
    else
        lines[#lines + 1] = "\n[ACTIVE SKILL CONTEXT]\nNo skills are active. Answer in plain chat; do not use lua_action."
    end

    return table.concat(lines, "\n")
end

local function build_messages(player_name, user_message, state)
    local messages = {
        { role = "system", content = build_system_prompt(player_name, state.options) },
    }

    if #state.tool_history > 0 then
        messages[#messages + 1] = {
            role = "system",
            content = "Previous action results for this task:\n" .. table.concat(state.tool_history, "\n"),
        }
    end

    messages[#messages + 1] = { role = "user", content = user_message }
    return messages
end

local function action_result_message(result)
    if not result then return "no result" end
    if result.success or result.ok then
        local rv = result.return_value
        if type(rv) == "table" then
            if type(rv.content) == "string" and rv.content ~= "" then
                return tostring(rv.message or "context loaded") .. "\n" .. rv.content
            end
            if type(rv.sections) == "table" then
                local lines = { tostring(rv.message or "context sections") }
                for _, sec in ipairs(rv.sections) do
                    lines[#lines + 1] = string.format("- %s: %s", tostring(sec.id or "?"), tostring(sec.summary or sec.title or ""))
                end
                return table.concat(lines, "\n")
            end
            return tostring(rv.message or rv.result or rv.status or "ok")
        end
        if result.output and result.output ~= "" then return result.output end
        return "ok"
    end
    return tostring(result.error or "failed")
end

local function is_context_action_code(code)
    code = tostring(code or "")
    local uses_context = code:find("llm_connect%.context", 1, false) ~= nil
    if not uses_context then return false end

    -- Treat pure context lookups as intermediate steps. If a model combines
    -- context and a real skill action in one block, let the explicit return
    -- value decide whether to continue.
    local uses_skill = code:find("llm_connect%.skills", 1, false) ~= nil
    return not uses_skill
end

local function mark_context_continuation(result)
    if not result or not (result.success or result.ok) then return end
    if result.is_context_action ~= true then return end

    -- Context lookups are intermediate agent steps, not final task answers.
    -- Some models return the context proxy table directly, others wrap it into
    -- their own {message=...} table, and weaker models may call the context API
    -- but forget to set continue=true. Normalize all successful context actions
    -- into a continuation request so the next iteration can use the loaded data.
    if type(result.return_value) == "table" then
        result.return_value.done = false
        result.return_value.continue = true
        if not result.return_value.message or result.return_value.message == "" then
            result.return_value.message = "Context lookup completed"
        end
    else
        result.return_value = {
            done = false,
            continue = true,
            message = "Context lookup completed",
        }
    end
end

local function wants_continue(result)
    if not result or not (result.success or result.ok) then return false end
    if result.is_context_action == true then return true end
    local rv = result.return_value
    if type(rv) ~= "table" then return false end
    if rv.continue == true then return true end
    if rv.done == false then return true end
    return false
end

local function action_history_entry(iteration, result)
    local prefix = string.format(
        "iteration %d action %d: %s — ",
        iteration,
        tonumber(result and result.index) or 0,
        (result and (result.success or result.ok)) and "ok" or "failed"
    )

    local rv = result and result.return_value
    if type(rv) == "table" and type(rv.content) == "string" and rv.content ~= "" then
        local content = rv.content
        if #content > 6000 then content = content:sub(1, 6000) .. "\n... [context truncated]" end
        return prefix .. tostring(rv.message or "context loaded") .. "\n" .. content
    end
    if type(rv) == "table" and type(rv.sections) == "table" then
        local lines = { prefix .. tostring(rv.message or "context sections") }
        for _, sec in ipairs(rv.sections) do
            lines[#lines + 1] = string.format("- %s: %s", tostring(sec.id or "?"), tostring(sec.summary or sec.title or ""))
        end
        return table.concat(lines, "\n")
    end
    if result and not (result.success or result.ok) then
        local lines = { prefix .. one_line(result.error or result.message or "failed", 240) }
        if result.action_code and result.action_code ~= "" then
            lines[#lines + 1] = "Failed lua_action code:"
            lines[#lines + 1] = "```lua"
            lines[#lines + 1] = tostring(result.action_code)
            lines[#lines + 1] = "```"
        end
        if result.traceback and result.traceback ~= "" then
            lines[#lines + 1] = "Traceback/error detail:"
            lines[#lines + 1] = one_line(result.traceback, 1200)
        end
        lines[#lines + 1] = "Repair instruction: either request focused context first, or emit a corrected lua_action. Do not repeat the same failing action."
        return table.concat(lines, "\n")
    end

    return prefix .. one_line(result and (result.message or result.error or "") or "", 180)
end

local function failure_signature(result)
    if not result then return nil end
    local err = tostring(result.error or result.message or "")
    local code = tostring(result.action_code or result.code or "")
    return err:sub(1, 220) .. "\n" .. code:sub(1, 600)
end

local function should_retry_failed_actions(state, action_results)
    if not state or not action_results or #action_results == 0 then return false end
    local failed
    for _, r in ipairs(action_results) do
        if not (r.success or r.ok) then
            failed = r
            break
        end
    end
    if not failed then return false end
    if state.failure_retries and state.failure_retries >= 1 then return false end

    local sig = failure_signature(failed)
    if sig and state.last_failure_signature == sig then return false end
    state.last_failure_signature = sig
    state.failure_retries = (state.failure_retries or 0) + 1
    core.log("warning", ("[agent] action failed; scheduling one repair iteration for %s"):format(tostring(state.message or "task")))
    return true
end

local function execute_actions(player_name, actions)
    local executor = get_executor()
    local results = {}
    if not executor or not executor.execute then
        return {{ ok = false, success = false, tool = "lua_action", message = "core_executor unavailable" }}
    end

    for i, action in ipairs(actions or {}) do
        local code = action.code or ""
        local result = executor.execute(player_name, code, {
            sandbox = true,
            required_priv = "llm_agent",
            purpose = "agent",
            source = "agent.lua_action",
            chunk_name = "=(llm_connect_agent_action)",
        })
        result.tool = "lua_action"
        result.index = i
        result.action_code = code
        result.is_context_action = is_context_action_code(code)
        mark_context_continuation(result)
        result.message = action_result_message(result)
        results[#results + 1] = result
    end
    return results
end

local function finish(state, callbacks, result)
    state.running = false
    if callbacks and callbacks.on_done then callbacks.on_done(result) end
end

local function fail(state, callbacks, err)
    state.running = false
    if callbacks and callbacks.on_error then callbacks.on_error(err) end
end

local function run_iteration(player_name, user_message, state, callbacks)
    if state.cancelled then return fail(state, callbacks, "cancelled") end
    if state.iteration >= state.max_iterations then
        return finish(state, callbacks, {
            success = true,
            ok = true,
            visible_text = table.concat(state.visible_parts, "\n\n"),
            action_results = state.action_results,
            stopped = "max_iterations",
        })
    end

    state.iteration = state.iteration + 1
    local llm_api = get_llm_api()
    local parser = get_parser()
    if not parser or not parser.split_dual_channel_response then
        return fail(state, callbacks, "parser_utils.split_dual_channel_response unavailable")
    end

    if callbacks and callbacks.on_thought then
        callbacks.on_thought("thinking")
    end

    llm_api.request(build_messages(player_name, user_message, state), function(response)
        if state.cancelled then return fail(state, callbacks, "cancelled") end
        if not response or not response.success then
            return fail(state, callbacks, response and response.error or "LLM request failed")
        end

        local split = parser.split_dual_channel_response(response.content or "")
        local visible = trim(split.visible_text or "")
        if visible ~= "" then state.visible_parts[#state.visible_parts + 1] = visible end

        local actions = split.actions or {}
        local action_results = {}

        if #actions > 0 then
            action_results = execute_actions(player_name, actions)
            for _, r in ipairs(action_results) do
                state.action_results[#state.action_results + 1] = r
                state.tool_history[#state.tool_history + 1] = action_history_entry(state.iteration, r)
            end
        end

        if callbacks and callbacks.on_step then
            callbacks.on_step(state.iteration, visible ~= "" and visible or "action", action_results)
        end

        local continue = false
        for _, r in ipairs(action_results) do
            if wants_continue(r) then continue = true break end
        end
        if not continue and should_retry_failed_actions(state, action_results) then
            continue = true
        end

        if continue and state.iteration < state.max_iterations then
            return run_iteration(player_name, user_message, state, callbacks)
        end

        return finish(state, callbacks, {
            success = true,
            ok = true,
            visible_text = table.concat(state.visible_parts, "\n\n"),
            actions = actions,
            action_results = state.action_results,
            iterations = state.iteration,
            raw = response.content,
        })
    end, { timeout = cfg_timeout() })
end

function M.run(player_name, message, options, callbacks)
    callbacks = callbacks or {}
    options = options or {}

    if not can_agent(player_name) then
        if callbacks.on_error then callbacks.on_error("missing privilege: llm_agent") end
        return false
    end

    local state = get_state(player_name)
    if state.running then
        if callbacks.on_error then callbacks.on_error("agent already running") end
        return false
    end

    local skill_count = active_skill_count(player_name)
    if skill_count <= 0 then
        if callbacks.on_error then callbacks.on_error("no active skills; use plain chat") end
        return false
    end

    state = reset_state(player_name, message, options)
    core.log("action", string.format(
        "[agent] dual-channel run started for %s | max_iterations=%d | active_skills=%d | message=%s",
        tostring(player_name), state.max_iterations, skill_count, tostring(message)
    ))
    run_iteration(player_name, message, state, callbacks)
    return true
end

function M.cancel(player_name)
    local state = get_state(player_name)
    state.cancelled = true
    state.running = false
    return true
end

function M.is_running(player_name)
    return get_state(player_name).running == true
end

function M.format_results(result)
    if not result then return "(no result)" end
    if not (result.success or result.ok) then
        return "✗ Error: " .. tostring(result.error or "unknown")
    end
    local visible = trim(result.visible_text or "")
    if visible ~= "" then return visible end

    local count = #(result.action_results or {})
    if count > 0 then
        local last = result.action_results[count]
        return "✓ Action completed: " .. one_line(last and (last.message or last.output or "ok") or "ok", 120)
    end
    return "(no visible response)"
end

core.log("action", "[agent] loaded — dual-channel Lua action orchestrator ready")

return M
