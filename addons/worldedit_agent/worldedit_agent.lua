-- ===========================================================================
--  addons/worldedit_agent/worldedit_agent.lua — LLM Connect 1.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  WorldEdit addon for the LLM Connect agent system.
--  Ported from llm_worldedit.lua (0.9.0) to the 1.0 addon interface.
--
--  Changes vs 0.9.0:
--    - Agent loop logic removed (now in agent.lua)
--    - Snapshot/undo delegated to agent.lua via snapshot_hook/restore_hook
--    - Registered via llm_connect.registry.register() instead of globals
--    - get_context() provides pos1/pos2 + environment scan per iteration
--    - Tool names prefixed by registry: "worldedit_agent.set_region" etc.
--    - WEA tools included as optional tool group when worldeditadditions present
--
--  Privilege required: llm_agent (checked by registry)
--
-- ===========================================================================

-- ===========================================================================
-- Helpers
-- ===========================================================================

local NODE_ALIASES = {
    -- Common LLM hallucinations / Minecraft-ish names mapped to Minetest Game nodes.
    -- Targets are validated at runtime, so harmless if a game lacks them.
    ["default:oak_log"]       = "default:tree",
    ["default:oak_tree"]      = "default:tree",
    ["default:oak_wood"]      = "default:wood",
    ["default:oak_planks"]    = "default:wood",
    ["default:wooden_planks"] = "default:wood",
    ["default:planks"]        = "default:wood",
    ["default:log"]           = "default:tree",
    ["default:glass_pane"]    = "default:glass",
    ["default:window"]        = "default:glass",
    ["default:cobblestone"]   = "default:cobble",
    ["default:grass"]         = "default:dirt_with_grass",
    ["minecraft:oak_log"]     = "default:tree",
    ["minecraft:oak_planks"]  = "default:wood",
    ["minecraft:glass"]       = "default:glass",
    ["minecraft:cobblestone"] = "default:cobble",
}

local function registered_node(name)
    return type(name) == "string" and core.registered_nodes and core.registered_nodes[name]
end

local function resolve_registered_alias(name)
    local aliases = rawget(core, "registered_aliases")
    local target = type(aliases) == "table" and aliases[name]
    if registered_node(target) then return target end
    return nil
end

local function resolve_node(node_str)
    if not node_str or node_str == "" then return nil, "node name is empty" end

    local original = tostring(node_str)
    local node = original:lower():gsub("^%s+", ""):gsub("%s+$", "")
    if node == "" then return nil, "node name is empty" end
    if node == "air" then return "air", nil end

    local candidates = { node }
    if not node:find(":", 1, true) then
        table.insert(candidates, "default:" .. node)
    end
    table.insert(candidates, node .. "_source")
    table.insert(candidates, node:gsub("_flowing$", "_source"))

    local direct_alias = NODE_ALIASES[node]
    if direct_alias then table.insert(candidates, 1, direct_alias) end

    -- Heuristic fallbacks for model-generated material names.
    if node:find("oak", 1, true) and (node:find("log", 1, true) or node:find("trunk", 1, true)) then
        table.insert(candidates, "default:tree")
    end
    if node:find("plank", 1, true) or node:find("wood", 1, true) then
        table.insert(candidates, "default:wood")
    end
    if node:find("window", 1, true) or node:find("glass", 1, true) then
        table.insert(candidates, "default:glass")
    end
    if node:find("cobble", 1, true) or node:find("cobblestone", 1, true) then
        table.insert(candidates, "default:cobble")
    end

    local seen = {}
    for _, candidate in ipairs(candidates) do
        if candidate and not seen[candidate] then
            seen[candidate] = true
            if registered_node(candidate) then
                if candidate ~= original then
                    core.log("action", ("[worldedit_agent] resolved node '%s' -> '%s'"):format(original, candidate))
                end
                return candidate, nil
            end
            local aliased = resolve_registered_alias(candidate)
            if aliased then
                core.log("action", ("[worldedit_agent] resolved alias '%s' -> '%s'"):format(original, aliased))
                return aliased, nil
            end
        end
    end

    core.log("warning", ("[worldedit_agent] unknown node '%s' — rejected before WorldEdit call"):format(original))
    return nil, "unknown node '" .. original .. "' (use a registered node such as default:stone, default:wood, default:tree, default:glass, default:cobble or air)"
