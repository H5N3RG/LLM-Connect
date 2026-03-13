-- ===========================================================================
--  agent.lua — LLM Connect 1.0 Agent Orchestrator
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  ROLE: Orchestrator.
--    Receives a natural-language goal from the UI, assembles the tool
--    manifest and context from registry.lua, drives the LLM loop, dispatches
--    tool_calls back through the registry, and streams results to the GUI
--    via callbacks.
--
--  THIS FILE DOES NOT:
--    - communicate with the LLM directly         (→ llm_api.lua)
--    - know about specific addon implementations  (→ registry.lua + addons/)
--    - render anything                            (→ main_gui.lua)
--    - load or register addons                    (→ registry.lua)
--
--  PUBLIC API:
--    M.run(player_name, goal, options, callbacks)
--    M.undo(player_name)
--    M.cancel(player_name)
--    M.is_running(player_name)
--
--  RESPONSE FORMAT expected from LLM (all fields except tool_calls optional):
--    {
--      "thought":    "...",          -- reasoning, shown in UI, NOT in history
--      "plan":       "...",          -- one-liner for this step, goes into history
--      "tool_calls": [               -- list of actions to execute
--        { "tool": "tool_name", "args": { ... } }
--      ],
--      "done":   false,              -- true = agent signals completion
--      "reason": "..."               -- explanation when done=true
--    }
--
-- ===========================================================================

local core = core
local M    = {}

-- ===========================================================================
-- Per-player agent state
-- One entry per active or recently finished run.
-- Cleared on new run start.
-- ===========================================================================

local agent_state = {}
-- agent_state[player_name] = {
--   running      = bool,
--   cancelled    = bool,
--   iteration    = int,
--   goal         = string,
--   history      = [],     -- compact step log, O(1) token growth
--   snapshots    = {},     -- addon undo data, keyed by addon_id
-- }

local function get_state(name)
    if not agent_state[name] then
        agent_state[name] = {
            running   = false,
            cancelled = false,
            iteration = 0,
            goal      = "",
            history   = {},
            snapshots = {},
        }
    end
    return agent_state[name]
end

local function reset_state(name, goal)
    agent_state[name] = {
        running   = true,
        cancelled = false,
        iteration = 0,
        goal      = goal,
        history   = {},
        snapshots = {},
    }
    return agent_state[name]
end

-- Clean up on player leave
core.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    if agent_state[name] then
        agent_state[name].cancelled = true
        agent_state[name].running   = false
    end
end)

-- ===========================================================================
-- Internal helpers
-- ===========================================================================

-- Resolve dependencies at call time (not at load time) to avoid
-- circular dependency issues between modules loaded by init.lua.
local function get_registry()
    if not _G.registry then
        error("[agent] registry not available — check init.lua load order")
    end
    return _G.registry
end

local function get_llm_api()
    if not _G.llm_api then
        error("[agent] llm_api not available — check init.lua load order")
    end
    return _G.llm_api
end

local function get_basic_context()
    -- basic_context is optional per-call; graceful fallback if unavailable
    return _G.basic_context
end

-- ===========================================================================
-- Settings helpers
-- ===========================================================================

local function cfg_max_iterations()
    return tonumber(core.settings:get("llm_agent_max_iterations")) or 8
end

local function cfg_timeout()
    local t = tonumber(core.settings:get("llm_timeout_agent"))
    if t and t > 0 then return t end
    return tonumber(core.settings:get("llm_timeout")) or 120
end

local function cfg_snapshot_enabled()
    return core.settings:get_bool("llm_agent_snapshot", true)
end

-- ===========================================================================
-- JSON parsing — tolerant of markdown fences
-- ===========================================================================

local function parse_llm_response(raw)
    if type(raw) ~= "string" then
        return nil, "response is not a string"
    end
    -- Strip markdown fences if present
    local stripped = raw:match("```json%s*\n(.-)%s*```")
               or raw:match("```%s*\n(.-)%s*```")
               or raw
    stripped = stripped:match("^%s*(.-)%s*$")  -- trim whitespace

    local parsed = core.parse_json(stripped)
    if not parsed or type(parsed) ~= "table" then
        return nil, "invalid JSON: " .. tostring(stripped):sub(1, 120)
    end
    return parsed, nil
end

-- ===========================================================================
-- Stuck detection
-- Two consecutive iterations with identical plan text and no successful
-- tool calls → agent is looping without progress.
-- ===========================================================================

