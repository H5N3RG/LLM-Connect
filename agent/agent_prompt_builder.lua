-- ===========================================================================
--  agent_prompt_builder.lua — mode-aware prompt construction for agent runtime
-- ===========================================================================

local M = {}

local function get_root()
    return rawget(_G, "llm_connect")
end

local function get_skills()
    local root = get_root()
    return type(root) == "table" and (root.skills or root.skills_subsystem or root.registry) or rawget(_G, "registry")
end

local function get_context()
    local root = get_root()
    return type(root) == "table" and (root.context_modules or root.context or root.basic_context) or rawget(_G, "basic_context")
end

local function collect_basic_context(player_name)
    local context = get_context()
    if not context then return "" end

    local fn = context.get_agent or context.get
    if type(fn) == "function" then
        local ok, ctx = pcall(fn, player_name, "agent")
        if ok and ctx and ctx ~= "" then return tostring(ctx) end
        if not ok and core and core.log then core.log("warning", "[agent_prompt_builder] context failed: " .. tostring(ctx)) end
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
    return table.concat(parts, "\n\n")
end

function M.build_system_prompt(player_name, options, state, deps)
    deps = deps or {}
    local basic = collect_basic_context(player_name)
    local skills = collect_skill_context(player_name, options)
    local cached = ""
    if deps.context_cache and deps.context_cache.render_for_prompt then
        cached = deps.context_cache.render_for_prompt(state, 6000)
    end

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
    if cached ~= "" then
        lines[#lines + 1] = "\n[RETRIEVED CONTEXT CACHE]\n" .. cached
    end

    if state and state.capability_snapshot then
        lines[#lines + 1] = "\n[CAPABILITY SNAPSHOT]\nactive_skill_count=" .. tostring(state.capability_snapshot.active_skill_count or 0) ..
            "\nfingerprint=" .. tostring(state.capability_snapshot.fingerprint or "")
    end

    return table.concat(lines, "\n")
end

function M.build_messages(player_name, user_message, state, deps)
    local messages = {
        { role = "system", content = M.build_system_prompt(player_name, state and state.options or {}, state, deps) },
    }

    if state and state.tool_history and #state.tool_history > 0 then
        messages[#messages + 1] = {
            role = "system",
            content = "Previous action results for this task:\n" .. table.concat(state.tool_history, "\n"),
        }
    end

    messages[#messages + 1] = { role = "user", content = tostring(user_message or "") }
    return messages
end

return M