end

local function call_worldedit(label, fn, ...)
    if type(fn) ~= "function" then
        return nil, label .. ": WorldEdit function unavailable"
    end
    local result = { pcall(fn, ...) }
    local ok = table.remove(result, 1)
    if not ok then
        return nil, label .. ": " .. tostring(result[1])
    end
    return unpack(result)
end

local function make_pos(args, player_name)
    if type(args.pos) == "table" then
        return { x=tonumber(args.pos.x) or 0, y=tonumber(args.pos.y) or 0, z=tonumber(args.pos.z) or 0 }
    end
    if type(args.pos) == "string" and player_name then
        if args.pos == "pos1" and worldedit.pos1[player_name] then return worldedit.pos1[player_name] end
        if args.pos == "pos2" and worldedit.pos2[player_name] then return worldedit.pos2[player_name] end
    end
    -- Also accept player pos as default when no explicit coords given
    if not args.x and not args.y and not args.z and player_name then
        local player = core.get_player_by_name(player_name)
        if player then
            local p = player:get_pos()
            return { x=math.floor(p.x), y=math.floor(p.y), z=math.floor(p.z) }
        end
    end
    return { x=tonumber(args.x) or 0, y=tonumber(args.y) or 0, z=tonumber(args.z) or 0 }
end

local function require_selection(name)
    local p1 = worldedit.pos1 and worldedit.pos1[name]
    local p2 = worldedit.pos2 and worldedit.pos2[name]
    if not p1 or not p2 then
        return nil, nil, "No selection — use set_pos1 and set_pos2 first"
    end
    return p1, p2, nil
end

local function validate_axis(axis)
    if not ({x=1,y=1,z=1})[axis] then
        return false, "axis must be x, y or z"
    end
    return true, nil
end

-- ===========================================================================
-- Environment context (called fresh each agent iteration)
-- ===========================================================================

local function sample_environment(pos, radius, step)
    radius = radius or 6
    step   = step   or 3
    local counts = {}
    for dx = -radius, radius, step do
        for dy = -radius, radius, step do
            for dz = -radius, radius, step do
                local node = core.get_node({
                    x = math.floor(pos.x + dx),
                    y = math.floor(pos.y + dy),
                    z = math.floor(pos.z + dz),
                })
                if node and node.name ~= "air" and node.name ~= "ignore" then
                    counts[node.name] = (counts[node.name] or 0) + 1
                end
            end
        end
    end
    local sorted = {}
    for n, c in pairs(counts) do table.insert(sorted, {name=n, count=c}) end
    table.sort(sorted, function(a, b) return a.count > b.count end)
    local parts = {}
    for i = 1, math.min(8, #sorted) do
        parts[i] = sorted[i].name .. "×" .. sorted[i].count
    end
    if #parts == 0 then return "Surroundings: mostly air" end
    return "Nearby nodes (r=" .. radius .. "): " .. table.concat(parts, ", ")
end

local function get_context(player_name)
    if type(worldedit) ~= "table" then
        local modpath = core.get_modpath and core.get_modpath("worldedit") or nil
        if modpath then
            return "WorldEdit: installed at " .. tostring(modpath) .. ", but the global Lua API table is not available yet. The worldedit_agent skill cannot run until the API table exists."
        end
        return "WorldEdit: not installed or not loaded (core.get_modpath('worldedit') returned nil)"
    end

    local player = core.get_player_by_name(player_name)
    if not player then return "WorldEdit context: player not found" end

    local pos = player:get_pos()
    local px, py, pz = math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)

    local p1 = worldedit.pos1 and worldedit.pos1[player_name]
    local p2 = worldedit.pos2 and worldedit.pos2[player_name]

    local sel_str
    if p1 and p2 then
        local vol = worldedit.volume and worldedit.volume(p1, p2) or "?"
        sel_str = string.format(
            "pos1=(%d,%d,%d) pos2=(%d,%d,%d) volume=%s",
            math.floor(p1.x), math.floor(p1.y), math.floor(p1.z),
            math.floor(p2.x), math.floor(p2.y), math.floor(p2.z),
            tostring(vol))
    elseif p1 then
        sel_str = string.format("pos1=(%d,%d,%d) pos2=not set",
            math.floor(p1.x), math.floor(p1.y), math.floor(p1.z))
    else
        sel_str = "no selection"
    end

    local env = sample_environment(pos)

    local lines = {
        string.format("WorldEdit — player pos: (%d,%d,%d)", px, py, pz),
        "Selection: " .. sel_str,
        env,
        "Tip: set_pos1/set_pos2 take absolute coords. Primitives (sphere etc.) default to player pos if no coords given.",
    }

    -- WEA availability hint
    if type(worldeditadditions) == "table" and type(worldeditadditions.torus) == "function" then
        table.insert(lines, "WorldEditAdditions: available (torus, ellipsoid, erode, convolve, overlay, layers, replacemix)")
    end

    return table.concat(lines, "\n")
