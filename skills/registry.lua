-- ===========================================================================
--  registry.lua — LLM Connect v1.2.0-dev Lua-first Skill Registry
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  HARD CUT FROM 1.0.0-dev:
--    - Lua-first skill registration and per-player skill toggles.
--    - registry.register(old_addon_manifest) is deprecated and rejected.
--
--  ROLE NOW:
--    - Hold Lua-first skills and runtime context providers.
--    - Provide prompt/context text to agent_runtime.lua.
--    - Expose a small stable API under llm_connect.registry.
-- ===========================================================================

local core = core
local M = {}

M.version = "1.2.0-dev"
M.protocol = "lua-first"
M.skills = M.skills or {}
M.context_providers = M.context_providers or {}

local function trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function now()
    return os.time and os.time() or 0
end

local function has_priv(player_name, priv)
    if not priv or priv == "" then return true end
    local policy = _G.llm_connect and _G.llm_connect.policy
    if policy and policy.has_priv then return policy.has_priv(player_name, priv) end
    local privs = core.get_player_privs(player_name) or {}
    return privs[priv] == true or privs.llm_root == true
end

local function normalize_id(id)
    id = trim(id)
    if id == "" then return nil, "missing id" end
    if not id:match("^[%w_%-%.:]+$") then
        return nil, "invalid id: " .. id
    end
    return id
end

local function shallow_copy(t)
    local out = {}
    for k, v in pairs(t or {}) do out[k] = v end
    return out
end

local function is_skill_available(skill)
    if not skill or skill.enabled == false then return false end
    if type(skill.available) == "function" then
        local ok, res = pcall(skill.available)
        if not ok then
            core.log("warning", "[registry] skill availability check failed for " .. tostring(skill.id) .. ": " .. tostring(res))
            return false
        end
        return res ~= false and res ~= nil
    end
    return skill.available ~= false
end

function M.register_skill(def)
    if type(def) ~= "table" then return false, "skill definition must be a table" end
    local id, err = normalize_id(def.id or def.name)
    if not id then return false, err end

    local skill = shallow_copy(def)
    skill.id = id
    skill.type = skill.type or "lua_skill"
    skill.version = skill.version or "0.1.0"
    skill.description = trim(skill.description or skill.summary or "")
    skill.permissions = skill.permissions or {}
    skill.created_at = skill.created_at or now()
    skill.updated_at = now()
    -- enabled/available = globally loadable; default_enabled = per-player default toggle.
    -- Safety default: skills are loaded and visible, but OFF until explicitly enabled.
    skill.enabled = skill.enabled ~= false
    if skill.available == nil then skill.available = true end
    skill.default_enabled = skill.default_enabled == true
    skill.origin = skill.origin or "internal"
    skill.category = skill.category or "skill"

    M.skills[id] = skill
    core.log("action", "[registry] Lua-first skill registered: " .. id)
    return true, skill
end

function M.unregister_skill(id)
    id = normalize_id(id)
    if not id then return false, "missing id" end
    if not M.skills[id] then return false, "unknown skill: " .. id end
    M.skills[id] = nil
    return true
end

function M.get_skill(id)
    return M.skills[id]
end