local function detect_stuck(history)
    local n = #history
    if n < 2 then return false end

    local last = history[n]
    local prev = history[n - 1]

    if last.plan ~= prev.plan then return false end

    -- Same plan — check if anything succeeded this time
    local any_ok = false
    for _, r in ipairs(last.results or {}) do
        if r.ok then any_ok = true; break end
    end
    return not any_ok
end

-- ===========================================================================
-- History builder — compact, O(1) token growth per step
-- Only plan + ok/fail counts per step, not full tool output.
-- ===========================================================================

local function build_history_text(history)
    if #history == 0 then return "" end
    local lines = {"", "Completed steps so far:"}
    for i, step in ipairs(history) do
        local ok_n, err_n = 0, 0
        for _, r in ipairs(step.results or {}) do
            if r.ok then ok_n = ok_n + 1 else err_n = err_n + 1 end
        end
        -- Include first failed tool message for LLM context
        local err_hint = ""
        if err_n > 0 then
            for _, r in ipairs(step.results or {}) do
                if not r.ok then
                    err_hint = "  ✗ " .. tostring(r.tool) .. ": " .. tostring(r.message):sub(1, 80)
                    break
                end
            end
        end
        table.insert(lines, string.format("  Step %d: %s  [✓%d ✗%d]%s",
            i, step.plan, ok_n, err_n, err_hint))
    end
    return table.concat(lines, "\n")
end

-- ===========================================================================
-- User message builder
-- Step 1: just the goal.
-- Step N: goal + compact history + instruction to continue.
-- ===========================================================================

local function build_user_message(goal, history, iteration)
    if iteration == 1 then
        return "Goal: " .. goal
    end
    return "Goal: " .. goal
        .. build_history_text(history)
        .. "\n\nContinue with the next step of your plan."
        .. " Set done=true when the entire goal is complete."
end

-- ===========================================================================
-- System prompt builder
-- Delegates to agent_system_prompts.lua for the heavy lifting.
-- Falls back to a minimal inline prompt if the external file is unavailable.
-- ===========================================================================

local agent_prompts   -- lazy loaded
local function get_agent_prompts()
    if agent_prompts then return agent_prompts end
    local ok, p = pcall(dofile,
        core.get_modpath("llm_connect") .. "/agent_system_prompts.lua")
    if ok and p then
        agent_prompts = p
    else
        core.log("warning", "[agent] agent_system_prompts.lua unavailable: "
            .. tostring(p) .. " — using fallback prompt")
        agent_prompts = {
            build = function(manifest_text, context_text)
                return table.concat({
                    "You are an AI agent inside a Luanti (Minetest) voxel game.",
                    "Execute the player's goal using the available tools.",
                    "Respond ONLY with a JSON object:",
                    '{ "thought": "...", "plan": "...", "tool_calls": [...], "done": false, "reason": "" }',
                    "",
                    "AVAILABLE TOOLS:",
                    manifest_text or "(none)",
                    "",
                    "CURRENT CONTEXT:",
                    context_text or "(none)",
                }, "\n")
            end,
        }
    end
    return agent_prompts
end

-- ===========================================================================
-- Snapshot & Undo
-- Delegates to registry, which calls each addon's snapshot_hook/restore_hook.
-- Agent stores the returned data per-player; registry knows how to restore it.
-- ===========================================================================

local function take_snapshot(state, player_name)
    if not cfg_snapshot_enabled() then return end
    local registry = get_registry()
    if registry.snapshot then
        local snap_data = registry.snapshot(player_name)
        state.snapshots = snap_data or {}
        core.log("action", "[agent] snapshot taken for " .. player_name)
    end
end

function M.undo(player_name)
    local state    = get_state(player_name)
    local registry = get_registry()
    if not registry.restore then
        return {ok = false, message = "No undo support in registry"}
    end
    local ok, err = registry.restore(player_name, state.snapshots)
    if ok then
        state.snapshots = {}
        return {ok = true, message = "Undo successful"}
    else
        return {ok = false, message = "Undo failed: " .. tostring(err)}
    end
end

-- ===========================================================================
-- Tool call execution
-- Dispatches a single tool_call through registry.
-- Returns a normalised result table.
-- ===========================================================================