end

-- ===========================================================================
-- Snapshot / restore hooks (for agent-level undo)
-- ===========================================================================

local function snapshot_hook(player_name)
    if not worldedit then return nil end
    local p1 = worldedit.pos1 and worldedit.pos1[player_name]
    local p2 = worldedit.pos2 and worldedit.pos2[player_name]
    if not p1 or not p2 then return nil end
    local ok, data = pcall(worldedit.serialize, p1, p2)
    if not ok or not data then return nil end
    return {
        p1   = {x=p1.x, y=p1.y, z=p1.z},
        p2   = {x=p2.x, y=p2.y, z=p2.z},
        data = data,
    }
end

local function restore_hook(player_name, snap)
    if not snap or not snap.data then return false, "no snapshot data" end
    if not worldedit then return false, "WorldEdit not loaded" end
    local ok, count = pcall(worldedit.deserialize, snap.p1, snap.data)
    if not ok then return false, "deserialize failed: " .. tostring(count) end
    worldedit.pos1[player_name] = snap.p1
    worldedit.pos2[player_name] = snap.p2
    if worldedit.mark_pos1 then worldedit.mark_pos1(player_name) end
    if worldedit.mark_pos2 then worldedit.mark_pos2(player_name) end
    return true, nil
end

-- ===========================================================================
-- Tool runner
-- ===========================================================================

