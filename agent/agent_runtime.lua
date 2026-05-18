-- ===========================================================================
--  agent_runtime.lua — LLM Connect v1.2.0-dev Dual-Channel Agent Orchestrator
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  ROLE:
--    One visible chat channel + one hidden Lua action channel.
--
--  FLOW:
--    main_gui.lua -> agent.run()
--    agent_runtime.lua -> llm_api.lua
--    parser_utils.lua splits visible text from ```lua_action blocks
--    core_executor.lua executes only explicit action blocks
--
--  RULE:
--    Normal chat must stay normal. Lua only runs when the model explicitly
--    emits a marked lua_action block and at least one skill is active.
-- ===========================================================================

local core = core
local M = {}

M.version = "1.2.0-dev"
M.protocol = "dual-channel-lua-action"

local mod_dir = core.get_modpath(core.get_current_modname())
local AGENT_DIR = mod_dir .. "/agent"

local function load_agent_module(global_name, filename)
    local root = rawget(_G, "llm_connect")
    if type(root) == "table" then
        if type(root.agent_modules) == "table" and root.agent_modules[global_name] then
            return root.agent_modules[global_name]
        end
        if root[global_name] then return root[global_name] end
    end
    local path = AGENT_DIR .. "/" .. filename
    local ok, module = pcall(dofile, path)
    if not ok then
        local msg = "failed to load middleware module " .. tostring(global_name) .. " from " .. tostring(path) .. ": " .. tostring(module)
        core.log("warning", "[agent] " .. msg)
        local health = root and root.health
        if health and health.mark_failed then health.mark_failed("agent_runtime." .. tostring(global_name), msg) end
        module = {}
    end
    if module == nil then
        local msg = "middleware module returned nil: " .. tostring(global_name) .. " from " .. tostring(path)
        core.log("warning", "[agent] " .. msg)
        local health = root and root.health
        if health and health.mark_failed then health.mark_failed("agent_runtime." .. tostring(global_name), msg) end
        module = {}
    end
    _G.llm_connect = root or {}
    _G.llm_connect[global_name] = module
    return module
end

local state_store    = load_agent_module("agent_state", "agent_state.lua")
local capabilities   = load_agent_module("agent_capabilities", "agent_capabilities.lua")
local context_cache  = load_agent_module("agent_context_cache", "agent_context_cache.lua")
local result_utils   = load_agent_module("agent_result", "agent_result.lua")
local retry_policy   = load_agent_module("agent_retry", "agent_retry.lua")
local middleware     = load_agent_module("agent_middleware", "agent_middleware.lua")
local prompt_builder = load_agent_module("agent_prompt_builder", "agent_prompt_builder.lua")

-- Degraded-mode defaults. These keep agent_runtime loadable even when one
-- middleware helper is absent; the agent will then fail gracefully at runtime
-- instead of crashing during mod bootstrap.
local fallback_states = {}
if type(state_store.get) ~= "function" then
    state_store.get = function(name)
        fallback_states[name] = fallback_states[name] or { running = false, visible_parts = {}, action_results = {}, tool_history = {}, iteration = 0, max_iterations = 1 }
        return fallback_states[name]
    end
end
if type(state_store.reset) ~= "function" then
    state_store.reset = function(name, message, options)
        local st = { player_name = name, message = message, options = options or {}, running = true, cancelled = false, visible_parts = {}, action_results = {}, tool_history = {}, iteration = 0, max_iterations = (options and options.max_iterations) or 1 }
        fallback_states[name] = st
        return st
    end
end
state_store.set_capability_snapshot = state_store.set_capability_snapshot or function(state, snapshot) state.capability_snapshot = snapshot end
state_store.cancel = state_store.cancel or function(name) if fallback_states[name] then fallback_states[name].cancelled = true; fallback_states[name].running = false end end
state_store.is_running = state_store.is_running or function(name) return fallback_states[name] and fallback_states[name].running == true or false end
state_store.append_visible = state_store.append_visible or function(state, text) if text and text ~= "" then state.visible_parts[#state.visible_parts + 1] = text end end
state_store.append_action_result = state_store.append_action_result or function(state, result) state.action_results[#state.action_results + 1] = result end
state_store.append_tool_history = state_store.append_tool_history or function(state, entry) state.tool_history[#state.tool_history + 1] = entry end

capabilities.snapshot = capabilities.snapshot or function() return {} end
capabilities.active_skill_count = capabilities.active_skill_count or function() return 0 end
context_cache.observe_result = context_cache.observe_result or function() end
result_utils.trim = result_utils.trim or function(x) return tostring(x or ""):match("^%s*(.-)%s*$") or "" end
result_utils.one_line = result_utils.one_line or function(x, max_len) local t = tostring(x or ""):gsub("%s+", " "); if max_len and #t > max_len then return t:sub(1, max_len) end; return t end
result_utils.action_result_message = result_utils.action_result_message or function(result) return result and (result.message or result.error) or "" end
result_utils.action_history_entry = result_utils.action_history_entry or function(iteration, result) return { iteration = iteration, result = result } end
result_utils.format_results = result_utils.format_results or function(result) return tostring(result and (result.message or result.visible_text) or "") end
retry_policy.failure_signature = retry_policy.failure_signature or function(result) return tostring(result and (result.error or result.message) or "unknown") end
retry_policy.should_retry_failed_actions = retry_policy.should_retry_failed_actions or function() return false end
middleware.decide_after_step = middleware.decide_after_step or function() return { continue = false, reason = "agent middleware unavailable" } end
prompt_builder.build_messages = prompt_builder.build_messages or function(player_name, user_message, state) return { { role = "system", content = build_system_prompt and build_system_prompt(player_name, state and state.options or {}) or "LLM Connect agent degraded" }, { role = "user", content = tostring(user_message or "") } } end

local function get_state(name)
    return state_store.get(name)
end

local function get_api()
    local root = rawget(_G, "llm_connect")
    local api = type(root) == "table" and root.api or nil
    if not api then
        return {
            request = function(_, callback)
                if callback then callback({ success = false, error = "api subsystem unavailable" }) end
                return false
            end,
            get_timeout = function() return 30 end,
        }
    end
    return api
end

local function get_root()
    return rawget(_G, "llm_connect")
end

local function get_parser()
    local root = get_root()
    return rawget(_G, "parser_utils") or (type(root) == "table" and root.parser_utils or nil)
end

local function get_runtime()
    local root = get_root()
    return type(root) == "table" and (root.runtime or root.core_executor) or rawget(_G, "core_executor")
end

local function get_live_trace()
    local root = get_root()
    return type(root) == "table" and root.live_trace or rawget(_G, "live_trace")
end

local function live_emit(category, player_name, message, data)
    local trace = get_live_trace()
    if trace and trace.emit then
        pcall(trace.emit, category, player_name, message, data)
    end
end

local function live_lua(player_name, code)
    local trace = get_live_trace()
    if trace and trace.emit_lua then
        pcall(trace.emit_lua, player_name, code)
    end
end

local function get_skills()
    local root = get_root()
    return type(root) == "table" and (root.skills or root.skills_subsystem or root.registry) or rawget(_G, "registry")
end

local function get_context()
    local root = get_root()
    return type(root) == "table" and (root.context_modules or root.context or root.basic_context) or rawget(_G, "basic_context")
end

local function get_policy()
    local root = get_root()
    return type(root) == "table" and root.policy or nil
end

local function can_agent(player_name)
    if core.settings:get_bool("llm_agent_enabled", true) == false then return false end
    local policy = get_policy()
    if policy and policy.can_agent then return policy.can_agent(player_name) end
    local privs = core.get_player_privs(player_name) or {}
    return privs.llm_agent == true or privs.llm_root == true
end

local function cfg_timeout()
    local api = get_api()
    if api and api.get_timeout then return api.get_timeout("agent") end
    return tonumber(core.settings:get("llm_timeout_agent")) or tonumber(core.settings:get("llm_timeout")) or 120
end

local function cfg_max_iterations(options)
    local srv_max = tonumber(core.settings:get("llm_agent_max_iterations")) or 4
    local req = options and tonumber(options.max_iterations)
    if req and req >= 1 then return math.min(math.floor(req), srv_max) end
    return srv_max
end

local function reset_state(name, message, options)
    options = options or {}
    local effective_options = {}
    for k, v in pairs(options) do effective_options[k] = v end
    effective_options.max_iterations = cfg_max_iterations(options)

    local state = state_store.reset(name, message, effective_options)
    state.max_iterations = effective_options.max_iterations
    state_store.set_capability_snapshot(state, capabilities.snapshot(name, effective_options))
    return state
end

core.register_on_leaveplayer(function(player)
    state_store.cancel(player:get_player_name())
end)

local function trim(s)
    return result_utils.trim(s)
end

local function one_line(s, max_len)
    return result_utils.one_line(s, max_len)
end

local function collect_basic_context(player_name)
    local context = get_context()
    if not context then return "" end

    local fn = context.get_agent or context.get
    if type(fn) == "function" then
        local ok, ctx = pcall(fn, player_name, "agent")
        if ok and ctx and ctx ~= "" then return tostring(ctx) end
        if not ok then core.log("warning", "[agent] context failed: " .. tostring(ctx)) end
    end
    return ""
end

local function collect_skill_context(player_name, options)
    local skills = get_skills()
    if not skills then return "" end
    local parts = {}
    if skills.describe_for_agent then
        local ok, text = pcall(skills.describe_for_agent, player_name, options and options.skill_filter)
        if ok and text and text ~= "" then parts[#parts + 1] = tostring(text) end
    end
    -- Do not inject full skill/API manuals here. Since 1.2-prep, detailed
    -- context is fetched on demand through llm_connect.context.* from lua_action.
    return table.concat(parts, "\n\n")
end

local function active_skill_count(player_name)
    return capabilities.active_skill_count(player_name)
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
    return prompt_builder.build_messages(player_name, user_message, state, {
        context_cache = context_cache,
    })
end

local function action_result_message(result)
    return result_utils.action_result_message(result)
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

    local explicit_continue = false
    if type(result.return_value) == "table" then
        explicit_continue = result.return_value.continue == true or result.return_value.done == false
    end

    -- Context lookups are intermediate only when they yielded useful context.
    -- Empty/failed lookups usually stop instead of creating search fog loops,
    -- except when the action explicitly requested another iteration. In that
    -- case, pass the lookup failure forward so the next model turn can repair
    -- the context key or proceed with already cached documentation.
    if type(result.return_value) == "table" then
        local rv = result.return_value
        local has_content = type(rv.content) == "string" and rv.content ~= ""
        local has_hits = type(rv.sections) == "table" and #rv.sections > 0
        local recent = result.retrieved_context
        local recent_failed = false
        if type(recent) == "table" then
            recent_failed = recent.ok == false
            has_content = has_content or (type(recent.content) == "string" and recent.content ~= "")
            has_hits = has_hits or (type(recent.sections) == "table" and #recent.sections > 0)
        end
        if rv.ok ~= false and (has_content or has_hits) then
            rv.done = false
            rv.continue = true
        elseif explicit_continue then
            rv.done = false
            rv.continue = true
            if recent_failed and type(recent.message) == "string" and recent.message ~= "" then
                rv.message = "Context lookup failed: " .. recent.message .. ". Continue using available cached context or list valid context keys."
                result.context_lookup_failed = true
            elseif not rv.message or rv.message == "" then
                rv.message = "Context lookup returned no content. Continue using available cached context or list valid context keys."
            end
        else
            rv.done = true
            rv.continue = false
        end
        if not rv.message or rv.message == "" then
            rv.message = "Context lookup completed"
        end
    else
        result.return_value = {
            done = true,
            continue = false,
            message = "Context lookup returned no structured result",
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
    return result_utils.action_history_entry(iteration, result)
end

local function failure_signature(result)
    return retry_policy.failure_signature(result)
end

local function should_retry_failed_actions(state, action_results)
    return retry_policy.should_retry_failed_actions(state, action_results)
end

local function execute_actions(player_name, actions)
    local runtime = get_runtime()
    local results = {}
    if not runtime or not runtime.execute then
        return {{ ok = false, success = false, tool = "lua_action", message = "core_executor unavailable" }}
    end

    for i, action in ipairs(actions or {}) do
        local code = action.code or ""
        live_emit("executor", player_name, "execute lua_action #" .. tostring(i), { bytes = #code })
        live_lua(player_name, code)
        local result = runtime.execute({
            actor = player_name,
            origin = "agent.runtime",
            role = "llm_agent",
            action = "run_lua_action",
            code = code,
            options = {
            sandbox = true,
            required_priv = "llm_agent",
            purpose = "agent",
            source = "agent_runtime.lua_action",
            chunk_name = "=(llm_connect_agent_action)",
            }
        })
        result.tool = "lua_action"
        result.index = i
        result.action_code = code
        result.is_context_action = is_context_action_code(code)
        if result.is_context_action == true then
            local root = get_root()
            local registry = type(root) == "table" and (root.context_registry or (root.context_modules and root.context_modules.registry)) or nil
            if registry and type(registry.consume_recent_context) == "function" then
                result.retrieved_context = registry.consume_recent_context(player_name)
            end
        end
        mark_context_continuation(result)
        result.message = action_result_message(result)
        live_emit(result.ok and "executor" or "error", player_name, result.message, {
            tool = result.tool,
            script_class = result.script_class,
            error = result.error,
        })
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
    live_emit("agent", player_name, "iteration " .. tostring(state.iteration) .. "/" .. tostring(state.max_iterations), {
        active_skills = state.capability_snapshot and state.capability_snapshot.active_skill_count,
        fingerprint = state.capability_snapshot and state.capability_snapshot.fingerprint,
    })
    local api = get_api()
    local parser = get_parser()
    if not parser or not parser.split_dual_channel_response then
        return fail(state, callbacks, "parser_utils.split_dual_channel_response unavailable")
    end

    if callbacks and callbacks.on_thought then
        callbacks.on_thought("thinking")
    end
    live_emit("prompt", player_name, "building agent messages", {
        iteration = state.iteration,
        history = state.tool_history and #state.tool_history or 0,
    })

    api.request(build_messages(player_name, user_message, state), function(response)
        if state.cancelled then return fail(state, callbacks, "cancelled") end
        if not response or not response.success then
            return fail(state, callbacks, response and response.error or "LLM request failed")
        end

        local split = parser.split_dual_channel_response(response.content or "")
        local visible = trim(split.visible_text or "")
        local actions = split.actions or {}
        live_emit("parser", player_name, "dual-channel split", {
            visible_chars = #visible,
            actions = #actions,
            finish_reason = response.finish_reason,
        })
        local action_results = {}

        if #actions > 0 then
            action_results = execute_actions(player_name, actions)
            for _, r in ipairs(action_results) do
                context_cache.observe_result(state, r)
                state_store.append_action_result(state, r)
                state_store.append_tool_history(state, action_history_entry(state.iteration, r))
            end
        end

        if callbacks and callbacks.on_step then
            callbacks.on_step(state.iteration, visible ~= "" and visible or "action", action_results)
        end

        local decision = middleware.decide_after_step(state, action_results, {
            retry = retry_policy,
        })
        live_emit("middleware", player_name, "decision", decision)
        local continue = decision.continue == true

        -- Visible text that accompanies lua_action is step/status text. Keep it
        -- out of the final answer so planning chatter from intermediate
        -- iterations does not masquerade as completion. Pure text turns remain
        -- normal chat responses.
        if #actions == 0 then
            state_store.append_visible(state, visible)
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
    end, { timeout = cfg_timeout(), mode = "agent", actor = player_name })
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
    live_emit("agent", player_name, "run started", {
        max_iterations = state.max_iterations,
        active_skills = skill_count,
        message = tostring(message),
    })
    core.log("action", string.format(
        "[agent] dual-channel run started for %s | max_iterations=%d | active_skills=%d | message=%s",
        tostring(player_name), state.max_iterations, skill_count, tostring(message)
    ))
    run_iteration(player_name, message, state, callbacks)
    return true
end

function M.resume(player_name, callbacks)
    callbacks = callbacks or {}
    if not can_agent(player_name) then
        if callbacks.on_error then callbacks.on_error("missing privilege: llm_agent") end
        return false
    end

    local state = get_state(player_name)
    if state.running then
        if callbacks.on_error then callbacks.on_error("agent already running") end
        return false
    end
    if not state.message or state.message == "" then
        if callbacks.on_error then callbacks.on_error("no resumable agent task") end
        return false
    end
    if state.iteration >= state.max_iterations then
        if callbacks.on_error then callbacks.on_error("agent iteration limit reached") end
        return false
    end

    state.running = true
    state.cancelled = false
    live_emit("agent", player_name, "run resumed", {
        iteration = state.iteration,
        max_iterations = state.max_iterations,
        message = tostring(state.message),
    })
    run_iteration(player_name, state.message, state, callbacks)
    return true
end

function M.cancel(player_name)
    state_store.cancel(player_name)
    return true
end

function M.is_running(player_name)
    return state_store.is_running(player_name)
end

function M.request_permission(player_name, request)
    return state_store.request_permission(player_name, request)
end

function M.get_pending_permission(player_name)
    return state_store.get_pending_permission(player_name)
end

function M.resolve_permission(player_name, allowed)
    return state_store.resolve_permission(player_name, allowed == true)
end

function M.format_results(result)
    return result_utils.format_results(result)
end

core.log("action", "[agent] loaded — dual-channel Lua action orchestrator ready")

return M
