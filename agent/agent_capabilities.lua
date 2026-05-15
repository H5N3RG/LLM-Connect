-- ===========================================================================
--  agent_capabilities.lua — active skill/capability snapshots
-- ===========================================================================

local M = {}

local function get_skills()
    local root = rawget(_G, "llm_connect")
    return type(root) == "table" and (root.skills or root.skills_subsystem or root.registry) or rawget(_G, "registry")
end

local function get_api()
    local root = rawget(_G, "llm_connect")
    return type(root) == "table" and (root.api or root.llm_api) or rawget(_G, "llm_api")
end

local function safe_call(fn, ...)
    if type(fn) ~= "function" then return false, nil end
    return pcall(fn, ...)
end

function M.snapshot(player_name, options)
    local skills = get_skills()
    local snapshot = {
        player_name = tostring(player_name or ""),
        active_skill_count = 0,
        skills = {},
        provider = nil,
        fingerprint = "no-registry",
    }

    if not skills then return snapshot end

    local ok, status = safe_call(skills.get_status, player_name)
    if ok and type(status) == "table" then
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

    local api = get_api()
    if api and type(api.get_provider) == "function" then
        local ok_provider, provider = pcall(api.get_provider)
        if ok_provider then snapshot.provider = provider end
    end

    return snapshot
end

function M.active_skill_count(player_name)
    return M.snapshot(player_name).active_skill_count or 0
end

function M.changed(old_snapshot, new_snapshot)
    if not old_snapshot or not new_snapshot then return false end
    return tostring(old_snapshot.fingerprint or "") ~= tostring(new_snapshot.fingerprint or "")
end

return M