local function execute_tool_call(tool_call, player_name)
    local tool_name = tool_call.tool
    local args      = tool_call.args or {}

    if not tool_name or tool_name == "" then
        return {tool = "(unnamed)", ok = false, message = "tool_call missing 'tool' field"}
    end

    -- Built-in: run_chat_command — generic command fallback
    -- Does not require an addon; player must have the privilege for the command.
    if tool_name == "run_chat_command" then
        return M._builtin_run_chat_command(args, player_name)
    end

    local registry = get_registry()
    local ok, result = pcall(registry.dispatch, tool_name, args, player_name)
    if not ok then
        -- pcall caught a Lua error in registry or addon
        return {tool = tool_name, ok = false, message = "dispatch error: " .. tostring(result)}
    end

    -- Normalise result — addons must return {ok, message}, data is optional
    result = result or {}
    return {
        tool    = tool_name,
        ok      = result.ok == true,
        message = result.message or "(no message)",
        data    = result.data,
    }
end

-- Execute a full list of tool_calls for one iteration.
-- Aborts chain on hard error (a result with ok=false and no recovery hint).
-- Returns: results[], had_hard_error bool
local function execute_tool_calls(tool_calls, player_name)
    local results       = {}
    local had_hard_error = false

    for i, call in ipairs(tool_calls) do
        local r = execute_tool_call(call, player_name)
        table.insert(results, r)

        if not r.ok then
            core.log("warning", string.format("[agent] tool '%s' failed: %s",
                tostring(r.tool), tostring(r.message)))
            -- Treat failure as hard error → abort chain
            -- Future: addons could signal "soft error" via r.recoverable = true
            had_hard_error = true
            table.insert(results, {
                tool    = "*",
                ok      = false,
                message = "Chain aborted at tool " .. i .. " (" .. tostring(r.tool) .. ")",
            })
            break
        end
    end

    return results, had_hard_error
end

-- ===========================================================================
-- Built-in tool: run_chat_command
-- Generic fallback — lets the LLM issue any chat command the player
-- is already privileged to run. Whitelist configurable in settings.
-- ===========================================================================

function M._builtin_run_chat_command(args, player_name)
    local cmd = tostring(args.command or "")
    if cmd == "" then
        return {tool = "run_chat_command", ok = false, message = "no command provided"}
    end

    -- Whitelist check (empty whitelist = all commands permitted)
    local whitelist_raw = core.settings:get("llm_agent_command_whitelist") or ""
    if whitelist_raw ~= "" then
        local allowed = false
        local cmd_base = cmd:match("^/?(%S+)") or cmd
        for entry in whitelist_raw:gmatch("[^,]+") do
            if entry:match("^%s*(.-)%s*$") == cmd_base then
                allowed = true; break
            end
        end
        if not allowed then
            return {tool = "run_chat_command", ok = false,
                message = "command not in whitelist: " .. cmd_base}
        end
    end

    -- Execute via core.handle_command
    -- Strip leading slash if present
    local bare = cmd:match("^/(.+)$") or cmd
    local cmdname, params = bare:match("^(%S+)%s*(.*)")
    if not cmdname then
        return {tool = "run_chat_command", ok = false, message = "malformed command"}
    end

    local cmd_def = core.registered_chatcommands[cmdname]
    if not cmd_def then
        return {tool = "run_chat_command", ok = false,
            message = "unknown command: " .. cmdname}
    end

    -- Privilege check — player must already be able to run this
    if cmd_def.privs then
        local player_privs = core.get_player_privs(player_name) or {}
        for priv in pairs(cmd_def.privs) do
            if not player_privs[priv] then
                return {tool = "run_chat_command", ok = false,
                    message = "missing privilege '" .. priv .. "' for /" .. cmdname}
            end
        end
    end

    local success, output = cmd_def.func(player_name, params or "")
    return {
        tool    = "run_chat_command",
        ok      = success ~= false,
        message = output or ("/" .. cmdname .. " executed"),
    }
end

-- ===========================================================================
-- Core: single LLM iteration
-- Builds messages, calls LLM, parses response, executes tools.
-- Calls callbacks.on_step and callbacks.on_thought during execution.
-- Returns: { ok, plan, results, done, reason, hard_error }
-- ===========================================================================