local function run_tool(tool_name, args, player_name)
    tool_name = tostring(tool_name or "")
    if type(args) ~= "table" then args = {} end
    if type(player_name) ~= "string" or player_name == "" then
        return {ok=false, message="worldedit_agent: missing player_name; call run('tool_name', {args...}, player_name)"}
    end
    if not worldedit then
        return {ok=false, message="worldedit_agent: WorldEdit is not loaded"}
    end

    -- ── Selection ────────────────────────────────────────────

    if tool_name == "set_pos1" then
        local pos = make_pos(args, player_name)
        worldedit.pos1[player_name] = pos
        if worldedit.mark_pos1 then worldedit.mark_pos1(player_name) end
        return {ok=true, message=string.format("pos1 set to (%d,%d,%d)", pos.x, pos.y, pos.z)}

    elseif tool_name == "set_pos2" then
        local pos = make_pos(args, player_name)
        worldedit.pos2[player_name] = pos
        if worldedit.mark_pos2 then worldedit.mark_pos2(player_name) end
        return {ok=true, message=string.format("pos2 set to (%d,%d,%d)", pos.x, pos.y, pos.z)}

    elseif tool_name == "get_selection" then
        local p1 = worldedit.pos1[player_name]
        local p2 = worldedit.pos2[player_name]
        if not p1 or not p2 then return {ok=true, message="No selection set."} end
        return {ok=true, message=string.format(
            "pos1=(%d,%d,%d) pos2=(%d,%d,%d) volume=%s",
            p1.x,p1.y,p1.z, p2.x,p2.y,p2.z,
            tostring(worldedit.volume and worldedit.volume(p1,p2) or "?"))}

    -- ── Region ops ───────────────────────────────────────────

    elseif tool_name == "set_region" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local node, nerr = resolve_node(tostring(args.node or "air"))
        if not node then return {ok=false, message="set_region: " .. nerr} end
        local count, call_err = call_worldedit("set_region", worldedit.set, p1, p2, node)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Set %d nodes to %s", count or 0, node), data={nodes=count}}

    elseif tool_name == "clear_region" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local count, call_err = call_worldedit("clear_region", worldedit.set, p1, p2, "air")
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Cleared %d nodes", count or 0), data={nodes=count}}

    elseif tool_name == "replace" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local search,   e1 = resolve_node(tostring(args.search_node  or ""))
        local replace_, e2 = resolve_node(tostring(args.replace_node or "air"))
        if not search   then return {ok=false, message="replace: search: "  .. (e1 or "?")} end
        if not replace_ then return {ok=false, message="replace: replace: " .. (e2 or "?")} end
        local count, call_err = call_worldedit("replace", worldedit.replace, p1, p2, search, replace_)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Replaced %d nodes: %s → %s", count or 0, search, replace_)}

    elseif tool_name == "copy" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local axis   = tostring(args.axis or "y")
        local amount = tonumber(args.amount or 1)
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="copy: " .. aerr} end
        local count, call_err = call_worldedit("copy", worldedit.copy, p1, p2, axis, amount)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Copied %d nodes along %s by %d", count or 0, axis, amount)}

    elseif tool_name == "move" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local axis   = tostring(args.axis or "y")
        local amount = tonumber(args.amount or 1)
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="move: " .. aerr} end
        local count, newp1, newp2 = call_worldedit("move", worldedit.move, p1, p2, axis, amount)
        if count == nil and type(newp1) == "string" then return {ok=false, message=newp1} end
        if newp1 then worldedit.pos1[player_name] = newp1 end
        if newp2 then worldedit.pos2[player_name] = newp2 end
        return {ok=true, message=string.format("Moved %d nodes along %s by %d", count or 0, axis, amount)}

    elseif tool_name == "stack" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local axis  = tostring(args.axis  or "y")
        local count = tonumber(args.count or 1)
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="stack: " .. aerr} end
        local nodes, call_err = call_worldedit("stack", worldedit.stack, p1, p2, axis, count)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Stacked %d times along %s (%d nodes)", count, axis, nodes or 0)}

    elseif tool_name == "flip" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local axis = tostring(args.axis or "y")
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="flip: " .. aerr} end
        local count, call_err = call_worldedit("flip", worldedit.flip, p1, p2, axis)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Flipped along %s (%d nodes)", axis, count or 0)}

    elseif tool_name == "rotate" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local axis  = tostring(args.axis  or "y")
        local angle = tonumber(args.angle or 90)
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="rotate: " .. aerr} end
        if not ({[90]=1,[180]=1,[270]=1,[-90]=1})[angle] then
            return {ok=false, message="rotate: angle must be 90, 180, 270 or -90"}
        end
        local count, newp1, newp2 = call_worldedit("rotate", worldedit.rotate, p1, p2, axis, angle)
        if count == nil and type(newp1) == "string" then return {ok=false, message=newp1} end
        if newp1 then worldedit.pos1[player_name] = newp1 end
        if newp2 then worldedit.pos2[player_name] = newp2 end
        return {ok=true, message=string.format("Rotated %d° around %s (%d nodes)", angle, axis, count or 0)}

    -- ── Primitives ───────────────────────────────────────────

    elseif tool_name == "sphere" then
        local pos    = make_pos(args, player_name)
        local radius = tonumber(args.radius or 5)
        local node, nerr = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="sphere: " .. nerr} end
        local hollow = args.hollow == true or args.hollow == "true"
        if radius < 1 or radius > 64 then return {ok=false, message="sphere: radius must be 1–64"} end
        local count, call_err = call_worldedit("sphere", worldedit.sphere, pos, radius, node, hollow)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Sphere r=%d %s at (%d,%d,%d): %d nodes",
            radius, node, pos.x, pos.y, pos.z, count or 0)}

    elseif tool_name == "dome" then
        local pos    = make_pos(args, player_name)
        local radius = tonumber(args.radius or 5)
        local node, nerr = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="dome: " .. nerr} end
        local hollow = args.hollow == true or args.hollow == "true"
        if radius < 1 or radius > 64 then return {ok=false, message="dome: radius must be 1–64"} end
        local primitive = worldedit.dome or worldedit.sphere  -- fallback if dome not available
        local count, call_err = call_worldedit("dome", primitive, pos, radius, node, hollow)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Dome r=%d %s at (%d,%d,%d): %d nodes",
            radius, node, pos.x, pos.y, pos.z, count or 0)}

    elseif tool_name == "cylinder" then
        local pos    = make_pos(args, player_name)
        local axis   = tostring(args.axis or "y")
        local length = tonumber(args.length or 5)
        local r1     = tonumber(args.radius or args.radius1 or 3)
        local r2     = tonumber(args.radius2 or r1)
        local node, nerr = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="cylinder: " .. nerr} end
        local hollow = args.hollow == true or args.hollow == "true"
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="cylinder: " .. aerr} end
        if length < 1 or length > 128 then return {ok=false, message="cylinder: length must be 1–128"} end
        if r1 < 1 or r1 > 64 then return {ok=false, message="cylinder: radius must be 1–64"} end
        local count, call_err = call_worldedit("cylinder", worldedit.cylinder, pos, axis, length, r1, r2, node, hollow)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Cylinder axis=%s len=%d r=%d %s at (%d,%d,%d): %d nodes",
            axis, length, r1, node, pos.x, pos.y, pos.z, count or 0)}

    elseif tool_name == "pyramid" then
        local pos    = make_pos(args, player_name)
        local axis   = tostring(args.axis or "y")
        local height = tonumber(args.height or 5)
        local node, nerr = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="pyramid: " .. nerr} end
        local hollow = args.hollow == true or args.hollow == "true"
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="pyramid: " .. aerr} end
        if height < 1 or height > 64 then return {ok=false, message="pyramid: height must be 1–64"} end
        local count, call_err = call_worldedit("pyramid", worldedit.pyramid, pos, axis, height, node, hollow)
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Pyramid axis=%s h=%d %s at (%d,%d,%d): %d nodes",
            axis, height, node, pos.x, pos.y, pos.z, count or 0)}

    elseif tool_name == "cube" then
        local pos  = make_pos(args, player_name)
        local w    = tonumber(args.width  or args.w or 5)
        local h    = tonumber(args.height or args.h or 5)
        local l    = tonumber(args.length or args.l or 5)
        local node, nerr = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="cube: " .. nerr} end
        local hollow = args.hollow == true or args.hollow == "true"
        if w < 1 or h < 1 or l < 1 or w > 128 or h > 128 or l > 128 then
            return {ok=false, message="cube: dimensions must be 1–128"}
        end
        -- worldedit.cube may not exist in all versions — use set_region as fallback.
        local count, call_err
        if worldedit.cube then
            count, call_err = call_worldedit("cube", worldedit.cube, pos, w, h, l, node, hollow)
        else
            local p1 = {x=pos.x, y=pos.y, z=pos.z}
            local p2 = {x=pos.x+w-1, y=pos.y+h-1, z=pos.z+l-1}
            count, call_err = call_worldedit("cube/set fallback", worldedit.set, p1, p2, node)
        end
        if call_err then return {ok=false, message=call_err} end
        return {ok=true, message=string.format("Cube %dx%dx%d %s at (%d,%d,%d): %d nodes",
            w, h, l, node, pos.x, pos.y, pos.z, count or 0)}

    -- ── WEA tools (only dispatched if worldeditadditions present) ────────────

    elseif tool_name == "torus" then
        if not (type(worldeditadditions) == "table" and worldeditadditions.torus) then
            return {ok=false, message="torus: WorldEditAdditions not available"}
        end
        local p1 = worldedit.pos1[player_name] or make_pos(args, player_name)
        local r_major = tonumber(args.radius_major or args.radius or 10)
        local r_minor = tonumber(args.radius_minor or args.tube_radius or 3)
        local node, nerr = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="torus: " .. nerr} end
        local hollow = args.hollow == true or args.hollow == "true"
        if r_major < 1 or r_major > 64 then return {ok=false, message="torus: radius_major must be 1–64"} end
        if r_minor < 1 or r_minor > 32 then return {ok=false, message="torus: radius_minor must be 1–32"} end
        local ok, count = pcall(worldeditadditions.torus, p1, r_major, r_minor, node, hollow)
        if not ok then return {ok=false, message="torus: " .. tostring(count)} end
        return {ok=true, message=string.format("Torus R=%d r=%d %s: %d nodes", r_major, r_minor, node, count or 0)}

    elseif tool_name == "ellipsoid" then
        if not (type(worldeditadditions) == "table" and worldeditadditions.ellipsoid) then
            return {ok=false, message="ellipsoid: WorldEditAdditions not available"}
        end
        local p1   = worldedit.pos1[player_name] or make_pos(args, player_name)
        local rx   = tonumber(args.rx or 5)
        local ry   = tonumber(args.ry or 5)
        local rz   = tonumber(args.rz or 5)
        local node, nerr = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="ellipsoid: " .. nerr} end
        local hollow = args.hollow == true or args.hollow == "true"
        local ok, count = pcall(worldeditadditions.ellipsoid, p1, rx, ry, rz, node, hollow)
        if not ok then return {ok=false, message="ellipsoid: " .. tostring(count)} end
        return {ok=true, message=string.format("Ellipsoid rx=%d ry=%d rz=%d %s: %d nodes", rx, ry, rz, node, count or 0)}

    elseif tool_name == "overlay" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        if not (type(worldeditadditions) == "table") then
            return {ok=false, message="overlay: WorldEditAdditions not available"}
        end
        local node, nerr = resolve_node(tostring(args.node or "default:dirt_with_grass"))
        if not node then return {ok=false, message="overlay: " .. nerr} end
        local ok, count = pcall(worldeditadditions.overlay, p1, p2, node)
        if not ok then return {ok=false, message="overlay: " .. tostring(count)} end
        return {ok=true, message=string.format("Overlay %s: %d nodes", node, count or 0)}

    elseif tool_name == "erode" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        if not (type(worldeditadditions) == "table") then
            return {ok=false, message="erode: WorldEditAdditions not available"}
        end
        local algorithm  = tostring(args.algorithm or "snowballs")
        local iterations = tonumber(args.iterations or 1)
        if iterations < 1 then iterations = 1 end
        if iterations > 10 then iterations = 10 end
        local ok, msg = pcall(worldeditadditions.erode, p1, p2, {algorithm=algorithm, iterations=iterations})
        if not ok then return {ok=false, message="erode: " .. tostring(msg)} end
        return {ok=true, message=string.format("Erode (%s, %d iter): done", algorithm, iterations)}

    elseif tool_name == "convolve" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        if not (type(worldeditadditions) == "table") then
            return {ok=false, message="convolve: WorldEditAdditions not available"}
        end
        local kernel = tostring(args.kernel or "gaussian")
        local size   = tonumber(args.size or 5)
        if size < 3 then size = 3 end
        if size > 15 then size = 15 end
        if size % 2 == 0 then size = size + 1 end
        local ok, count = pcall(worldeditadditions.convolve, p1, p2, {kernel=kernel, size=size})
        if not ok then return {ok=false, message="convolve: " .. tostring(count)} end
        return {ok=true, message=string.format("Convolve kernel=%s size=%d: done", kernel, size)}

    else
        return {ok=false, message="unknown tool: " .. tostring(tool_name)}
    end
