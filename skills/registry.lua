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
M.loaded_skill_gateways = M.loaded_skill_gateways or {}
M.external_skill_report = M.external_skill_report or {
    discovered = 0,
    valid = 0,
    invalid = 0,
    skills = {},
    errors = {},
}

local function trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function now()
    return os.time and os.time() or 0
end

local function has_priv(player_name, priv)
    if not priv or priv == "" then return true end
    if not player_name or player_name == "" then return false end
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

local function normalize_origin(origin)
    origin = trim(origin or "internal")
    if origin == "extern" then origin = "external" end
    if origin == "" then origin = "internal" end
    if origin ~= "internal" and origin ~= "external" then
        return nil, "invalid origin: " .. tostring(origin)
    end
    return origin
end

local function mounted_skill_namespace()
    local root = rawget(_G, "llm_connect")
    if type(root) ~= "table" then
        root = {}
        rawset(_G, "llm_connect", root)
    end
    if type(root.skills) ~= "table" then root.skills = {} end
    return root.skills
end

local function validate_skill_api(id, api, required)
    if api == nil then
        if required then return false, "external skill requires api table" end
        return true
    end
    if type(api) ~= "table" then
        return false, "skill api for " .. tostring(id) .. " must be a table"
    end
    if type(api.run) ~= "function" then
        return false, "skill api for " .. tostring(id) .. " requires run(tool_name, args, player_name)"
    end
    return true
end

local function collision_error(id, existing, skill)
    if not existing then return nil end

    local existing_origin = existing.origin or "internal"
    local new_origin = skill.origin or "internal"
    if existing_origin == "extern" then existing_origin = "external" end
    if new_origin == "extern" then new_origin = "external" end

    if existing_origin == "internal" and new_origin == "external" then
        return "external skill '" .. id .. "' cannot overwrite internal skill id"
    end
    if existing_origin == "external" and new_origin == "internal" then
        return "internal skill '" .. id .. "' cannot overwrite external provider skill"
    end
    if existing_origin == "external" and new_origin == "external" then
        local existing_provider = trim(existing.provider_mod or "")
        local new_provider = trim(skill.provider_mod or "")
        if existing_provider ~= new_provider then
            return "external skill '" .. id .. "' already registered by provider_mod '" .. existing_provider .. "'"
        end
    end
    return nil
end