local function do_iteration(state, player_name, manifest_text, addon_filter, callbacks)
    state.iteration = state.iteration + 1
    local iteration = state.iteration

    -- Build context fresh each iteration (player may have moved, env changed)
    local context_parts = {}
    local basic_ctx = get_basic_context()
    if basic_ctx and basic_ctx.get then
        local bc = basic_ctx.get(player_name)
        if bc and bc ~= "" then table.insert(context_parts, bc) end
    end

    -- Addon-contributed context (e.g. WE pos1/pos2, nearby nodes)
    local registry = get_registry()
    if registry.get_contexts then
        local addon_ctx = registry.get_contexts(player_name, addon_filter)
        if addon_ctx and addon_ctx ~= "" then
            table.insert(context_parts, addon_ctx)
        end
    end

    local context_text = table.concat(context_parts, "\n\n")

    -- Build messages
    local prompts     = get_agent_prompts()
    local system_text = prompts.build(manifest_text, context_text)
    local user_text   = build_user_message(state.goal, state.history, iteration)

    local messages = {
        {role = "system", content = system_text},
        {role = "user",   content = user_text},
    }

    -- Notify UI that we're waiting for LLM
    if callbacks.on_step then
        pcall(callbacks.on_step, iteration, "⏳ Waiting for LLM…", {})
    end

    -- LLM request (async via Luanti HTTP)
    local llm_api = get_llm_api()
    local done_flag = false  -- set by callback, checked after

    llm_api.request(messages, function(result)
        if state.cancelled then
            if callbacks.on_done then
                pcall(callbacks.on_done, {
                    ok       = false,
                    finished = false,
                    reason   = "cancelled by player",
                    steps    = state.history,
                })
            end
            done_flag = true
            return
        end

        if not result.success then
            if callbacks.on_error then
                pcall(callbacks.on_error, result.error or "LLM request failed")
            end
            state.running = false
            done_flag = true
            return
        end

        -- Parse JSON
        local parsed, parse_err = parse_llm_response(result.content or "")
        if not parsed then
            if callbacks.on_error then
                pcall(callbacks.on_error, "JSON parse failed: " .. tostring(parse_err))
            end
            state.running = false
            done_flag = true
            return
        end

        local thought    = parsed.thought    -- optional, not stored in history
        local plan       = parsed.plan       or "(no plan)"
        local tool_calls = parsed.tool_calls or {}
        local is_done    = parsed.done       == true
        local reason     = parsed.reason     or ""

        -- Stream thought to UI if present (shown but not stored)
        if thought and thought ~= "" and callbacks.on_thought then
            pcall(callbacks.on_thought, thought)
        end

        -- Execute tool calls
        local results, had_hard_error = {}, false
        if type(tool_calls) == "table" and #tool_calls > 0 then
            results, had_hard_error = execute_tool_calls(tool_calls, player_name)
        end

        -- Record step in history (compact — plan + result counts only)
        local step = {
            iteration = iteration,
            plan      = plan,
            results   = results,
            done      = is_done,
        }
        table.insert(state.history, step)

        -- Notify UI with full step data
        if callbacks.on_step then
            pcall(callbacks.on_step, iteration, plan, results)
        end

        -- Termination conditions
        local stuck = detect_stuck(state.history)

        if is_done or had_hard_error or stuck then
            local final_reason
            if stuck then
                final_reason = "stuck: LLM repeated identical failing plan"
            elseif had_hard_error then
                final_reason = "aborted: hard error on iteration " .. iteration
            else
                final_reason = reason
            end

            state.running = false
            if callbacks.on_done then
                pcall(callbacks.on_done, {
                    ok       = not had_hard_error and not stuck,
                    finished = is_done and not had_hard_error and not stuck,
                    reason   = final_reason,
                    steps    = state.history,
                })
            end
            done_flag = true
            return
        end

        -- Max iterations check
        if iteration >= cfg_max_iterations() then
            state.running = false
            if callbacks.on_done then
                pcall(callbacks.on_done, {
                    ok       = true,
                    finished = false,
                    reason   = "reached max iterations (" .. cfg_max_iterations() .. ")",
                    steps    = state.history,
                })
            end
            done_flag = true
            return
        end

        -- Continue loop — schedule next iteration
        -- Luanti has no true async recursion; we use a 0-delay globalstep trick
        -- to avoid stack overflow on deep loops.
        core.after(0, function()
            if state.cancelled or not state.running then return end
            do_iteration(state, player_name, manifest_text, addon_filter, callbacks)
        end)

    end, {timeout = cfg_timeout()})
end