end

-- ===========================================================================
-- Tool definitions for registry manifest
-- ===========================================================================

local TOOLS = {
    -- Selection
    { name="set_pos1",      description="Set WorldEdit pos1 to absolute coords. Defaults to player pos if no x/y/z given.",
      parameters={x="integer (optional)", y="integer (optional)", z="integer (optional)"} },
    { name="set_pos2",      description="Set WorldEdit pos2 to absolute coords. Defaults to player pos if no x/y/z given.",
      parameters={x="integer (optional)", y="integer (optional)", z="integer (optional)"} },
    { name="get_selection", description="Return current pos1, pos2 and volume.",
      parameters={} },
    -- Region
    { name="set_region",    description="Fill current selection with node. Use 'air' to clear/delete.",
      parameters={node="string — e.g. 'default:stone' or 'air'"} },
    { name="clear_region",  description="Fill current selection with air (delete all nodes in region).",
      parameters={} },
    { name="replace",       description="Replace all occurrences of search_node with replace_node in selection.",
      parameters={search_node="string", replace_node="string"} },
    { name="copy",          description="Copy selection along axis by amount blocks.",
      parameters={axis="string — x|y|z", amount="integer"} },
    { name="move",          description="Move selection along axis by amount blocks (updates pos1/pos2).",
      parameters={axis="string — x|y|z", amount="integer"} },
    { name="stack",         description="Duplicate selection count times along axis.",
      parameters={axis="string — x|y|z", count="integer"} },
    { name="flip",          description="Mirror selection along axis.",
      parameters={axis="string — x|y|z"} },
    { name="rotate",        description="Rotate selection by angle degrees around axis (updates pos1/pos2).",
      parameters={axis="string — x|y|z", angle="integer — 90|180|270|-90"} },
    -- Primitives
    { name="sphere",        description="Generate a filled or hollow sphere at given pos (defaults to player pos).",
      parameters={x="integer (optional)", y="integer (optional)", z="integer (optional)",
                  radius="integer 1–64", node="string", hollow="boolean (optional)"} },
    { name="dome",          description="Generate a dome (upper hemisphere) at given pos.",
      parameters={x="integer (optional)", y="integer (optional)", z="integer (optional)",
                  radius="integer 1–64", node="string", hollow="boolean (optional)"} },
    { name="cylinder",      description="Generate a cylinder at pos along axis.",
      parameters={x="integer (optional)", y="integer (optional)", z="integer (optional)",
                  axis="string — x|y|z", length="integer 1–128",
                  radius="integer 1–64", node="string", hollow="boolean (optional)"} },
    { name="pyramid",       description="Generate a pyramid at pos along axis.",
      parameters={x="integer (optional)", y="integer (optional)", z="integer (optional)",
                  axis="string — x|y|z", height="integer 1–64",
                  node="string", hollow="boolean (optional)"} },
    { name="cube",          description="Generate a solid or hollow box at pos.",
      parameters={x="integer (optional)", y="integer (optional)", z="integer (optional)",
                  width="integer 1–128", height="integer 1–128", length="integer 1–128",
                  node="string", hollow="boolean (optional)"} },
    -- WEA (always listed — dispatch fails gracefully if WEA not loaded)
    { name="torus",         description="WorldEditAdditions: torus at pos1. Requires WEA.",
      parameters={radius_major="integer 1–64", radius_minor="integer 1–32",
                  node="string", hollow="boolean (optional)"} },
    { name="ellipsoid",     description="WorldEditAdditions: ellipsoid at pos1. Requires WEA.",
      parameters={rx="integer 1–64", ry="integer 1–64", rz="integer 1–64",
                  node="string", hollow="boolean (optional)"} },
    { name="overlay",       description="WorldEditAdditions: place node on every surface column in selection. Requires WEA.",
      parameters={node="string"} },
    { name="erode",         description="WorldEditAdditions: erode terrain in selection. Requires WEA.",
      parameters={algorithm="string — snowballs|river|wind (optional, default snowballs)",
                  iterations="integer 1–10 (optional)"} },
    { name="convolve",      description="WorldEditAdditions: smooth terrain with convolution kernel in selection. Requires WEA.",
      parameters={kernel="string — gaussian|box|pascal (optional)",
                  size="odd integer 3–15 (optional)"} },
}

