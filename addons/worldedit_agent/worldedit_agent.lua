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

local function resolve_node(node_str)
    if not node_str or node_str == "" then return nil, "node name is empty" end
    if node_str == "air" then return "air", nil end
    if core.registered_nodes[node_str] then return node_str, nil end
    local with_source = node_str .. "_source"
    if core.registered_nodes[with_source] then return with_source, nil end
    local base = node_str:gsub("_flowing$", "_source")
    if core.registered_nodes[base] then return base, nil end
    core.log("warning", ("[worldedit_agent] unknown node '%s' — passing through"):format(node_str))
    return node_str, nil
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
    if not worldedit then return "WorldEdit: not loaded" end

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
-- Dispatchers
-- ===========================================================================

local function dispatch(tool_name, args, player_name)
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
        local count = worldedit.set(p1, p2, node)
        return {ok=true, message=string.format("Set %d nodes to %s", count or 0, node), data={nodes=count}}

    elseif tool_name == "clear_region" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local count = worldedit.set(p1, p2, "air")
        return {ok=true, message=string.format("Cleared %d nodes", count or 0), data={nodes=count}}

    elseif tool_name == "replace" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local search,   e1 = resolve_node(tostring(args.search_node  or ""))
        local replace_, e2 = resolve_node(tostring(args.replace_node or "air"))
        if not search   then return {ok=false, message="replace: search: "  .. (e1 or "?")} end
        if not replace_ then return {ok=false, message="replace: replace: " .. (e2 or "?")} end
        local count = worldedit.replace(p1, p2, search, replace_)
        return {ok=true, message=string.format("Replaced %d nodes: %s → %s", count or 0, search, replace_)}

    elseif tool_name == "copy" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local axis   = tostring(args.axis or "y")
        local amount = tonumber(args.amount or 1)
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="copy: " .. aerr} end
        local count = worldedit.copy(p1, p2, axis, amount)
        return {ok=true, message=string.format("Copied %d nodes along %s by %d", count or 0, axis, amount)}

    elseif tool_name == "move" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local axis   = tostring(args.axis or "y")
        local amount = tonumber(args.amount or 1)
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="move: " .. aerr} end
        local count, newp1, newp2 = worldedit.move(p1, p2, axis, amount)
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
        local nodes = worldedit.stack(p1, p2, axis, count)
        return {ok=true, message=string.format("Stacked %d times along %s (%d nodes)", count, axis, nodes or 0)}

    elseif tool_name == "flip" then
        local p1, p2, err = require_selection(player_name)
        if err then return {ok=false, message=err} end
        local axis = tostring(args.axis or "y")
        local ok, aerr = validate_axis(axis)
        if not ok then return {ok=false, message="flip: " .. aerr} end
        local count = worldedit.flip(p1, p2, axis)
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
        local count, newp1, newp2 = worldedit.rotate(p1, p2, axis, angle)
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
        local count = worldedit.sphere(pos, radius, node, hollow)
        return {ok=true, message=string.format("Sphere r=%d %s at (%d,%d,%d): %d nodes",
            radius, node, pos.x, pos.y, pos.z, count or 0)}

    elseif tool_name == "dome" then
        local pos    = make_pos(args, player_name)
        local radius = tonumber(args.radius or 5)
        local node, nerr = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="dome: " .. nerr} end
        local hollow = args.hollow == true or args.hollow == "true"
        if radius < 1 or radius > 64 then return {ok=false, message="dome: radius must be 1–64"} end
        local count = worldedit.dome and worldedit.dome(pos, radius, node, hollow)
            or worldedit.sphere(pos, radius, node, hollow)  -- fallback if dome not available
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
        local count = worldedit.cylinder(pos, axis, length, r1, r2, node, hollow)
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
        local count = worldedit.pyramid(pos, axis, height, node, hollow)
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
        -- worldedit.cube may not exist in all versions — use set_region as fallback
        local count
        if worldedit.cube then
            count = worldedit.cube(pos, w, h, l, node, hollow)
        else
            local p1 = {x=pos.x, y=pos.y, z=pos.z}
            local p2 = {x=pos.x+w-1, y=pos.y+h-1, z=pos.z+l-1}
            count = worldedit.set(p1, p2, node)
        end
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
            return dispatch(tool_name, args or {}, player_name)
        end,
        get_context = get_context,
        snapshot = snapshot_hook,
        restore = restore_hook,
    }

    local api = {
        "Preferred call form: llm_connect.skills.worldedit_agent.run('tool_name', {arg=value}, player_name)",
        "Do not omit player_name. Do not pass player_name as the first argument.",
        "llm_connect.skills.worldedit_agent.run('set_pos1', {x=0,y=0,z=0}, player_name)",
        "llm_connect.skills.worldedit_agent.run('set_pos2', {x=10,y=10,z=10}, player_name)",
        "llm_connect.skills.worldedit_agent.run('set_region', {node='default:stone'}, player_name)",
        "llm_connect.skills.worldedit_agent.run('clear_region', {}, player_name)",
        "llm_connect.skills.worldedit_agent.run('cube', {width=5,height=3,length=5,node='default:stone',hollow=false}, player_name)",
        "llm_connect.skills.worldedit_agent.run('sphere', {radius=4,node='default:glass',hollow=true}, player_name)",
    }

    root.registry.register_skill({
        id          = "worldedit_agent",
        label       = "WorldEdit Agent",
        version     = "1.1.0-dev",
        description = "Lua-first WorldEdit bridge: selections, region operations, primitives and optional WEA tools.",
        required_priv = "llm_agent",
        default_enabled = false,
        available = function()
            return type(worldedit) == "table"
                and (type(worldedit.set) == "function"
                     or type(worldedit.set_node) == "function"
                     or next(worldedit) ~= nil)
        end,
        api = api,
        get_context = get_context,
        snapshot_hook = snapshot_hook,
        restore_hook  = restore_hook,
        tool_count = #TOOLS,
    })
end

do_register()

core.log("action", "[worldedit_agent] loaded")