-- ===========================================================================
-- PUBLIC: M.run
-- Main entry point called by main_gui.lua.
--
-- player_name  string   — the player running the agent
-- goal         string   — natural language goal
-- options      table    — optional config overrides:
--   addon_filter   table|nil   — nil = all active addons, or {"worldedit", ...}
--   mode           string      — "loop" (default) | "single"
-- callbacks    table    — event hooks:
--   on_step(iter, plan, results)   — called after each iteration
--   on_thought(text)               — called when LLM emits a thought
--   on_done(result)                — called on completion or abort
--   on_error(message)              — called on hard errors
-- ===========================================================================

function M.run(player_name, goal, options, callbacks)
    options   = options   or {}
    callbacks = callbacks or {}

    -- Prevent double-run
    local existing = agent_state[player_name]
    if existing and existing.running then
        core.log("warning", "[agent] run() called while already running for " .. player_name)
        if callbacks.on_error then
            pcall(callbacks.on_error, "Agent already running — cancel first")
        end
        return
    end

    if not goal or goal:match("^%s*$") then
        if callbacks.on_error then
            pcall(callbacks.on_error, "Goal is empty")
        end
        return
    end

    local registry = get_registry()
    local llm_api  = get_llm_api()

    if not llm_api.is_configured() then
        if callbacks.on_error then
            pcall(callbacks.on_error, "LLM not configured — set API key, URL, and model")
        end
        return
    end

    -- Assemble tool manifest from registry (once per run, not per iteration)
    local manifest, manifest_text
    if registry.get_manifest then
        manifest      = registry.get_manifest(player_name, options.addon_filter)
        manifest_text = registry.manifest_to_text(manifest)
    else
        manifest      = {}
        manifest_text = "(no tools registered)"
    end

    if #manifest == 0 then
        core.log("warning", "[agent] no tools in manifest for " .. player_name
            .. " (addon_filter=" .. tostring(options.addon_filter) .. ")")
        -- Not a hard error — LLM can still use run_chat_command built-in
    end

    -- Initialise state
    local state = reset_state(player_name, goal)

    core.log("action", string.format("[agent] run() started for %s | goal: %s | tools: %d",
        player_name, goal:sub(1, 60), #manifest))

    -- Take snapshot before any execution
    take_snapshot(state, player_name)

    -- Single-shot mode: cap at 1 iteration
    if options.mode == "single" then
        local orig_max = cfg_max_iterations
        cfg_max_iterations = function() return 1 end
        do_iteration(state, player_name, manifest_text, options.addon_filter, callbacks)
        cfg_max_iterations = orig_max
    else
        do_iteration(state, player_name, manifest_text, options.addon_filter, callbacks)
    end
end

-- ===========================================================================
-- PUBLIC: M.cancel
-- Signals the running loop to stop after the current LLM call completes.
-- Does not interrupt an in-flight HTTP request.
-- ===========================================================================

function M.cancel(player_name)
    local state = agent_state[player_name]
    if state and state.running then
        state.cancelled = true
        state.running   = false
        core.log("action", "[agent] cancelled for " .. player_name)
        return true
    end
    return false
end

-- ===========================================================================
-- PUBLIC: M.is_running
-- ===========================================================================

function M.is_running(player_name)
    local state = agent_state[player_name]
    return state and state.running == true
end

-- ===========================================================================
-- PUBLIC: M.get_history
-- Returns the step history of the last (or current) run.
-- Used by main_gui.lua to display results after on_done.
-- ===========================================================================

function M.get_history(player_name)
    local state = agent_state[player_name]
    return state and state.history or {}
end

-- ===========================================================================
-- PUBLIC: M.format_results
-- Formats a completed run result into a human-readable string for the UI.
-- ===========================================================================

function M.format_results(result)
    if not result then return "No result." end
    if not result.ok then
        return "✗ Agent error: " .. (result.reason or "unknown")
    end

    local icon = result.finished and "✓" or "⚠"
    local lines = {
        icon .. " Agent finished after "
            .. #(result.steps or {}) .. " step(s)."
            .. (result.reason ~= "" and ("  " .. result.reason) or "")
    }

    for _, step in ipairs(result.steps or {}) do
        table.insert(lines, string.format("\n— Step %d: %s", step.iteration, step.plan))
        for _, r in ipairs(step.results or {}) do
            if r.tool ~= "*" then  -- skip internal chain-abort markers in display
                table.insert(lines, string.format("  %s %-22s %s",
                    r.ok and "✓" or "✗",
                    tostring(r.tool),
                    tostring(r.message):sub(1, 80)))
            end
        end
    end
    return table.concat(lines, "\n")
end

-- ===========================================================================

core.log("action", "[agent] loaded — orchestrator ready")

return M