local function mount_skill_api(id, api)
    if api == nil then return true end
    mounted_skill_namespace()[id] = api
    return true
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

    local origin, origin_err = normalize_origin(def.origin)
    if not origin then return false, origin_err end
    local provider_mod = trim(def.provider_mod or "")
    if origin == "external" and provider_mod == "" then
        return false, "external skill requires provider_mod"
    end

    local api_ok, api_err = validate_skill_api(id, def.api, origin == "external")
    if not api_ok then return false, api_err end

    local existed = M.skills[id] ~= nil

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
    skill.origin = origin
    if provider_mod ~= "" then skill.provider_mod = provider_mod end
    skill.provider_version = trim(skill.provider_version or "")
    if skill.provider_version == "" then skill.provider_version = nil end
    skill.source = trim(skill.source or "")
    if skill.source == "" then skill.source = nil end
    skill.homepage = trim(skill.homepage or "")
    if skill.homepage == "" then skill.homepage = nil end
    skill.category = skill.category or "skill"

    local collision = collision_error(id, M.skills[id], skill)
    if collision then return false, collision end

    mount_skill_api(id, skill.api)
    M.skills[id] = skill
    if type(M.current_skill_load) == "table" then
        local load = M.current_skill_load
        load.registered_ids = load.registered_ids or {}
        load.registered_ids[#load.registered_ids + 1] = id
        if existed then
            load.refreshed_ids = load.refreshed_ids or {}
            load.refreshed_ids[#load.refreshed_ids + 1] = id
        else
            load.new_ids = load.new_ids or {}
            load.new_ids[#load.new_ids + 1] = id
        end
    end
    core.log("action", "[registry] Lua-first skill registered: " .. id .. " (" .. skill.origin .. ")")
    return true, skill
end

function M.unregister_skill(id)
    id = normalize_id(id)
    if not id then return false, "missing id" end
    local skill = M.skills[id]
    if not skill then return false, "unknown skill: " .. id end
    M.skills[id] = nil
    if skill.origin == "external" then
        local runtime = mounted_skill_namespace()
        if runtime[id] == skill.api then runtime[id] = nil end
    end
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
            local attached = M.is_skill_attached(player_name, id)
            if attached and has_priv(player_name, required) then out[#out + 1] = skill end
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
        "Active Lua-first skills are invoked only through llm_connect.skills.<skill_id>.run(\"<tool_name>\", args, player_name).",
        "Do not call tool helpers directly as functions or with :run(). The .run(\"tool\", args, player_name) form is the only agent-facing protocol.",
        "In visible chat, use each skill's display name. Treat skill_id values as code namespaces only.",
        "Detailed manuals are intentionally not injected. Use llm_connect.context.load(context_section) before complex skill calls.",
        "Context loads return documentation in the content field, not parsed API tables.",
    }
    for _, skill in ipairs(skills) do
        local display = skill.label or skill.display_name or skill.name or skill.id
        lines[#lines + 1] = string.format("- %s v%s: %s", tostring(display), tostring(skill.version or "?"), tostring(skill.description or ""))
        lines[#lines + 1] = "  Code namespace: llm_connect.skills." .. tostring(skill.id)
        lines[#lines + 1] = "  Invocation: llm_connect.skills." .. tostring(skill.id) .. ".run(\"<tool_name>\", args, player_name)"
        local ctx_id = skill.context_section or ("skills." .. tostring(skill.id))
        lines[#lines + 1] = "  Context section: " .. ctx_id
        if type(skill.context_aliases) == "table" and #skill.context_aliases > 0 then
            lines[#lines + 1] = "  Context aliases: " .. table.concat(skill.context_aliases, ", ") .. " (also accepted as skills.<alias>)"
        end
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

local function get_player_override(player_name, id)
    local player = M.player_skill_overrides and M.player_skill_overrides[player_name]
    if player and player[id] ~= nil then return player[id] == true end
    return nil
end

function M.is_skill_attached(player_name, id)
    local override = get_player_override(player_name, id)
    if override ~= nil then return override end
    return skill_default_enabled(M.skills[id])
end

function M.has_player_override(player_name, id)
    return get_player_override(player_name, id) ~= nil
end

function M.is_addon_enabled(player_name, id)
    -- Kept for main_gui compatibility; this now means "skill attached".
    if not M.skills[id] then return false end
    return M.is_skill_attached(player_name, id)
end

function M.set_player_addon(player_name, id, enabled)
    -- Kept for main_gui compatibility; this now toggles Lua-first skills only.
    if not player_name or player_name == "" then return false, "missing player" end
    if not M.skills[id] then return false, "unknown skill: " .. tostring(id) end
    M.player_skill_overrides[player_name] = M.player_skill_overrides[player_name] or {}
    M.player_skill_overrides[player_name][id] = enabled == true
    return true
end

function M.attach_skill_to_player(target_name, id, enabled)
    -- Root-facing explicit attach/detach primitive. This intentionally avoids
    -- the old addon/traffic-light wording: a skill is either attached to the
    -- target's agent session or it is not.
    return M.set_player_addon(target_name, id, enabled ~= false)
end

function M.detach_skill_from_player(target_name, id)
    return M.set_player_addon(target_name, id, false)
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
        local manual = M.has_player_override(player_name, id)
        local manually_attached = manual and enabled
        out[#out + 1] = {
            id = id,
            label = skill.label or skill.name or id,
            description = skill.description or "Lua-first skill",
            available = available,
            has_priv = has,
            enabled = enabled,
            attached = enabled,
            manual = manual,
            manual_attached = manually_attached,
            default_enabled = skill.default_enabled == true,
            effective = available and enabled and has,
            tool_count = skill.tool_count or (type(skill.api) == "table" and #skill.api or 0),
            required_priv = required,
            version = skill.version or "0.1.0",
            origin = skill.origin or "internal",
            provider_mod = skill.provider_mod,
            provider_version = skill.provider_version,
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

local function list_skill_dirs(base)
    local dirs = {}
    if core.get_dir_list then
        local ok, found = pcall(core.get_dir_list, base, true)
        if ok and type(found) == "table" then
            for _, name in ipairs(found) do
                if type(name) == "string" and name ~= "" and name:sub(1, 1) ~= "." then
                    dirs[#dirs + 1] = name
                end
            end
        end
    end
    table.sort(dirs)
    return dirs
end

local function load_skill_gateway(spec, results)
    local path = spec.path
    if not file_exists(path) then
        local msg = "skill gateway missing: " .. spec.rel
        results[spec.name] = { ok = false, error = msg, path = path }
        core.log("warning", "[registry] " .. msg)
        return false
    end

    local old_loading = M.current_skill_load
    M.current_skill_load = {
        name = spec.name,
        dir = spec.dir,
        path = path,
        rel = spec.rel,
        registered_ids = {},
        new_ids = {},
        refreshed_ids = {},
    }
    local ok, err = pcall(dofile, path)
    local load = M.current_skill_load
    M.current_skill_load = old_loading

    if not ok then
        local msg = "failed to load skill gateway " .. spec.rel .. ": " .. tostring(err)
        results[spec.name] = { ok = false, error = msg, path = path }
        health_mark("degraded", spec.name, msg)
        core.log("warning", "[registry] " .. msg)
        return false
    end

    local registered = load and load.registered_ids or {}
    local new_ids = load and load.new_ids or {}
    local refreshed = load and load.refreshed_ids or {}
    table.sort(registered)
    table.sort(new_ids)
    table.sort(refreshed)

    if #registered == 0 then
        local msg = "skill gateway loaded but registered no skill: " .. spec.rel
        results[spec.name] = { ok = false, error = msg, path = path }
        health_mark("degraded", spec.name, msg)
        core.log("warning", "[registry] " .. msg)
        return false
    end

    for _, id in ipairs(registered) do
        health_mark("ok", id, "loaded")
    end
    M.loaded_skill_gateways[spec.name] = spec
    local state = (#new_ids > 0) and "loaded" or "refreshed"
    results[spec.name] = {
        ok = true,
        state = state,
        path = path,
        registered = registered,
        new = new_ids,
        refreshed = refreshed,
    }
    core.log("action", "[registry] " .. state .. " Lua-first skill gateway: " .. spec.rel .. " -> " .. table.concat(registered, ", "))
    return true, state
end

function M.load_internal()
    local modpath = core.get_modpath(core.get_current_modname())
    local base = modpath .. "/skills"
    local loaded = 0
    local refreshed = 0
    local failed = 0
    local results = {}

    local skill_dirs = list_skill_dirs(base)
    if #skill_dirs == 0 then
        core.log("warning", "[registry] no skill gateways discovered under skills/*/init.lua")
    end

    for _, name in ipairs(skill_dirs) do
        local spec = {
            name = name,
            dir = base .. "/" .. name,
            rel = "skills/" .. name .. "/init.lua",
            path = base .. "/" .. name .. "/init.lua",
        }
        local ok, state = load_skill_gateway(spec, results)
        if ok then
            if state == "refreshed" then refreshed = refreshed + 1
            else loaded = loaded + 1 end
        else
            failed = failed + 1
        end
    end

    M.internal_skill_load = { loaded = loaded, refreshed = refreshed, failed = failed, results = results }
    return loaded, M.internal_skill_load
end

function M.discover_external()
    local report = {
        discovered = 0,
        valid = 0,
        invalid = 0,
        skills = {},
        errors = {},
    }
    local runtime = mounted_skill_namespace()

    for id, skill in pairs(M.skills) do
        if skill and skill.origin == "external" then
            report.discovered = report.discovered + 1
            local item = {
                id = id,
                origin = skill.origin,
                provider_mod = skill.provider_mod,
                provider_version = skill.provider_version,
                version = skill.version,
                ok = true,
            }
            local errors = {}
            if trim(skill.provider_mod or "") == "" then
                errors[#errors + 1] = "missing provider_mod"
            end
            if type(runtime[id]) ~= "table" then
                errors[#errors + 1] = "runtime api not mounted"
            elseif type(runtime[id].run) ~= "function" then
                errors[#errors + 1] = "runtime api missing run"
            end

            if #errors > 0 then
                item.ok = false
                item.errors = errors
                report.invalid = report.invalid + 1
                for _, msg in ipairs(errors) do
                    report.errors[#report.errors + 1] = { id = id, error = msg }
                end
            else
                report.valid = report.valid + 1
            end
            report.skills[#report.skills + 1] = item
        end
    end

    table.sort(report.skills, function(a, b) return tostring(a.id) < tostring(b.id) end)
    table.sort(report.errors, function(a, b)
        if tostring(a.id) == tostring(b.id) then return tostring(a.error) < tostring(b.error) end
        return tostring(a.id) < tostring(b.id)
    end)

    M.external_skill_report = report
    core.log("action", "[registry] external skill validation report: discovered="
        .. tostring(report.discovered)
        .. " valid=" .. tostring(report.valid)
        .. " invalid=" .. tostring(report.invalid))
    return report
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
