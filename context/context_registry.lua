-- ===========================================================================
--  context_registry.lua — LLM Connect v1.2 preparation layer
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Purpose:
--    Small Lua-native context retrieval layer for agent self-context.
--    The system prompt should stay compact. When the LLM needs details about
--    the Luanti API, active skills, server state, nodes, or project docs, it can
--    request focused sections through llm_connect.context.* from lua_action.
-- ===========================================================================

local core = core
local M = {}

M.version = "0.2.0-dev"
M.sections = M.sections or {}
M.aliases = M.aliases or {}
M.recent_context_by_player = M.recent_context_by_player or {}

local function trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize_id(id)
    id = trim(id)
    if id == "" then return nil, "missing id" end
    if not id:match("^[%w_%-%.:/]+$") then
        return nil, "invalid context section id: " .. id
    end
    return id
end

local function normalize_alias(alias)
    alias = trim(alias):lower()
    if alias == "" then return nil, "missing alias" end
    if not alias:match("^[%w_%-%.:/]+$") then
        return nil, "invalid context alias: " .. alias
    end
    return alias
end

local function has_priv(player_name, priv)
    if not priv or priv == "" then return true end
    local policy = _G.llm_connect and _G.llm_connect.policy
    if policy and policy.has_priv then return policy.has_priv(player_name, priv) end
    local privs = core.get_player_privs(player_name) or {}
    return privs[priv] == true or privs.llm_root == true
end

local function safe_call(fn, player_name, args)
    local ok, res = pcall(fn, player_name, args or {})
    if ok then return true, res end
    return false, tostring(res)
end

local function section_allowed(section, player_name)
    if not section or section.enabled == false then return false end
    return has_priv(player_name, section.required_priv or section.priv or "llm_agent")
end