-- ===========================================================================
-- Register with llm_connect
-- ===========================================================================

local function do_register()
    local root = rawget(_G, "llm_connect")
    if type(root) ~= "table" or type(root.registry) ~= "table" then
        core.log("warning", "[worldedit_agent] llm_connect.registry not available — not registering")
        return
    end

    root.skills = root.skills or {}
    local function normalize_run_args(a, b, c)
        -- Preferred: run('cube', {width=5}, player_name)
        if type(a) == "string" and type(b) == "table" and type(c) == "string" then
            return a, b, c
        end
        -- Common accidental variant: run('cube', player_name, {width=5})
        if type(a) == "string" and type(b) == "string" and type(c) == "table" then
            return a, c, b
        end
        -- Single spec table: run({tool='cube', args={...}}, player_name)
        if type(a) == "table" and type(b) == "string" then
            local tool = a.tool or a.name or a.action
            local args = a.args or a.params or a.parameters or a
            return tool, args, b
        end
        -- Spec table with embedded player: run({tool='cube', player_name=player_name, ...})
        if type(a) == "table" then
            local tool = a.tool or a.name or a.action
            local args = a.args or a.params or a.parameters or a
            local player = a.player_name or a.player or b or c
            return tool, args, player
        end
        return a, b, c
    end

    root.skills.worldedit_agent = {
        run = function(a, b, c)
            local tool_name, args, player_name = normalize_run_args(a, b, c)
            return run_tool(tool_name, args or {}, player_name)
        end,
        get_context = get_context,
        snapshot = snapshot_hook,
        restore = restore_hook,
    }


    if root.context and type(root.context.register_section) == "function" then
        root.context.register_section({
            id = "skills.worldedit_agent",
            title = "WorldEdit Agent skill manual",
            summary = "Selections, region operations, primitives, and safe node/material usage.",
            tags = {"skill", "worldedit", "building", "nodes", "regions"},
            required_priv = "llm_agent",
            provider = function(player_name)
                return table.concat({
                    get_context(player_name),
                    "",
                    "Preferred call form:",
                    "  llm_connect.skills.worldedit_agent.run('tool_name', {arg=value}, player_name)",
                    "Do not omit player_name. Do not pass player_name as the first argument.",
                    "",
                    "Common calls:",
                    "  llm_connect.skills.worldedit_agent.run('set_pos1', {x=0,y=0,z=0}, player_name)",
                    "  llm_connect.skills.worldedit_agent.run('set_pos2', {x=10,y=10,z=10}, player_name)",
                    "  llm_connect.skills.worldedit_agent.run('set_region', {node='default:stone'}, player_name)",
                    "  llm_connect.skills.worldedit_agent.run('clear_region', {}, player_name)",
                    "  llm_connect.skills.worldedit_agent.run('cube', {width=5,height=3,length=5,node='default:stone',hollow=false}, player_name)",
                    "  llm_connect.skills.worldedit_agent.run('sphere', {radius=4,node='default:glass',hollow=true}, player_name)",
                    "",
                    "Safe common materials:",
                    "  default:stone, default:cobble, default:wood, default:tree, default:glass, default:brick, default:dirt_with_grass, air",
                    "Node resolver accepts common aliases like default:oak_log -> default:tree and default:oak_planks -> default:wood.",
                    "Unknown nodes are rejected before WorldEdit to prevent runtime crashes.",
                    "For unfamiliar materials, query llm_connect.context.get_section('luanti.registered_nodes.preview', {query='wood'}).",
                }, "\n")
            end,
        })
    end


    root.registry.register_skill({
        id          = "worldedit_agent",
        label       = "WorldEdit Agent",
        version     = "1.1.0-dev",
        description = "Lua-first WorldEdit bridge: selections, region operations, primitives and optional WEA tools.",
        required_priv = "llm_agent",
        default_enabled = false,
        available = function()
            local we = rawget(_G, "worldedit")
            return type(we) == "table"
                and (type(we.set) == "function"
                     or type(we.set_node) == "function"
                     or next(we) ~= nil)
        end,
        context_section = "skills.worldedit_agent",
        get_context = get_context,
        snapshot_hook = snapshot_hook,
        restore_hook  = restore_hook,
        tool_count = #TOOLS,
    })
end

do_register()

core.log("action", "[worldedit_agent] loaded")