function M.list_skills(player_name, filter)
    -- Active skills only. The GUI uses get_status() to list all loaded skills.
    local out = {}
    local allowed = {}
    if type(filter) == "table" then
        for _, id in ipairs(filter) do allowed[tostring(id)] = true end
    end

    for id, skill in pairs(M.skills) do
        if is_skill_available(skill) and (not filter or allowed[id]) then
            local required = skill.required_priv or skill.priv or "llm_agent"
            local player = M.player_skill_overrides and M.player_skill_overrides[player_name]
            local active
            if player and player[id] ~= nil then
                active = player[id] == true
            else
                active = skill.default_enabled == true
            end
            if active and has_priv(player_name, required) then out[#out + 1] = skill end
        end
    end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end

function M.register_context_provider(id, fn, meta)
    local norm, err = normalize_id(id)
    if not norm then return false, err end
    if type(fn) ~= "function" then return false, "context provider must be a function" end
    M.context_providers[norm] = {
        id = norm,
        fn = fn,
        meta = meta or {},
        enabled = not (meta and meta.enabled == false),
        created_at = now(),
    }
    core.log("action", "[registry] context provider registered: " .. norm)
    return true
end

function M.get_contexts(player_name, filter)
    local parts = {}
    local allowed = {}
    if type(filter) == "table" then
        for _, id in ipairs(filter) do allowed[tostring(id)] = true end
    end

    for id, provider in pairs(M.context_providers) do
        if provider.enabled ~= false and (not filter or allowed[id]) then
            local required = provider.meta and (provider.meta.required_priv or provider.meta.priv)
            if has_priv(player_name, required or "llm_agent") then
                local ok, text = pcall(provider.fn, player_name)
                if ok and text and text ~= "" then
                    parts[#parts + 1] = "[context:" .. id .. "]\n" .. tostring(text)
                elseif not ok then
                    core.log("warning", "[registry] context provider failed: " .. id .. " — " .. tostring(text))
                end
            end
        end
    end

    for _, skill in ipairs(M.list_skills(player_name, filter)) do
        if type(skill.get_context) == "function" then
            local ok, text = pcall(skill.get_context, player_name)
            if ok and text and text ~= "" then
                parts[#parts + 1] = "[skill-context:" .. skill.id .. "]\n" .. tostring(text)
            elseif not ok then
                core.log("warning", "[registry] skill context failed: " .. skill.id .. " — " .. tostring(text))
            end
        elseif type(skill.context) == "string" and skill.context ~= "" then
            parts[#parts + 1] = "[skill-context:" .. skill.id .. "]\n" .. skill.context
        end
    end

    return table.concat(parts, "\n\n")
end

function M.describe_for_agent(player_name, filter)
    local skills = M.list_skills(player_name, filter)
    if #skills == 0 then return "" end
    local lines = {
        "Active Lua-first skills are available through llm_connect.skills.<skill_id>.",
        "Detailed manuals are intentionally not injected. Use llm_connect.context.search(...) or get_section(...) before complex skill calls.",
    }
    for _, skill in ipairs(skills) do
        lines[#lines + 1] = string.format("- %s v%s: %s", tostring(skill.id), tostring(skill.version or "?"), tostring(skill.description or ""))
        local ctx_id = skill.context_section or ("skills." .. tostring(skill.id))
        lines[#lines + 1] = "  Context section: " .. ctx_id
    end
    return table.concat(lines, "\n")
end


-- ---------------------------------------------------------------------------
-- GUI compatibility helpers for the existing Skills panel
-- ---------------------------------------------------------------------------

M.player_skill_overrides = M.player_skill_overrides or {}

local function skill_default_enabled(skill)
    if not is_skill_available(skill) then return false end
    return skill.default_enabled == true
end

function M.is_addon_enabled(player_name, id)
    -- Kept for main_gui compatibility; this now means "skill enabled".
    local skill = M.skills[id]
    if not skill then return false end
    local player = M.player_skill_overrides[player_name]
    if player and player[id] ~= nil then return player[id] == true end
    return skill_default_enabled(skill)
end

function M.set_player_addon(player_name, id, enabled)
    -- Kept for main_gui compatibility; this now toggles Lua-first skills only.
    M.player_skill_overrides[player_name] = M.player_skill_overrides[player_name] or {}
    M.player_skill_overrides[player_name][id] = enabled == true
    return true
end

function M.reset_player_addons(player_name)
    M.player_skill_overrides[player_name] = nil
    return true
end

function M.get_status(player_name)
    local out = {}
    for id, skill in pairs(M.skills) do
        local required = skill.required_priv or skill.priv or "llm_agent"
        local available = is_skill_available(skill)
        local has = has_priv(player_name, required)
        local enabled = M.is_addon_enabled(player_name, id)
        out[#out + 1] = {
            id = id,
            label = skill.label or skill.name or id,
            description = skill.description or "Lua-first skill",
            available = available,
            has_priv = has,
            enabled = enabled,
            default_enabled = skill.default_enabled == true,
            effective = available and has and enabled,
            tool_count = skill.tool_count or (type(skill.api) == "table" and #skill.api or 0),
            required_priv = required,
            version = skill.version or "0.1.0",
            origin = skill.origin or "internal",
            category = skill.category or "skill",
        }
    end
    table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
    return out
end

-- ---------------------------------------------------------------------------
-- Deprecated 1.0.0-dev addon API surface
-- ---------------------------------------------------------------------------

function M.register(def)
    local id = type(def) == "table" and (def.id or def.name) or "(unknown)"
    core.log("warning", "[registry] rejected old-style addon registration '" .. tostring(id) .. "' — use register_skill()")
    return false, "old-style addon API removed; use register_skill()"
end

local function health_mark(kind, name, message)
    local root = rawget(_G, "llm_connect")
    local health = root and root.health
    local key = "skills." .. tostring(name)
    if health then
        if kind == "ok" and type(health.mark_ok) == "function" then
            health.mark_ok(key, { message = message or "loaded" })
        elseif type(health.mark_degraded) == "function" then
            health.mark_degraded(key, message or "degraded")
        end
    end
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

function M.load_internal()
    local modpath = core.get_modpath(core.get_current_modname())
    local files = {
        { id = "command_agent", rel = "skills/command_agent/command_agent.lua" },
        { id = "worldedit_agent", rel = "skills/worldedit_agent/worldedit_agent.lua" },
    }
    local loaded = 0
    local failed = 0
    local results = {}

    for _, spec in ipairs(files) do
        local path = modpath .. "/" .. spec.rel
        if not file_exists(path) then
            local msg = "internal skill file missing: " .. spec.rel
            failed = failed + 1
            results[spec.id] = { ok = false, error = msg, path = path }
            health_mark("degraded", spec.id, msg)
            core.log("warning", "[registry] " .. msg)
        else
            local ok, err = pcall(dofile, path)
            if ok then
                loaded = loaded + 1
                results[spec.id] = { ok = true, path = path }
                health_mark("ok", spec.id, "loaded")
                core.log("action", "[registry] loaded Lua-first internal skill file: " .. spec.rel)
            else
                local msg = "failed to load Lua-first internal skill file " .. spec.rel .. ": " .. tostring(err)
                failed = failed + 1
                results[spec.id] = { ok = false, error = msg, path = path }
                health_mark("degraded", spec.id, msg)
                core.log("warning", "[registry] " .. msg)
            end
        end
    end

    M.internal_skill_load = { loaded = loaded, failed = failed, results = results }
    return loaded, M.internal_skill_load
end

function M.discover_external()
    core.log("action", "[registry] external skill discovery skipped — Lua-first skills must register explicitly")
    return 0
end


function M.expose_global()
    local root = rawget(_G, "llm_connect")
    if type(root) ~= "table" then
        root = {}
        rawset(_G, "llm_connect", root)
    end
    root.registry = M
    core.log("action", "[registry] Lua-first registry exposed as llm_connect.registry")
end

core.log("action", "[registry] module loaded — Lua-first skill registry")

return M