local function worldedit_status_lines(player_name)
    local modpath = core.get_modpath and core.get_modpath("worldedit") or nil
    local we = rawget(_G, "worldedit")
    local lines = {}
    lines[#lines + 1] = "WorldEdit modpath: " .. tostring(modpath or "not found")
    lines[#lines + 1] = "WorldEdit global table: " .. tostring(type(we) == "table")
    if type(we) == "table" then
        lines[#lines + 1] = "WorldEdit API functions: set=" .. tostring(type(we.set) == "function")
            .. ", cube=" .. tostring(type(we.cube) == "function")
            .. ", sphere=" .. tostring(type(we.sphere) == "function")
            .. ", volume=" .. tostring(type(we.volume) == "function")
    end
    local wea = rawget(_G, "worldeditadditions")
    lines[#lines + 1] = "WorldEditAdditions modpath: " .. tostring((core.get_modpath and core.get_modpath("worldeditadditions")) or "not found")
    lines[#lines + 1] = "WorldEditAdditions global table: " .. tostring(type(wea) == "table")
    return lines
end

local function section_summary(section)
    return {
        id = section.id,
        title = section.title or section.id,
        summary = section.summary or "",
        tags = section.tags or {},
        dynamic = section.dynamic == true or type(section.provider) == "function",
    }
end

local function remember_recent_context(player_name, res)
    if type(player_name) ~= "string" or player_name == "" or type(res) ~= "table" then return res end
    local has_content = type(res.content) == "string" and res.content ~= ""
    local has_hits = type(res.sections) == "table" and #res.sections > 0
    if res.ok ~= false and (has_content or has_hits) then
        M.recent_context_by_player[player_name] = res
    end
    return res
end

function M.consume_recent_context(player_name)
    if type(player_name) ~= "string" or player_name == "" then return nil end
    local res = M.recent_context_by_player[player_name]
    M.recent_context_by_player[player_name] = nil
    return res
end

function M.register_section(def)
    if type(def) ~= "table" then return false, "section definition must be a table" end
    local id, err = normalize_id(def.id or def.name)
    if not id then return false, err end
    if type(def.content) ~= "string" and type(def.provider) ~= "function" then
        return false, "section needs string content or provider(player_name, args)"
    end

    local section = {}
    for k, v in pairs(def) do section[k] = v end
    section.id = id
    section.title = trim(section.title or id)
    section.summary = trim(section.summary or "")
    section.tags = type(section.tags) == "table" and section.tags or {}
    section.enabled = section.enabled ~= false
    section.updated_at = os.time and os.time() or 0

    M.sections[id] = section
    core.log("action", "[context_registry] section registered: " .. id)
    return true, section
end

function M.unregister_section(id)
    id = normalize_id(id)
    if not id then return false, "missing id" end
    M.sections[id] = nil
    return true
end

function M.register_alias(alias, id)
    local a, aerr = normalize_alias(alias)
    if not a then return false, aerr end
    local sid, serr = normalize_id(id)
    if not sid then return false, serr end
    M.aliases[a] = sid
    return true, sid
end

function M.register_aliases(map)
    if type(map) ~= "table" then return false, "alias map must be a table" end
    for alias, id in pairs(map) do
        M.register_alias(alias, id)
    end
    return true
end

function M.resolve_id(key)
    key = trim(key or "")
    if key == "" then return nil, "missing context key" end
    if M.sections[key] then return key, nil, "section" end
    local alias = key:lower()
    if M.aliases[alias] then return M.aliases[alias], nil, "alias" end
    return nil, "unknown context key or alias: " .. key
end

function M.has(player_name, key)
    local id = M.resolve_id(key)
    local section = id and M.sections[id] or nil
    return remember_recent_context(player_name, {
        ok = section ~= nil and section_allowed(section, player_name),
        key = tostring(key or ""),
        id = id,
        message = section and ("Context key exists: " .. tostring(id)) or ("Context key missing: " .. tostring(key or "")),
    })
end

function M.keys(player_name, opts)
    opts = opts or {}
    local sections = M.list_sections(player_name, opts).sections or {}
    local aliases = {}
    for alias, id in pairs(M.aliases) do
        local section = M.sections[id]
        if section_allowed(section, player_name) then
            aliases[#aliases + 1] = { alias = alias, id = id }
        end
    end
    table.sort(aliases, function(a, b) return a.alias < b.alias end)
    return remember_recent_context(player_name, {
        ok = true,
        count = #sections,
        sections = sections,
        aliases = aliases,
        message = "Context keys available: " .. tostring(#sections) .. " sections, " .. tostring(#aliases) .. " aliases",
    })
end

function M.lookup(player_name, key, args)
    local id, err, kind = M.resolve_id(key)
    if not id then
        return { ok = false, key = tostring(key or ""), message = err }
    end
    local res = M.get_section(player_name, id, args or {})
    res.key = tostring(key or "")
    res.resolved_id = id
    res.resolved_by = kind
    return res
end

-- Friendly alias for agents: load accepts exact ids and glossary aliases.
function M.load(player_name, key, args)
    return M.lookup(player_name, key, args or {})
end

function M.search_first(player_name, query, opts)
    local res = M.search(player_name, query, opts or {})
    local first = res.sections and res.sections[1]
    if not first or not first.id then
        return { ok = false, query = tostring(query or ""), message = "No context search hit" }
    end
    local loaded = M.get_section(player_name, first.id, opts and opts.args or {})
    loaded.query = tostring(query or "")
    loaded.search_score = first.score
    loaded.resolved_id = first.id
    loaded.resolved_by = "search_first"
    return loaded
end

function M.list_sections(player_name, opts)
    opts = opts or {}
    local out = {}
    local query = trim(opts.query or opts.q or ""):lower()

    for id, section in pairs(M.sections) do
        if section_allowed(section, player_name) then
            local hay = (id .. " " .. tostring(section.title or "") .. " " .. tostring(section.summary or "") .. " " .. table.concat(section.tags or {}, " ")):lower()
            if query == "" or hay:find(query, 1, true) then
                out[#out + 1] = section_summary(section)
            end
        end
    end

    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return remember_recent_context(player_name, {
        ok = true,
        count = #out,
        sections = out,
        message = (#out == 0) and "No context sections matched" or ("Available context sections: " .. tostring(#out)),
    })
end

function M.get_section(player_name, id, args)
    id = tostring(id or "")
    local section = M.sections[id]
    if not section then
        return { ok = false, message = "unknown context section: " .. id }
    end
    if not section_allowed(section, player_name) then
        return { ok = false, message = "context section not available or privilege missing: " .. id }
    end

    local content
    if type(section.provider) == "function" then
        local ok, res = safe_call(section.provider, player_name, args or {})
        if not ok then
            return { ok = false, id = id, message = "context provider failed: " .. tostring(res) }
        end
        content = tostring(res or "")
    else
        content = tostring(section.content or "")
    end

    return remember_recent_context(player_name, {
        ok = true,
        id = id,
        title = section.title or id,
        summary = section.summary or "",
        content = content,
        message = "Context section loaded: " .. id,
    })
end

local function score_text(hay, terms)
    local score = 0
    hay = hay:lower()
    for _, term in ipairs(terms) do
        if term ~= "" and hay:find(term, 1, true) then score = score + 1 end
    end
    return score
end

function M.search(player_name, query, opts)
    opts = opts or {}
    query = trim(query or opts.query or opts.q or "")
    if query == "" then return M.list_sections(player_name, opts) end

    local terms = {}
    for word in query:lower():gmatch("[%w_:%-%.]+") do terms[#terms + 1] = word end

    local hits = {}
    for id, section in pairs(M.sections) do
        if section_allowed(section, player_name) then
            local hay = id .. " " .. tostring(section.title or "") .. " " .. tostring(section.summary or "") .. " " .. table.concat(section.tags or {}, " ")
            local score = score_text(hay, terms)
            if score > 0 then
                local item = section_summary(section)
                item.score = score
                hits[#hits + 1] = item
            end
        end
    end

    table.sort(hits, function(a, b)
        if a.score == b.score then return tostring(a.id) < tostring(b.id) end
        return a.score > b.score
    end)

    local limit = tonumber(opts.limit or 12) or 12
    while #hits > limit do table.remove(hits) end

    return remember_recent_context(player_name, {
        ok = true,
        query = query,
        count = #hits,
        sections = hits,
        message = (#hits == 0) and "No context sections matched" or ("Context search hits: " .. tostring(#hits)),
    })
end

function M.make_sandbox_proxy(player_name)
    local function as_context_step(res)
        if type(res) == "table" then
            local has_content = type(res.content) == "string" and res.content ~= ""
            local has_hits = type(res.sections) == "table" and #res.sections > 0
            -- Context loading is an intermediate step only when it actually
            -- returns usable content/hits. Failed lookups and empty searches
            -- should not burn agent iterations.
            if res.ok ~= false and (has_content or has_hits) then
                res.done = false
                res.continue = true
            else
                res.done = true
                res.continue = false
            end
            if not res.message or res.message == "" then
                res.message = "Context lookup completed"
            end
        end
        return res
    end

    return {
        keys = function(opts)
            return as_context_step(M.keys(player_name, opts or {}))
        end,
        aliases = function(opts)
            return as_context_step(M.keys(player_name, opts or {}))
        end,
        has = function(key)
            return as_context_step(M.has(player_name, key))
        end,
        lookup = function(key, args)
            return as_context_step(M.lookup(player_name, key, args or {}))
        end,
        load = function(key, args)
            return as_context_step(M.load(player_name, key, args or {}))
        end,
        list_sections = function(opts)
            return as_context_step(M.list_sections(player_name, opts or {}))
        end,
        search = function(query, opts)
            return as_context_step(M.search(player_name, query, opts or {}))
        end,
        search_first = function(query, opts)
            return as_context_step(M.search_first(player_name, query, opts or {}))
        end,
        get_section = function(id, args)
            return as_context_step(M.get_section(player_name, id, args or {}))
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Built-in dynamic sections. These are intentionally compact bootstrap docs;
-- detailed skill documentation is registered by each skill.
-- ---------------------------------------------------------------------------

local function register_builtin_sections()
    M.register_section({
        id = "agent.context_api",
        title = "Agent self-context API",
        summary = "How to discover and request focused context from lua_action.",
        tags = {"agent", "context", "bootstrap", "self-context"},
        required_priv = "llm_agent",
        content = table.concat({
            "Use llm_connect.context when you need details that are not in the compact system prompt.",
            "Available calls inside lua_action:",
            "  local keys = llm_connect.context.keys() -- sections plus glossary aliases",
            "  local list = llm_connect.context.list_sections() -- available section ids",
            "  local doc = llm_connect.context.load('<alias-or-section-id>')",
            "  local hits = llm_connect.context.search('<query>') -- fallback only; returns {ok,count,sections={...}}",
            "load()/lookup()/get_section() return {ok,id,title,summary,content,message}. Read docs from doc.content.",
            "Do not test doc.commands or doc.api after context.load(); those fields are not part of the context result.",
            "Prefer load()/lookup() with exact ids or glossary aliases. Use search() only if no alias/id is known.",
            "Return the loaded context table directly, or return {done=false, continue=true, message='Loaded context: ...'} before acting.",
            "Do not guess complex APIs, server state, node names, or skill arguments when a context section can be requested first.",
        }, "\n"),
    })

    M.register_section({
        id = "server.info",
        title = "Current server and player state",
        summary = "Engine, game, player position, wielded item, and online players.",
        tags = {"server", "player", "state", "position"},
        required_priv = "llm_agent",
        dynamic = true,
        provider = function(player_name)
            local version = core.get_version()
            local gameinfo = core.get_game_info()
            local lines = {}
            lines[#lines + 1] = "Engine: " .. tostring(version.project or "Luanti") .. " " .. tostring(version.string or "")
            lines[#lines + 1] = "Game: " .. tostring(gameinfo.name or gameinfo.id or "unknown")
            lines[#lines + 1] = "World path: " .. tostring(core.get_worldpath())
            for _, line in ipairs(worldedit_status_lines(player_name)) do lines[#lines + 1] = line end
            local player = core.get_player_by_name(player_name)
            if player then
                local pos = player:get_pos()
                lines[#lines + 1] = string.format("Player: %s @ (%.1f, %.1f, %.1f), hp=%d, breath=%d", player_name, pos.x, pos.y, pos.z, player:get_hp(), player:get_breath())
                lines[#lines + 1] = "Holding: " .. tostring(player:get_wielded_item():get_name())
            end
            local names = {}
            for _, p in ipairs(core.get_connected_players()) do names[#names + 1] = p:get_player_name() end
            table.sort(names)
            lines[#lines + 1] = "Players online: " .. table.concat(names, ", ")
            return table.concat(lines, "\n")
        end,
    })

    M.register_section({
        id = "luanti.safe_core",
        title = "Safe core API available in agent sandbox",
        summary = "Compact list of core.* functions exposed by core_executor sandbox.",
        tags = {"luanti", "api", "core", "sandbox"},
        required_priv = "llm_agent",
        content = table.concat({
            "The agent sandbox exposes a safe subset as core.* and minetest.* alias.",
            "Common reads: core.get_node, get_node_or_nil, get_meta, get_node_timer, find_node_near, find_nodes_in_area.",
            "Common writes: core.set_node, swap_node, remove_node, add_node.",
            "Players/objects: core.get_player_by_name, get_connected_players, get_objects_inside_radius.",
            "Helpers: core.pos_to_string, string_to_pos, serialize, deserialize, after, sound_play, show_formspec.",
            "Time changes are not exposed as core.set_time in the safe runtime. If command_agent is active, use llm_connect.skills.command_agent.set_time({time=18000}, player_name).",
            "Runtime registrations are blocked: register_node/tool/craftitem/entity/craft.",
            "Host access is blocked: io, require, dofile, loadfile, load, loadstring, debug, package.",
        }, "\n"),
    })

    M.register_section({
        id = "mods.worldedit.status",
        title = "WorldEdit installation and API status",
        summary = "Detects whether WorldEdit is installed, loaded, and available as a Lua API table.",
        tags = {"worldedit", "mod", "status", "skill", "building"},
        required_priv = "llm_agent",
        dynamic = true,
        provider = function(player_name)
            local lines = worldedit_status_lines(player_name)
            local player = core.get_player_by_name(player_name)
            if player then
                local p = player:get_pos()
                lines[#lines + 1] = string.format("Current player position: (%.1f, %.1f, %.1f)", p.x, p.y, p.z)
            end
            lines[#lines + 1] = "Interpretation: modpath found means installed. A global worldedit table with functions means callable Lua API."
            return table.concat(lines, "\n")
        end,
    })

    M.register_section({
        id = "luanti.registered_nodes.preview",
        title = "Registered node preview",
        summary = "Searchable preview of registered node names by mod prefix.",
        tags = {"luanti", "nodes", "materials", "registry"},
        required_priv = "llm_agent",
        dynamic = true,
        provider = function(_, args)
            args = args or {}
            local query = trim(args.query or args.q or ""):lower()
            local limit = tonumber(args.limit or 80) or 80
            local names = {}
            for name in pairs(core.registered_nodes or {}) do
                if name ~= "air" and name ~= "ignore" then
                    if query == "" or name:lower():find(query, 1, true) then
                        names[#names + 1] = name
                    end
                end
            end
            table.sort(names)
            local out = {}
            for i = 1, math.min(#names, limit) do out[#out + 1] = names[i] end
            if #names > #out then out[#out + 1] = "... " .. tostring(#names - #out) .. " more" end
            return "Registered node names" .. (query ~= "" and (" matching '" .. query .. "'") or "") .. ":\n" .. table.concat(out, "\n")
        end,
    })
end

M.register_aliases({
    api = "luanti.safe_core",
    core = "luanti.safe_core",
    safe_core = "luanti.safe_core",
    server = "server.info",
    player = "server.info",
    position = "server.info",
    nodes = "luanti.registered_nodes.preview",
    node_registry = "luanti.registered_nodes.preview",
    materials = "luanti.registered_nodes.preview",
})

register_builtin_sections()

core.log("action", "[context_registry] module loaded — agent self-context layer ready")

return M
