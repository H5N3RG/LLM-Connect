-- ===========================================================================
--  agent_context.lua — prompt context, retrieved context cache, capabilities
-- ===========================================================================

local M = {}

local function get_communication()
    local root = rawget(_G, "llm_connect")
    return type(root) == "table" and root.agent_communication or rawget(_G, "agent_communication") or {}
end

-- ---------------------------------------------------------------------------
-- Capability snapshots
-- ---------------------------------------------------------------------------

local capabilities = {}

function capabilities.snapshot(player_name, options)
    local communication = get_communication()
    local status = communication.get_skill_status and communication.get_skill_status(player_name) or nil
    local snapshot = {
        player_name = tostring(player_name or ""),
        active_skill_count = 0,
        skills = {},
        provider = communication.get_provider and communication.get_provider() or nil,
        fingerprint = status and "" or "no-registry",
    }

    if type(status) == "table" then
        local fp = {}
        for _, skill in ipairs(status) do
            local effective = skill.effective == true
            local id = tostring(skill.id or skill.name or "?")
            snapshot.skills[#snapshot.skills + 1] = {
                id = id,
                name = tostring(skill.name or id),
                effective = effective,
                version = tostring(skill.version or ""),
            }
            if effective then
                snapshot.active_skill_count = snapshot.active_skill_count + 1
                fp[#fp + 1] = id .. ":" .. tostring(skill.version or "")
            end
        end
        snapshot.fingerprint = table.concat(fp, "|")
    end

    return snapshot
end

function capabilities.active_skill_count(player_name)
    return capabilities.snapshot(player_name).active_skill_count or 0
end

function capabilities.changed(old_snapshot, new_snapshot)
    if not old_snapshot or not new_snapshot then return false end
    return tostring(old_snapshot.fingerprint or "") ~= tostring(new_snapshot.fingerprint or "")
end

-- ---------------------------------------------------------------------------
-- Retrieved context cache
-- ---------------------------------------------------------------------------

local context_cache = {}

local function ensure_cache(state)
    state.context_cache = state.context_cache or { sections = {}, order = {} }
    state.context_cache.sections = state.context_cache.sections or {}
    state.context_cache.order = state.context_cache.order or {}
    return state.context_cache
end

local function remember_section(cache, id, title, content)
    id = tostring(id or "")
    if id == "" then return end
    if cache.sections[id] == nil then
        cache.order[#cache.order + 1] = id
    end
    cache.sections[id] = {
        id = id,
        title = tostring(title or id),
        content = tostring(content or ""),
    }
end

function context_cache.observe_result(state, result)
    if not state or not result or not (result.success or result.ok) then return end
    local rv = result.retrieved_context or result.return_value
    if type(rv) ~= "table" then return end

    local cache = ensure_cache(state)

    if type(rv.id) == "string" and type(rv.content) == "string" then
        remember_section(cache, rv.id, rv.title or rv.message, rv.content)
    elseif type(rv.section) == "table" then
        remember_section(cache, rv.section.id, rv.section.title or rv.message, rv.section.content)
    elseif type(rv.sections) == "table" then
        -- Search/list results contain summaries, not full manuals. Do not inject
        -- summaries as if they were loaded context; that confused the agent into
        -- thinking it had documentation it never loaded.
        for _, section in ipairs(rv.sections) do
            if type(section) == "table" and type(section.content) == "string" and section.content ~= "" then
                remember_section(cache, section.id, section.title or section.summary, section.content)
            end
        end
    elseif type(rv.content) == "string" and result.is_context_action == true then
        local id = "context-action-" .. tostring(#cache.order + 1)
        remember_section(cache, id, rv.message or "Context action", rv.content)
    end
end

function context_cache.render_for_prompt(state, max_chars)
    if not state or not state.context_cache then return "" end
    local cache = ensure_cache(state)
    local blocks = {}
    local remaining = tonumber(max_chars) or 6000

    for _, id in ipairs(cache.order) do
        local sec = cache.sections[id]
        if sec and sec.content and sec.content ~= "" and remaining > 0 then
            local block = ("[CACHED CONTEXT: %s]\n%s"):format(tostring(sec.title or id), tostring(sec.content))
            if #block > remaining then block = block:sub(1, remaining) .. "\n... [cached context truncated]" end
            blocks[#blocks + 1] = block
            remaining = remaining - #block
        end
    end

    if #blocks == 0 then return "" end

    local lines = {
        "Note: The following context sections are already loaded in this prompt. Use them directly; do not call load()/lookup() for the same section again unless the user asks for newer or different context.",
    }
    for _, block in ipairs(blocks) do
        lines[#lines + 1] = block
    end

    return table.concat(lines, "\n\n")
end

-- ---------------------------------------------------------------------------
-- Prompt building
-- ---------------------------------------------------------------------------

local prompt_builder = {}

local function collect_basic_context(player_name)
    local communication = get_communication()
    if communication.get_agent_context then
        return communication.get_agent_context(player_name)
    end
    return ""
end

local function collect_skill_context(player_name, options)
    local communication = get_communication()
    if communication.describe_skills_for_agent then
        return communication.describe_skills_for_agent(player_name, options and options.skill_filter)
    end
    return ""
end

function prompt_builder.build_system_prompt(player_name, options, state, deps)
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
        "When you include lua_action, visible text is only a short status for the player, not the full final answer unless the task is complete.",
        "Text outside lua_action is visible to the player. lua_action content is hidden and executed by core_executor.lua.",
        "The prompt is intentionally compact. Do not guess missing APIs, node names, server state, or skill details.",
        "When details are needed, first request focused context through llm_connect.context.load()/lookup() inside lua_action.",
        "Prefer exact context ids or glossary aliases over search. search() is a fallback only.",
        "Do not invent context ids. Only load ids or aliases shown in [ACTIVE SKILL CONTEXT], [RETRIEVED CONTEXT CACHE], or list_sections()/keys() results.",
        "After a requested context section is cached, use it; do not load narrower subkeys unless they were explicitly listed.",
        "",
        "Action block format:",
        "```lua_action",
        "-- Lua code here",
        "return { done = true, message = \"short result\" }",
        "```",
        "",
        "Lua action rules:",
        "- player_name is available in the sandbox. ALWAYS include it in skill calls.",
        "- core is available as the safe Luanti API namespace.",
        "- For direct node writes, use node tables: core.set_node(pos, {name='default:stone'}). Do not pass bare node-name strings to set_node/add_node/swap_node.",
        "- Return {done=false, continue=true, message=\"...\"} if you need to perform more steps after the current block.",
        "- Results of load()/lookup() are provided in the next turn's [RETRIEVED CONTEXT CACHE] or action history.",
        "- If context is only an intermediate step for another requested action, set done=false to receive the data and continue.",
        "- If the user's whole request is to load/check/show documentation and the context load succeeded, set done=true and stop.",
        "- ONLY set done=true when the entire task requested by the user is complete.",
        "- For imperative user requests, keep taking action until the requested task is done or a real blocker occurs.",
        "- Do not ask the player to confirm that an internal action block was processed. The runtime processes it automatically.",
        "- Do not stop after planning. If a skill call can advance the task, call it in lua_action.",
        "- For imperative requests, a lua_action that only returns done=true/message without calling a skill/core action is invalid.",
        "- Always check skill results before done=true: local res = llm_connect.skills.<id>.run(...); if res and res.ok == false then return {done=false, continue=true, message=res.message or res.error or 'Skill failed'} end.",
        "- Do not ask preference questions after the user already asked you to act freely. Choose reasonable defaults and proceed.",
        "- Never say 'next step follows after execution' or ask for confirmation between action blocks.",
        "- If a risky or destructive action needs explicit player approval, call llm_connect.agent.request_permission({kind='...', summary='...'}) in lua_action instead of asking in visible text.",
        "- Self-context API: load(key), lookup(key), keys(), has(key), list_sections(), get_section(id).",
        "- Discover context ids and aliases with llm_connect.context.keys() or list_sections() before loading optional details.",
        "- load()/lookup()/get_section() return {ok,id,title,summary,content,message}; read documentation from doc.content.",
        "- Do not expect doc.commands or doc.api fields from context.load(); use doc.content, then continue and call the documented skill API only when the user requested an action beyond loading docs.",
        "- If using search(query), remember it returns an object: {ok=true,count=n,sections={...}}, not an array or string.",
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

function prompt_builder.build_messages(player_name, user_message, state, deps)
    local messages = {
        { role = "system", content = prompt_builder.build_system_prompt(player_name, state and state.options or {}, state, deps) },
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

M.capabilities = capabilities
M.context_cache = context_cache
M.prompt_builder = prompt_builder

core.log("action", "[agent_context] loaded — prompt context, cache, and capability snapshots ready")

return M
