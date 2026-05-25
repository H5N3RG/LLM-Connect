-- ===========================================================================
--  skills/worldedit_agent/worldedit_agent.lua — LLM Connect Node Printer
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Agent-facing node printer for LLM Connect.
--  The skill id remains worldedit_agent for compatibility, but the preferred
--  path is native batch node placement. WorldEdit remains a bridge backend for
--  selections and legacy operations.
--
--  Gateway contract:
--    - skills/worldedit_agent/init.lua is discovered generically.
--    - This file registers its own API through registry.register_skill().
--    - Context aliases and manuals are owned by this skill, not the engine.
--    - WorldEdit bridge tools are compatibility/extension paths; native
--      print_plan is the preferred generated-structure primitive.
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
    table.insert(candidates, (node:gsub("_flowing$", "_source")))

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
        if type(worldedit) == "table" and args.pos == "pos1" and worldedit.pos1 and worldedit.pos1[player_name] then return worldedit.pos1[player_name] end
        if type(worldedit) == "table" and args.pos == "pos2" and worldedit.pos2 and worldedit.pos2[player_name] then return worldedit.pos2[player_name] end
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

local validate_axis
function validate_axis(axis)
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
    local player = core.get_player_by_name(player_name)
    if not player then return "Node Printer context: player not found" end

    local pos = player:get_pos()
    local px, py, pz = math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)

    local we_available = type(worldedit) == "table"
    local p1 = we_available and worldedit.pos1 and worldedit.pos1[player_name]
    local p2 = we_available and worldedit.pos2 and worldedit.pos2[player_name]

    local sel_str
    if not we_available then
        local modpath = core.get_modpath and core.get_modpath("worldedit") or nil
        sel_str = modpath
            and "WorldEdit installed but Lua API table unavailable; native node printing still works"
            or "WorldEdit not loaded; native node printing still works"
    elseif p1 and p2 then
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
        string.format("Node Printer — player pos: (%d,%d,%d)", px, py, pz),
        "Selection: " .. sel_str,
        env,
        "Canonical invocation: llm_connect.skills.worldedit_agent.run(\"<tool>\", args, player_name).",
        "Stable tools: preview_plan, print_plan, get_node.",
        "WorldEdit bridge calls exist internally for compatibility but are experimental agent-facing surface.",
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
-- Native node-printer primitives
-- ===========================================================================

local function place_node(name, x, y, z)
    local pos = {x = x, y = y, z = z}
    local pos_label = core.pos_to_string and core.pos_to_string(pos) or ("(" .. x .. "," .. y .. "," .. z .. ")")
    local ok, err = pcall(core.set_node, pos, {name = name})
    if not ok then
        return false, "set_node failed at " .. pos_label .. ": " .. tostring(err)
    end

    local read = core.get_node_or_nil and core.get_node_or_nil(pos) or core.get_node(pos)
    if not read then
        return false, "node write could not be verified at " .. pos_label .. " (unloaded or inaccessible mapblock)"
    end
    if read.name == "ignore" then
        return false, "node write hit ignore at " .. pos_label .. " (mapblock not loaded)"
    end
    if read.name ~= name then
        return false, "node mismatch at " .. pos_label .. ": expected " .. tostring(name) .. ", got " .. tostring(read.name)
    end
    return true
end

local function fill_box(p1, p2, node, hollow)
    local minx, maxx = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local miny, maxy = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local minz, maxz = math.min(p1.z, p2.z), math.max(p1.z, p2.z)
    local count = 0
    for x = minx, maxx do
        for y = miny, maxy do
            for z = minz, maxz do
                local boundary = x == minx or x == maxx or y == miny or y == maxy or z == minz or z == maxz
                if not hollow or boundary then
                    place_node(node, x, y, z)
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function copy_pos(pos)
    return {
        x = math.floor(tonumber(pos and pos.x) or 0),
        y = math.floor(tonumber(pos and pos.y) or 0),
        z = math.floor(tonumber(pos and pos.z) or 0),
    }
end

local function add_pos(a, b)
    return {
        x = (a and a.x or 0) + (b and b.x or 0),
        y = (a and a.y or 0) + (b and b.y or 0),
        z = (a and a.z or 0) + (b and b.z or 0),
    }
end

local function table_len(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function plan_int(v, default, min_v, max_v)
    v = tonumber(v or default) or default
    v = math.floor(v)
    if min_v and v < min_v then v = min_v end
    if max_v and v > max_v then v = max_v end
    return v
end

local function resolve_plan_origin(args, player_name)
    local absolute = args and args.absolute == true
    if absolute then
        if type(args.origin) == "table" then return copy_pos(args.origin) end
        return { x = 0, y = 0, z = 0 }
    end

    if args and (args.origin == nil or args.origin == "player") then
        local player = player_name and core.get_player_by_name(player_name)
        if player then return copy_pos(player:get_pos()) end
        return nil, "relative plan requires a player position"
    end

    if type(args.origin) == "table" then
        local origin = copy_pos(args.origin)
        if origin.x == 0 and origin.y == 0 and origin.z == 0 then
            return nil, "origin={x=0,y=0,z=0} with absolute=false would build at world origin; omit origin or use origin=\"player\" to build at the player"
        end
        return origin
    end

    if type(args.pos) == "table" then return make_pos(args, player_name) end
    local player = player_name and core.get_player_by_name(player_name)
    if player then return copy_pos(player:get_pos()) end
    return nil, "relative plan requires a player position"
end

local function plan_pos(raw, origin, absolute)
    local pos = type(raw) == "table" and raw.pos or raw
    local out = copy_pos(pos or raw)
    if absolute == true then return out end
    return add_pos(origin, out)
end

local function mul_pos(v, n)
    return {
        x = (v and v.x or 0) * n,
        y = (v and v.y or 0) * n,
        z = (v and v.z or 0) * n,
    }
end

local function vector_from(raw, default, label)
    if raw == nil then return copy_pos(default), nil end
    if type(raw) == "string" then
        local key = raw:lower()
        local axes = {
            x = {x=1,y=0,z=0},
            y = {x=0,y=1,z=0},
            z = {x=0,y=0,z=1},
            ["-x"] = {x=-1,y=0,z=0},
            ["-y"] = {x=0,y=-1,z=0},
            ["-z"] = {x=0,y=0,z=-1},
            up = {x=0,y=1,z=0},
            down = {x=0,y=-1,z=0},
            north = {x=0,y=0,z=1},
            south = {x=0,y=0,z=-1},
            east = {x=1,y=0,z=0},
            west = {x=-1,y=0,z=0},
        }
        raw = axes[key]
    end
    if type(raw) ~= "table" then
        return nil, (label or "dir") .. ": direction vector must be {x=...,y=...,z=...}"
    end
    local v = copy_pos(raw)
    if v.x == 0 and v.y == 0 and v.z == 0 then
        return nil, (label or "dir") .. ": direction vector must not be zero"
    end
    return v, nil
end

local function count_items(list)
    return type(list) == "table" and #list or 0
end

local function reject_trivial_solid_plan(args)
    if args and args.allow_solid_volume == true then return nil end
    if count_items(args and args.nodes) > 0 then return nil end
    if count_items(args and args.lines) > 0 then return nil end
    if count_items(args and args.planes) > 0 then return nil end
    if count_items(args and args.rows) > 0 then return nil end
    if count_items(args and args.boxes) > 0 then return nil end
    if count_items(args and args.volumes) ~= 1 then return nil end

    local volume = args.volumes[1]
    if type(volume) ~= "table" or volume.hollow == true then return nil end
    local size1 = plan_int(volume.size1 or volume.width or volume.w, 1, 1, 20000)
    local size2 = plan_int(volume.size2 or volume.height or volume.h, 1, 1, 20000)
    local size3 = plan_int(volume.size3 or volume.depth or volume.length or volume.l, 1, 1, 20000)
    if size1 * size2 * size3 < 64 then return nil end

    return "single solid volume plans are not valid generated structures; compose named buildings from floors, walls, openings, roofs, towers or battlements, or set allow_solid_volume=true only for an explicit literal cube/block request"
end

local function append_op(ops, pos, node, limit)
    if #ops >= limit then return false, "plan exceeds max_nodes=" .. tostring(limit) end
    ops[#ops + 1] = { x = pos.x, y = pos.y, z = pos.z, node = node }
    return true
end

local function append_directed_ops(ops, start, dirs, sizes, node, hollow, limit)
    local dims = #dirs
    if dims == 1 then
        for i = 0, sizes[1] - 1 do
            local ok, err = append_op(ops, add_pos(start, mul_pos(dirs[1], i)), node, limit)
            if not ok then return false, err end
        end
        return true
    end

    if dims == 2 then
        for i = 0, sizes[1] - 1 do
            for j = 0, sizes[2] - 1 do
                local pos = add_pos(add_pos(start, mul_pos(dirs[1], i)), mul_pos(dirs[2], j))
                local ok, err = append_op(ops, pos, node, limit)
                if not ok then return false, err end
            end
        end
        return true
    end

    for i = 0, sizes[1] - 1 do
        for j = 0, sizes[2] - 1 do
            for k = 0, sizes[3] - 1 do
                local boundary = i == 0 or j == 0 or k == 0
                    or i == sizes[1] - 1 or j == sizes[2] - 1 or k == sizes[3] - 1
                if not hollow or boundary then
                    local pos = add_pos(add_pos(add_pos(start, mul_pos(dirs[1], i)), mul_pos(dirs[2], j)), mul_pos(dirs[3], k))
                    local ok, err = append_op(ops, pos, node, limit)
                    if not ok then return false, err end
                end
            end
        end
    end
    return true
end

local function append_box_ops(ops, p1, p2, node, hollow, limit)
    local minx, maxx = math.min(p1.x, p2.x), math.max(p1.x, p2.x)
    local miny, maxy = math.min(p1.y, p2.y), math.max(p1.y, p2.y)
    local minz, maxz = math.min(p1.z, p2.z), math.max(p1.z, p2.z)
    for x = minx, maxx do
        for y = miny, maxy do
            for z = minz, maxz do
                local boundary = x == minx or x == maxx or y == miny or y == maxy or z == minz or z == maxz
                if not hollow or boundary then
                    if #ops >= limit then return false, "plan exceeds max_nodes=" .. tostring(limit) end
                    ops[#ops + 1] = { x = x, y = y, z = z, node = node }
                end
            end
        end
    end
    return true
end

local function build_node_plan(args, player_name)
    args = args or {}
    local trivial_err = reject_trivial_solid_plan(args)
    if trivial_err then return nil, trivial_err end

    local origin, origin_err = resolve_plan_origin(args, player_name)
    if not origin then return nil, origin_err end
    local absolute = args.absolute == true
    local max_nodes = tonumber(args.max_nodes or 20000) or 20000
    local ops = {}

    for _, item in ipairs(args.nodes or {}) do
        local node, err = resolve_node(tostring(item.node or item.name or item[4] or args.node or "air"))
        if not node then return nil, "nodes: " .. err end
        local raw_pos = item.at or item.pos or { x = item.x or item[1], y = item.y or item[2], z = item.z or item[3] }
        local pos = plan_pos(raw_pos, origin, absolute)
        local ok, oerr = append_op(ops, pos, node, max_nodes)
        if not ok then return nil, oerr end
    end

    for _, line in ipairs(args.lines or {}) do
        local node, err = resolve_node(tostring(line.node or line.name or args.node or "air"))
        if not node then return nil, "lines: " .. err end
        local dir, derr = vector_from(line.dir or line.direction, {x=1,y=0,z=0}, "lines.dir")
        if not dir then return nil, derr end
        local len = plan_int(line.size or line.length or line.count, 1, 1, max_nodes)
        local start = plan_pos(line.from or line.at or line.pos or line, origin, absolute)
        local ok, lerr = append_directed_ops(ops, start, {dir}, {len}, node, false, max_nodes)
        if not ok then return nil, lerr end
    end

    for _, plane in ipairs(args.planes or {}) do
        local node, err = resolve_node(tostring(plane.node or plane.name or args.node or "air"))
        if not node then return nil, "planes: " .. err end
        local dir1, d1err = vector_from(plane.dir1, {x=1,y=0,z=0}, "planes.dir1")
        if not dir1 then return nil, d1err end
        local dir2, d2err = vector_from(plane.dir2, {x=0,y=0,z=1}, "planes.dir2")
        if not dir2 then return nil, d2err end
        local size1 = plan_int(plane.size1 or plane.width or plane.w, 1, 1, max_nodes)
        local size2 = plan_int(plane.size2 or plane.height or plane.h or plane.depth or plane.length or plane.l, 1, 1, max_nodes)
        local start = plan_pos(plane.from or plane.at or plane.pos or plane, origin, absolute)
        local ok, perr = append_directed_ops(ops, start, {dir1, dir2}, {size1, size2}, node, false, max_nodes)
        if not ok then return nil, perr end
    end

    for _, volume in ipairs(args.volumes or {}) do
        local node, err = resolve_node(tostring(volume.node or volume.name or args.node or "air"))
        if not node then return nil, "volumes: " .. err end
        local dir1, d1err = vector_from(volume.dir1, {x=1,y=0,z=0}, "volumes.dir1")
        if not dir1 then return nil, d1err end
        local dir2, d2err = vector_from(volume.dir2, {x=0,y=1,z=0}, "volumes.dir2")
        if not dir2 then return nil, d2err end
        local dir3, d3err = vector_from(volume.dir3, {x=0,y=0,z=1}, "volumes.dir3")
        if not dir3 then return nil, d3err end
        local size1 = plan_int(volume.size1 or volume.width or volume.w, 1, 1, max_nodes)
        local size2 = plan_int(volume.size2 or volume.height or volume.h, 1, 1, max_nodes)
        local size3 = plan_int(volume.size3 or volume.depth or volume.length or volume.l, 1, 1, max_nodes)
        local start = plan_pos(volume.from or volume.at or volume.pos or volume, origin, absolute)
        local ok, verr = append_directed_ops(ops, start, {dir1, dir2, dir3}, {size1, size2, size3}, node, volume.hollow == true, max_nodes)
        if not ok then return nil, verr end
    end

    -- Legacy inputs are accepted for old callers, but the model-facing contract
    -- is nodes/lines/planes/volumes.
    for _, row in ipairs(args.rows or {}) do
        local node, err = resolve_node(tostring(row.node or row.name or args.node or "air"))
        if not node then return nil, "rows: " .. err end
        local axis = tostring(row.axis or "x")
        local ok, aerr = validate_axis(axis)
        if not ok then return nil, "rows: " .. aerr end
        local len = plan_int(row.length or row.count, 1, 1, max_nodes)
        local step = tonumber(row.step or 1) or 1
        local start = plan_pos(row.pos or { x = row.x, y = row.y, z = row.z }, origin, absolute)
        for i = 0, len - 1 do
            if #ops >= max_nodes then return nil, "plan exceeds max_nodes=" .. tostring(max_nodes) end
            local pos = { x = start.x, y = start.y, z = start.z }
            pos[axis] = pos[axis] + i * step
            ops[#ops + 1] = { x = pos.x, y = pos.y, z = pos.z, node = node }
        end
    end

    for _, box in ipairs(args.boxes or {}) do
        local node, err = resolve_node(tostring(box.node or box.name or args.node or "air"))
        if not node then return nil, "boxes: " .. err end
        local p1 = plan_pos(box.pos1 or box.p1 or box.from or box.min or box, origin, absolute)
        local p2
        if box.pos2 or box.p2 or box.to or box.max then
            p2 = plan_pos(box.pos2 or box.p2 or box.to or box.max, origin, absolute)
        else
            p2 = {
                x = p1.x + plan_int(box.width or box.w, 1, 1, max_nodes) - 1,
                y = p1.y + plan_int(box.height or box.h, 1, 1, max_nodes) - 1,
                z = p1.z + plan_int(box.length or box.l, 1, 1, max_nodes) - 1,
            }
        end
        local ok, berr = append_box_ops(ops, p1, p2, node, box.hollow == true, max_nodes)
        if not ok then return nil, berr end
    end

    return ops, nil, origin
end

local function print_plan(args, player_name)
    local ops, err, origin = build_node_plan(args or {}, player_name)
    if not ops then return { ok = false, success = false, message = err } end
    if #ops == 0 then
        return { ok = false, success = false, message = "print_plan: no nodes, lines, planes, or volumes supplied" }
    end

    local by_node = {}
    local minp, maxp
    for _, op in ipairs(ops) do
        by_node[op.node] = (by_node[op.node] or 0) + 1
        if not minp then
            minp = { x = op.x, y = op.y, z = op.z }
            maxp = { x = op.x, y = op.y, z = op.z }
        else
            minp.x = math.min(minp.x, op.x); minp.y = math.min(minp.y, op.y); minp.z = math.min(minp.z, op.z)
            maxp.x = math.max(maxp.x, op.x); maxp.y = math.max(maxp.y, op.y); maxp.z = math.max(maxp.z, op.z)
        end
    end

    if args and args.dry_run == true then
        return {
            ok = true,
            success = true,
            message = string.format("Plan validated: %d node writes", #ops),
            data = { nodes = #ops, materials = by_node, origin = origin, min = minp, max = maxp },
        }
    end

    local failed = {}
    for _, op in ipairs(ops) do
        local ok, perr = place_node(op.node, op.x, op.y, op.z)
        if not ok then
            failed[#failed + 1] = perr or ("write failed at (" .. tostring(op.x) .. "," .. tostring(op.y) .. "," .. tostring(op.z) .. ")")
            if #failed >= 5 then break end
        end
    end

    if #failed > 0 then
        local message = string.format(
            "print_plan wrote with verification failures: %d sample failure(s); first: %s",
            #failed,
            failed[1]
        )
        core.log("warning", ("[worldedit_agent] %s | origin=%s min=%s max=%s nodes=%d"):format(
            message,
            core.pos_to_string and core.pos_to_string(origin) or "?",
            core.pos_to_string and core.pos_to_string(minp) or "?",
            core.pos_to_string and core.pos_to_string(maxp) or "?",
            #ops
        ))
        return {
            ok = false,
            success = false,
            message = message,
            data = { nodes = #ops, materials = by_node, origin = origin, min = minp, max = maxp, failures = failed },
        }
    end

    core.log("action", ("[worldedit_agent] print_plan verified %d node write(s) | origin=%s min=%s max=%s"):format(
        #ops,
        core.pos_to_string and core.pos_to_string(origin) or "?",
        core.pos_to_string and core.pos_to_string(minp) or "?",
        core.pos_to_string and core.pos_to_string(maxp) or "?"
    ))

    return {
        ok = true,
        success = true,
        message = string.format("Printed %d nodes across %d material(s)", #ops, table_len(by_node)),
        data = { nodes = #ops, materials = by_node, origin = origin, min = minp, max = maxp },
    }
end

local function compat_set_node(pos, node_name)
    if type(pos) ~= "table" then
        return {ok=false, message="set_node: pos must be {x=..., y=..., z=...}"}
    end
    local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
    if not x or not y or not z then
        return {ok=false, message="set_node: pos requires numeric x/y/z"}
    end
    local node, err = resolve_node(tostring(node_name or "air"))
    if not node then return {ok=false, message="set_node: " .. err} end
    core.set_node({x=math.floor(x), y=math.floor(y), z=math.floor(z)}, {name=node})
    return {ok=true, message=string.format("Set node %s at (%d,%d,%d)", node, math.floor(x), math.floor(y), math.floor(z))}
end

local function compat_set_nodes(args)
    args = args or {}
    if type(args) ~= "table" then
        return {ok=false, message="set_nodes: args must be a table"}
    end
    local p1 = args.pos1 or args.p1 or args.from
    local p2 = args.pos2 or args.p2 or args.to
    if type(p1) ~= "table" or type(p2) ~= "table" then
        return {ok=false, message="set_nodes: pos1 and pos2 are required"}
    end
    local node, err = resolve_node(tostring(args.node or args.node_name or "air"))
    if not node then return {ok=false, message="set_nodes: " .. err} end
    local count = fill_box(
        {x=math.floor(tonumber(p1.x) or 0), y=math.floor(tonumber(p1.y) or 0), z=math.floor(tonumber(p1.z) or 0)},
        {x=math.floor(tonumber(p2.x) or 0), y=math.floor(tonumber(p2.y) or 0), z=math.floor(tonumber(p2.z) or 0)},
        node,
        args.hollow == true or args.hollow == "true"
    )
    return {ok=true, message=string.format("Set %d nodes to %s", count, node), data={nodes=count}}
end

local function compat_get_node(pos)
    if type(pos) ~= "table" then
        return {ok=false, success=false, message="get_node: pos must be {x=..., y=..., z=...}"}
    end
    local x, y, z = tonumber(pos.x), tonumber(pos.y), tonumber(pos.z)
    if not x or not y or not z then
        return {ok=false, success=false, message="get_node: pos requires numeric x/y/z"}
    end
    local ipos = {x=math.floor(x), y=math.floor(y), z=math.floor(z)}
    local node = core.get_node(ipos)
    return {
        ok=true,
        success=true,
        message=string.format("Node at (%d,%d,%d): %s", ipos.x, ipos.y, ipos.z, node and node.name or "unknown"),
        data={pos=ipos, node=node},
    }
end

-- ===========================================================================
-- Tool runner
-- ===========================================================================

local REMOVED_SEMANTIC_BUILDERS = {
    build_platform = true,
    build_hut = true,
    build_house = true,
    build_tower = true,
}

local function run_tool(tool_name, args, player_name)
    tool_name = tostring(tool_name or "")

    -- Handle common swap: run('tool', 'player', {args})
    if type(player_name) == "table" and type(args) == "string" then
        local temp = args
        args = player_name
        player_name = temp
    end

    if type(args) ~= "table" then args = {} end

    -- Try to find player_name if missing
    if not player_name or player_name == "" then
        player_name = rawget(_G, "player_name")
    end

    if type(player_name) ~= "string" or player_name == "" then
        return {ok=false, message="worldedit_agent: missing player_name; call run('tool_name', {args...}, player_name)"}
    end

    -- Native node-printer tools. These do not require WorldEdit.
    if tool_name == "print_plan" or tool_name == "print_nodes" then
        return print_plan(args, player_name)
    elseif tool_name == "preview_plan" then
        args.dry_run = true
        return print_plan(args, player_name)
    elseif tool_name == "get_node" then
        return compat_get_node(args.pos or args)
    end

    if REMOVED_SEMANTIC_BUILDERS[tool_name] or tool_name == "build_structure" then
        return {ok=false, message="unknown tool: " .. tostring(tool_name)}
    end

    if not worldedit then
        return {ok=false, message="worldedit_agent: WorldEdit bridge is not loaded; use print_plan"}
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
    -- Native node-printer tools: preferred for model-generated structures
    { name="print_plan", description="Validate and place native node geometry primitives. Coordinates are relative to player position unless absolute=true.",
      parameters={nodes="array optional", lines="array optional", planes="array optional", volumes="array optional", origin="player|string|pos optional", absolute="boolean optional", max_nodes="integer optional"} },
    { name="preview_plan", description="Validate a print_plan without writing nodes.",
      parameters={nodes="array optional", lines="array optional", planes="array optional", volumes="array optional", origin="player|string|pos optional", absolute="boolean optional", max_nodes="integer optional"} },
    { name="get_node", description="Inspect one node at an explicit position.",
      parameters={pos="pos table, or x/y/z numeric fields"} },
    -- Experimental WorldEdit bridge compatibility
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
        print_plan = function(args, player_name)
            return print_plan(args or {}, player_name)
        end,
        preview_plan = function(args, player_name)
            args = args or {}
            args.dry_run = true
            return print_plan(args, player_name)
        end,
        set_node = function(pos, node_name)
            -- Compatibility for common model mistakes. Prefer run('cube'...) or
            -- run('set_region'...) for bulk work.
            return compat_set_node(pos, node_name)
        end,
        set_nodes = function(args)
            -- Compatibility for common model mistakes. Prefer
            -- run('set_region', {node=...}, player_name) after setting pos1/pos2.
            return compat_set_nodes(args or {})
        end,
        get_node = function(pos)
            return compat_get_node(pos)
        end,
        get_context = get_context,
        snapshot = snapshot_hook,
        restore = restore_hook,
    }


    if root.context and type(root.context.register_section) == "function" then
        root.context.register_section({
            id = "skills.worldedit_agent",
            title = "Node Printer skill manual",
            summary = "Native node/line/plane/volume geometry printing plus WorldEdit bridge compatibility.",
            tags = {"skill", "worldedit", "node_printer", "building", "nodes", "regions"},
            required_priv = "llm_agent",
            provider = function(player_name)
                return table.concat({
                    get_context(player_name),
                    "",
                    "Node Printer builds generated structures from explicit Lua geometry plans.",
                    "Generated structures must be composed from nodes, lines, planes, and volumes by the agent.",
                    "Default placement is player-anchored: omit origin or set origin=\"player\" to build at the current player position.",
                    "Use absolute=true only when every coordinate is an intentional world coordinate.",
                    "Do not set origin={x=0,y=0,z=0} for player-local builds; that means world origin and is rejected unless absolute=true.",
                    "A single solid volume is only a literal block, not a house, tower, castle or other named building.",
                    "For named buildings, compose visible parts: floor, separate walls or hollow shell, door/window air nodes, roof, and requested features.",
                    "For castles, include at least walls, an entrance, and either four corner towers or battlements.",
                    "Keep lua_action blocks concise; use small helper functions or loops to build repeated plan entries instead of long comments or huge literal tables.",
                    "",
                    "Canonical invocation:",
                    "  llm_connect.skills.worldedit_agent.run(\"<tool>\", args, player_name)",
                    "Do not call direct helpers such as llm_connect.skills.worldedit_agent.print_plan(...). Do not use nested :run() calls.",
                    "Do not omit player_name. Do not pass player_name as the first argument.",
                    "",
                    "Stable construction tools:",
                    "  \"preview_plan\": validate a plan without writing nodes.",
                    "  \"print_plan\": execute an explicit node/line/plane/volume plan and verify writes by reading nodes back.",
                    "  \"get_node\": read one node at {pos={x=...,y=...,z=...}}.",
                    "",
                    "For natural-language construction requests:",
                    "  1. Translate the requested object into explicit nodes, lines, planes and volumes.",
                    "  2. Call preview_plan first.",
                    "  3. Check preview.ok and inspect preview.data.origin/min/max to confirm the structure is anchored near the player.",
                    "  4. If preview succeeds and execution is still required, return done=false and continue=true so the next agent iteration can perform print_plan.",
                    "  5. Do not search for semantic builders such as build_house, build_hut, build_tower or build_platform; they are intentionally not part of this skill.",
                    "  6. Never satisfy a named building request with one solid volume; if preview/print rejects this, rewrite the plan with multiple parts.",
                    "  7. Keep the generated Lua short and complete; one closed lua_action block is better than a verbose unfinished plan.",
                    "",
                    "Plan schema:",
                    "  {",
                    "    origin = \"player\", -- optional default; omit for player-local builds",
                    "    absolute = false,   -- optional default; true means world coordinates",
                    "    nodes = {",
                    "      {at={x=0,y=1,z=0}, node=\"default:glass\"}",
                    "    },",
                    "    lines = {",
                    "      {from={x=-3,y=1,z=-3}, dir={x=1,y=0,z=0}, length=7, node=\"default:wood\"}",
                    "    },",
                    "    planes = {",
                    "      {from={x=-3,y=0,z=-3}, dir1={x=1,y=0,z=0}, dir2={x=0,y=0,z=1}, size1=7, size2=7, node=\"default:stone\"}",
                    "    },",
                    "    volumes = {",
                    "      {from={x=-3,y=1,z=-3}, dir1={x=1,y=0,z=0}, dir2={x=0,y=1,z=0}, dir3={x=0,y=0,z=1}, size1=7, size2=4, size3=7, node=\"default:wood\", hollow=true}",
                    "    },",
                    "    max_nodes = 20000",
                    "  }",
                    "",
                    "Primitive meanings:",
                    "  node: one position (0D).",
                    "  line: from + dir + length (1D).",
                    "  plane: from + dir1/dir2 + size1/size2 (2D).",
                    "  volume: from + dir1/dir2/dir3 + size1/size2/size3 (3D).",
                    "Direction vectors make verticality explicit; for vertical walls use one direction with y=1.",
                    "For simple player-local buildings, omit origin entirely and use relative coordinates around {x=0,y=0,z=0}.",
                    "A single solid volume larger than 64 nodes is rejected unless allow_solid_volume=true is set for an explicit literal cube/block request.",
                    "",
                    "Primitive plan-composition example:",
                    "  local plan = {",
                    "      planes = {",
                    "          {from={x=-3,y=0,z=-3}, dir1={x=1,y=0,z=0}, dir2={x=0,y=0,z=1}, size1=7, size2=7, node=\"default:stone\"},",
                    "          {from={x=-4,y=5,z=-4}, dir1={x=1,y=0,z=0}, dir2={x=0,y=0,z=1}, size1=9, size2=9, node=\"default:cobble\"},",
                    "      },",
                    "      volumes = {",
                    "          {from={x=-3,y=1,z=-3}, dir1={x=1,y=0,z=0}, dir2={x=0,y=1,z=0}, dir3={x=0,y=0,z=1}, size1=7, size2=4, size3=7, node=\"default:wood\", hollow=true},",
                    "      },",
                    "      nodes = {",
                    "          {at={x=0,  y=1, z=-3}, node=\"air\"},",
                    "          {at={x=0,  y=2, z=-3}, node=\"air\"},",
                    "          {at={x=-2, y=2, z=-3}, node=\"default:glass\"},",
                    "          {at={x=2,  y=2, z=-3}, node=\"default:glass\"},",
                    "      },",
                    "  }",
                    "",
                    "  local preview = llm_connect.skills.worldedit_agent.run(\"preview_plan\", plan, player_name)",
                    "  if not (preview and preview.ok) then",
                    "      return {",
                    "          done = false,",
                    "          continue = true,",
                    "          message = preview and preview.message or \"Node Printer preview failed\"",
                    "      }",
                    "  end",
                    "",
                    "  return {",
                    "      done = false,",
                    "      continue = true,",
                    "      message = \"Primitive construction plan validated; execute it with print_plan in the next step.\"",
                    "  }",
                    "",
                    "On the following iteration, execute the same explicit plan with print_plan after checking that execution is still required.",
                    "print_plan returns data.origin/min/max and fails with ok=false if node writes cannot be verified.",
                    "",
                    "Simple castle composition pattern:",
                    "  Use a floor plane, four wall volumes or planes, one or more air nodes for an entrance, and four hollow corner tower volumes.",
                    "  Add battlements with short lines or nodes along the top edges.",
                    "  Keep each part explicit; do not use one 5x5x5 solid cobble volume and call it a castle.",
                    "",
                    "WorldEdit and WorldEditAdditions bridge tools are experimental/compatibility paths and are intentionally not part of this stable agent-facing surface.",
                    "print_nodes may exist as a compatibility alias for print_plan, but print_plan is canonical.",
                    "Use max_nodes to cap write volume for large generated plans.",
                    "",
                    "Safe common materials:",
                    "  default:stone, default:cobble, default:wood, default:tree, default:glass, default:brick, default:dirt_with_grass, air",
                    "Node resolver accepts common aliases like default:oak_log -> default:tree and default:oak_planks -> default:wood.",
                    "Unknown nodes are rejected before WorldEdit to prevent runtime crashes.",
                    "For unfamiliar materials, query llm_connect.context.get_section('luanti.registered_nodes.preview', {query='wood'}).",
                }, "\n")
            end,
        })
        if type(root.context.register_aliases) == "function" then
            root.context.register_aliases({
                node_printer = "skills.worldedit_agent",
                building = "skills.worldedit_agent",
                worldedit = "skills.worldedit_agent",
                worldedit_agent = "skills.worldedit_agent",
            })
        end
    end


    if not (root.registry and type(root.registry.register_skill) == "function") then
        core.log("warning", "[worldedit_agent] registry unavailable; skill API installed but not registered")
        return root.skills.worldedit_agent
    end

    root.registry.register_skill({
        id          = "worldedit_agent",
        label       = "Node Printer",
        version     = "1.3.0-dev",
        description = "Lua-first node printer for explicit primitive structure plans with optional WorldEdit bridge compatibility.",
        required_priv = "llm_agent",
        default_enabled = false,
        available = function()
            return type(core.set_node) == "function" and type(core.registered_nodes) == "table"
        end,
        context_section = "skills.worldedit_agent",
        context_aliases = {"node_printer", "building", "worldedit", "worldedit_agent"},
        get_context = get_context,
        snapshot_hook = snapshot_hook,
        restore_hook  = restore_hook,
        tool_count = 3,
    })
end

do_register()

core.log("action", "[worldedit_agent] loaded")
