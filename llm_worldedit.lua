-- llm_worldedit.lua
-- LLM-Connect Agency Module: WorldEdit Bridge
-- v0.4.0 – Fixes: make_pos handles nested/string pos, resolve_node auto-corrects liquids,
--           loop prompt enforces upfront planning, cumulative step history passed to LLM
--
-- ARCHITECTURE:
--   Direct Lua wrapper around worldedit.* API (not chat command parsing).
--   The LLM receives a compact context and responds with a JSON tool_calls array.
--   Each tool call is validated and dispatched to the corresponding worldedit function.
--
-- SAFETY LIMITS (enforced per-call):
--   - Primitives: max radius 64, max dimension 128
--   - All region ops require explicit pos1+pos2
--   - Chain aborts on any hard error
--   - Snapshot taken before every chain → undo available
--
-- ROADMAP:
--   Phase 1 ✅ – Skeleton, context builder, pos1/pos2, WE toggle
--   Phase 2 ✅ – All dispatchers: set/replace/copy/move/stack/flip/rotate + primitives
--   Phase 3 ✅ – Snapshot before execution, M.undo(name) for rollback
--   Phase 4a  – Iterative feedback loop: LLM sees step results, re-plans
--   Phase 4b  – Macro mode: LLM builds complex structures over N iterations
--              with abort condition ("done" signal) and token budget guard
--   Phase 5   – WorldEditAdditions support (torus, erode, maze…)

local core = core
local M    = {}

-- Load system prompts from external file
local prompts_path = core.get_modpath("llm_connect") .. "/worldedit_system_prompts.lua"
local prompts_ok, WE_PROMPTS = pcall(dofile, prompts_path)
if not prompts_ok then
    core.log("error", "[llm_worldedit] Failed to load worldedit_system_prompts.lua: " .. tostring(WE_PROMPTS))
    WE_PROMPTS = nil
end

-- ============================================================
-- Availability check

local function wea_enabled()
    if not core.settings:get_bool("llm_worldedit_additions", true) then return false end
    return type(worldeditadditions) == "table"
        and type(worldeditadditions.torus) == "function"
end

-- ============================================================

function M.is_available()
    if type(worldedit) ~= "table" then return false end
    -- Extended check – different WE versions use different function names
    return type(worldedit.set) == "function"
        or type(worldedit.set_node) == "function"
        or type(worldedit.manip_helpers) == "table"
        or next(worldedit) ~= nil  -- Fallback: Tabelle nicht leer
end

-- ============================================================
-- Snapshot / Undo (Phase 3)
-- Serializes the bounding box of pos1..pos2 before any chain
-- runs. M.undo(name) restores it. One snapshot per player
-- (last-write-wins — sufficient for agency use).
-- ============================================================

local snapshots = {}  -- [player_name] = {p1, p2, data}

local function take_snapshot(name)
    if not M.is_available() then return false end
    local p1 = worldedit.pos1 and worldedit.pos1[name]
    local p2 = worldedit.pos2 and worldedit.pos2[name]
    if not p1 or not p2 then return false end  -- nothing to snapshot yet

    -- worldedit.serialize returns a string representation of the region
    local ok, data = pcall(worldedit.serialize, p1, p2)
    if not ok or not data then return false end

    snapshots[name] = {
        p1   = {x=p1.x, y=p1.y, z=p1.z},
        p2   = {x=p2.x, y=p2.y, z=p2.z},
        data = data,
    }
    return true
end

-- Public: restore last snapshot for player. Returns {ok, message}.
function M.undo(name)
    if not M.is_available() then
        return {ok=false, message="WorldEdit not available"}
    end
    local snap = snapshots[name]
    if not snap then
        return {ok=false, message="No snapshot available for " .. name}
    end
    local ok, count = pcall(worldedit.deserialize, snap.p1, snap.data)
    if ok then
        -- Restore selection markers
        worldedit.pos1[name] = snap.p1
        worldedit.pos2[name] = snap.p2
        if worldedit.mark_pos1 then worldedit.mark_pos1(name) end
        if worldedit.mark_pos2 then worldedit.mark_pos2(name) end
        snapshots[name] = nil
        return {ok=true, message=string.format("Restored %d nodes from snapshot", count or 0)}
    else
        return {ok=false, message="Deserialize failed: " .. tostring(count)}
    end
end

-- Cleanup snapshots on leave
core.register_on_leaveplayer(function(player)
    snapshots[player:get_player_name()] = nil
end)

-- ============================================================
-- Context builder
-- Returns a compact but rich string that the LLM gets instead
-- of the generic game context when WorldEdit mode is active.
-- Goal: minimal tokens, maximum actionability.
-- ============================================================

-- Samples a coarse NxNxN grid of node names around a position.
-- Returns a compact summary string to give the LLM spatial awareness.
-- N=5 → 5x5x5 = 125 nodes, sampled at step=2 → ~32 unique checks
local function sample_environment(pos, radius, step)
    radius = radius or 6
    step   = step   or 3
    local counts = {}
    local total  = 0

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
                    total = total + 1
                end
            end
        end
    end

    if total == 0 then return "Surroundings: mostly air" end

    -- Sort by frequency, take top 8
    local sorted = {}
    for name, count in pairs(counts) do
        table.insert(sorted, {name=name, count=count})
    end
    table.sort(sorted, function(a,b) return a.count > b.count end)

    local parts = {}
    for i = 1, math.min(8, #sorted) do
        parts[i] = sorted[i].name .. "×" .. sorted[i].count
    end
    return "Nearby nodes (sampled r=" .. radius .. "): " .. table.concat(parts, ", ")
end

function M.get_context(player_name)
    if not M.is_available() then
        return "WorldEdit: NOT LOADED"
    end

    local player = core.get_player_by_name(player_name)
    if not player then return "Player not found" end

    local pos = player:get_pos()
    local px, py, pz = math.floor(pos.x), math.floor(pos.y), math.floor(pos.z)

    -- Current WE selection for this player
    local p1 = worldedit.pos1 and worldedit.pos1[player_name]
    local p2 = worldedit.pos2 and worldedit.pos2[player_name]
    local sel_str
    if p1 and p2 then
        sel_str = string.format("pos1=(%d,%d,%d) pos2=(%d,%d,%d) vol=%d",
            math.floor(p1.x), math.floor(p1.y), math.floor(p1.z),
            math.floor(p2.x), math.floor(p2.y), math.floor(p2.z),
            worldedit.volume(p1, p2))
    elseif p1 then
        sel_str = string.format("pos1=(%d,%d,%d) pos2=not set",
            math.floor(p1.x), math.floor(p1.y), math.floor(p1.z))
    else
        sel_str = "no selection"
    end

    -- Coarse environment scan
    local env = sample_environment(pos)

    -- WorldEdit API capability list (static, no token bloat)
    -- This tells the LLM WHAT it can call. Details are in the tool schema.
    local capabilities = table.concat({
        "set_region(pos1,pos2,node)",
        "replace(pos1,pos2,search,replace)",
        "copy(pos1,pos2,axis,amount)",
        "move(pos1,pos2,axis,amount)",
        "stack(pos1,pos2,axis,count)",
        "flip(pos1,pos2,axis)",
        "rotate(pos1,pos2,angle)",
        "sphere(pos,radius,node,hollow)",
        "dome(pos,radius,node,hollow)",
        "cylinder(pos,axis,length,radius1,radius2,node,hollow)",
        "pyramid(pos,axis,height,node,hollow)",
        "cube(pos,width,height,length,node,hollow)",
        "set_pos1(pos)",
        "set_pos2(pos)",
        "get_selection()",
        "clear_region(pos1,pos2)",
    }, " | ")

    local lines = {
        "=== WorldEdit Agency Mode ===",
        string.format("Player: %s  Pos: (%d,%d,%d)", player_name, px, py, pz),
        "Selection: " .. sel_str,
        env,
        "",
        "Available tools: " .. capabilities,
        "",
        "RULES:",
        "1. Always think about coordinates relative to the player position.",
        "2. Set pos1 and pos2 BEFORE calling region operations.",
        "3. Use 'air' as node name to clear/delete nodes.",
        "4. Prefer relative offsets from player pos for natural language requests.",
        "5. Return a JSON tool_calls array. Each call: {tool, args}.",
        "6. If the request is ambiguous, ask for clarification instead of guessing.",
        "=== END CONTEXT ===",
    }
    return table.concat(lines, "\n")
end

-- ============================================================
-- System prompt for WorldEdit agency mode
-- ============================================================


-- ============================================================
-- Tool schema (for llm_api tool_calls / function calling)
-- Phase 2 will use this to validate and dispatch.
-- Currently used only to document; real dispatch is in Phase 2.
-- ============================================================

M.TOOL_SCHEMA = {
    -- Region selection
    {
        name = "set_pos1",
        description = "Set WorldEdit position 1 to absolute world coordinates.",
        parameters = {x="integer", y="integer", z="integer"}
    },
    {
        name = "set_pos2",
        description = "Set WorldEdit position 2 to absolute world coordinates.",
        parameters = {x="integer", y="integer", z="integer"}
    },
    {
        name = "get_selection",
        description = "Return current pos1, pos2 and volume for the player.",
        parameters = {}
    },
    -- Region manipulation
    {
        name = "set_region",
        description = "Fill the current selection with node. Use 'air' to clear.",
        parameters = {node="string"}
    },
    {
        name = "clear_region",
        description = "Fill the current selection with air (delete nodes).",
        parameters = {}
    },
    {
        name = "replace",
        description = "Replace all instances of search_node with replace_node in selection.",
        parameters = {search_node="string", replace_node="string"}
    },
    {
        name = "copy",
        description = "Copy the selection along an axis by amount nodes.",
        parameters = {axis="string (x|y|z)", amount="integer"}
    },
    {
        name = "move",
        description = "Move the selection along an axis by amount nodes.",
        parameters = {axis="string (x|y|z)", amount="integer"}
    },
    {
        name = "stack",
        description = "Stack (duplicate) the selection along an axis count times.",
        parameters = {axis="string (x|y|z)", count="integer"}
    },
    {
        name = "flip",
        description = "Flip the selection along the given axis.",
        parameters = {axis="string (x|y|z)"}
    },
    {
        name = "rotate",
        description = "Rotate the selection by angle degrees (90/180/270) around Y axis.",
        parameters = {angle="integer (90|180|270)"}
    },
    -- Primitives (absolute pos, no selection needed)
    {
        name = "sphere",
        description = "Generate a sphere at pos with given radius and node.",
        parameters = {x="integer", y="integer", z="integer",
                      radius="integer", node="string", hollow="boolean (optional)"}
    },
    {
        name = "dome",
        description = "Generate a dome (half-sphere) at pos.",
        parameters = {x="integer", y="integer", z="integer",
                      radius="integer", node="string", hollow="boolean (optional)"}
    },
    {
        name = "cylinder",
        description = "Generate a cylinder at pos along axis.",
        parameters = {x="integer", y="integer", z="integer",
                      axis="string (x|y|z)", length="integer",
                      radius="integer", node="string", hollow="boolean (optional)"}
    },
    {
        name = "pyramid",
        description = "Generate a pyramid at pos along axis.",
        parameters = {x="integer", y="integer", z="integer",
                      axis="string (x|y|z)", height="integer",
                      node="string", hollow="boolean (optional)"}
    },
    {
        name = "cube",
        description = "Generate a cube/box centered at pos.",
        parameters = {x="integer", y="integer", z="integer",
                      width="integer", height="integer", length="integer",
                      node="string", hollow="boolean (optional)"}
    },
}

-- ============================================================
-- Tool dispatcher – PHASE 2 STUB
-- Currently: validates structure, logs, returns not_implemented.
-- Phase 2: actually calls worldedit.* and reports results.
-- ============================================================

-- Resolves pos from args — handles both flat {x,y,z} and nested {pos={x,y,z}}
-- Also falls back to player's pos1 if args.pos == "pos1" etc.
local function make_pos(args, player_name)
    -- Nested: {"pos": {"x":1,"y":2,"z":3}}
    if type(args.pos) == "table" then
        return {
            x = tonumber(args.pos.x) or 0,
            y = tonumber(args.pos.y) or 0,
            z = tonumber(args.pos.z) or 0,
        }
    end
    -- String alias: "pos1" or "pos2" → use current selection
    if type(args.pos) == "string" then
        if player_name then
            if args.pos == "pos1" and worldedit.pos1[player_name] then
                return worldedit.pos1[player_name]
            end
            if args.pos == "pos2" and worldedit.pos2[player_name] then
                return worldedit.pos2[player_name]
            end
        end
    end
    -- Flat: {x=1, y=2, z=3}
    return {
        x = tonumber(args.x) or 0,
        y = tonumber(args.y) or 0,
        z = tonumber(args.z) or 0,
    }
end

-- Validates a node name — returns corrected name or nil + error message.
-- Tries common suffixes (_source, _flowing) if the base name is unknown.
local function resolve_node(node_str)
    if not node_str or node_str == "" then
        return nil, "node name is empty"
    end
    if node_str == "air" then return "air", nil end
    if core.registered_nodes[node_str] then return node_str, nil end
    -- Try _source suffix (liquids)
    local with_source = node_str .. "_source"
    if core.registered_nodes[with_source] then
        return with_source, nil
    end
    -- Try stripping _flowing
    local base = node_str:gsub("_flowing$", "_source")
    if core.registered_nodes[base] then
        return base, nil
    end
    -- Unknown but pass through — worldedit will handle it
    core.log("warning", ("[llm_worldedit] unknown node '%s' – passing through"):format(node_str))
    return node_str, nil
end

-- Map tool names → executor functions
-- Each returns {ok=bool, message=string, nodes_affected=int|nil}
local DISPATCHERS = {

    set_pos1 = function(name, args)
        local pos = make_pos(args)
        worldedit.pos1[name] = pos
        if worldedit.mark_pos1 then worldedit.mark_pos1(name) end
        return {ok=true, message=string.format("pos1 set to (%d,%d,%d)", pos.x, pos.y, pos.z)}
    end,

    set_pos2 = function(name, args)
        local pos = make_pos(args)
        worldedit.pos2[name] = pos
        if worldedit.mark_pos2 then worldedit.mark_pos2(name) end
        return {ok=true, message=string.format("pos2 set to (%d,%d,%d)", pos.x, pos.y, pos.z)}
    end,

    get_selection = function(name, _args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=true, message="No selection set."}
        end
        return {ok=true, message=string.format(
            "pos1=(%d,%d,%d) pos2=(%d,%d,%d) vol=%d",
            p1.x,p1.y,p1.z, p2.x,p2.y,p2.z,
            worldedit.volume(p1,p2)
        )}
    end,

    -- ============================================================
    -- Region operations (require pos1 + pos2 to be set first)
    -- ============================================================

    set_region = function(name, args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=false, message="No selection: use set_pos1/set_pos2 first"}
        end
        local node, err = resolve_node(tostring(args.node or "air"))
        if not node then return {ok=false, message="set_region: " .. err} end
        local count = worldedit.set(p1, p2, node)
        return {ok=true, message=string.format("Set %d nodes to %s", count or 0, node), nodes=count}
    end,

    clear_region = function(name, args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=false, message="No selection: use set_pos1/set_pos2 first"}
        end
        local count = worldedit.set(p1, p2, "air")
        return {ok=true, message=string.format("Cleared %d nodes", count or 0), nodes=count}
    end,

    replace = function(name, args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=false, message="No selection: use set_pos1/set_pos2 first"}
        end
        local search,  e1 = resolve_node(tostring(args.search_node  or ""))
        local replace_, e2 = resolve_node(tostring(args.replace_node or "air"))
        if not search  then return {ok=false, message="replace: search_node: "  .. (e1 or "?")} end
        if not replace_ then return {ok=false, message="replace: replace_node: " .. (e2 or "?")} end
        local count = worldedit.replace(p1, p2, search, replace_)
        return {ok=true,
            message=string.format("Replaced %d nodes: %s → %s", count or 0, search, replace_),
            nodes=count}
    end,

    -- ── Transforms (operate on current selection, move markers too) ──────────

    copy = function(name, args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=false, message="No selection: use set_pos1/set_pos2 first"}
        end
        local axis   = tostring(args.axis   or "y")
        local amount = tonumber(args.amount or 1)
        if not ({x=1,y=1,z=1})[axis] then
            return {ok=false, message="copy: axis must be x, y or z"}
        end
        local count = worldedit.copy(p1, p2, axis, amount)
        return {ok=true,
            message=string.format("Copied %d nodes along %s by %d", count or 0, axis, amount),
            nodes=count}
    end,

    move = function(name, args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=false, message="No selection: use set_pos1/set_pos2 first"}
        end
        local axis   = tostring(args.axis   or "y")
        local amount = tonumber(args.amount or 1)
        if not ({x=1,y=1,z=1})[axis] then
            return {ok=false, message="move: axis must be x, y or z"}
        end
        -- worldedit.move also updates pos1/pos2 in place
        local count, newp1, newp2 = worldedit.move(p1, p2, axis, amount)
        if newp1 then worldedit.pos1[name] = newp1 end
        if newp2 then worldedit.pos2[name] = newp2 end
        return {ok=true,
            message=string.format("Moved %d nodes along %s by %d", count or 0, axis, amount),
            nodes=count}
    end,

    stack = function(name, args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=false, message="No selection: use set_pos1/set_pos2 first"}
        end
        local axis  = tostring(args.axis  or "y")
        local count = tonumber(args.count or 1)
        if not ({x=1,y=1,z=1})[axis] then
            return {ok=false, message="stack: axis must be x, y or z"}
        end
        local nodes = worldedit.stack(p1, p2, axis, count)
        return {ok=true,
            message=string.format("Stacked region %d times along %s (%d nodes)", count, axis, nodes or 0),
            nodes=nodes}
    end,

    flip = function(name, args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=false, message="No selection: use set_pos1/set_pos2 first"}
        end
        local axis = tostring(args.axis or "y")
        if not ({x=1,y=1,z=1})[axis] then
            return {ok=false, message="flip: axis must be x, y or z"}
        end
        local count = worldedit.flip(p1, p2, axis)
        return {ok=true,
            message=string.format("Flipped region along %s (%d nodes)", axis, count or 0),
            nodes=count}
    end,

    rotate = function(name, args)
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then
            return {ok=false, message="No selection: use set_pos1/set_pos2 first"}
        end
        local angle = tonumber(args.angle or 90)
        -- worldedit.rotate(pos1, pos2, axis, angle) – axis is always "y" for our schema
        local axis = tostring(args.axis or "y")
        if not ({x=1,y=1,z=1})[axis] then
            return {ok=false, message="rotate: axis must be x, y or z"}
        end
        if not ({[90]=1,[180]=1,[270]=1,[-90]=1})[angle] then
            return {ok=false, message="rotate: angle must be 90, 180, 270 or -90"}
        end
        local count, newp1, newp2 = worldedit.rotate(p1, p2, axis, angle)
        if newp1 then worldedit.pos1[name] = newp1 end
        if newp2 then worldedit.pos2[name] = newp2 end
        return {ok=true,
            message=string.format("Rotated %d nodes by %d° around %s", count or 0, angle, axis),
            nodes=count}
    end,

    -- ── Primitives (standalone, no selection needed) ─────────────────────────
    -- All take absolute world coordinates from args.

    sphere = function(name, args)
        local pos    = make_pos(args, name)
        local radius = tonumber(args.radius or 5)
        local node,err = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="sphere: " .. err} end
        local hollow = args.hollow == true or args.hollow == "true"
        if radius < 1 or radius > 64 then
            return {ok=false, message="sphere: radius must be 1–64"}
        end
        local count = worldedit.sphere(pos, radius, node, hollow)
        return {ok=true,
            message=string.format("Sphere r=%d %s at (%d,%d,%d): %d nodes",
                radius, node, pos.x, pos.y, pos.z, count or 0),
            nodes=count}
    end,

    dome = function(name, args)
        local pos    = make_pos(args, name)
        local radius = tonumber(args.radius or 5)
        local node,err = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="dome: " .. err} end
        local hollow = args.hollow == true or args.hollow == "true"
        if radius < 1 or radius > 64 then
            return {ok=false, message="dome: radius must be 1–64"}
        end
        local count = worldedit.dome(pos, radius, node, hollow)
        return {ok=true,
            message=string.format("Dome r=%d %s at (%d,%d,%d): %d nodes",
                radius, node, pos.x, pos.y, pos.z, count or 0),
            nodes=count}
    end,

    cylinder = function(name, args)
        local pos    = make_pos(args, name)
        local axis   = tostring(args.axis   or "y")
        local length = tonumber(args.length or 5)
        local r1     = tonumber(args.radius or args.radius1 or 3)
        local r2     = tonumber(args.radius2 or r1)
        local node,err = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="cylinder: " .. err} end
        local hollow = args.hollow == true or args.hollow == "true"
        if not ({x=1,y=1,z=1})[axis] then
            return {ok=false, message="cylinder: axis must be x, y or z"}
        end
        if length < 1 or length > 128 then
            return {ok=false, message="cylinder: length must be 1–128"}
        end
        local count = worldedit.cylinder(pos, axis, length, r1, r2, node, hollow)
        return {ok=true,
            message=string.format("Cylinder axis=%s len=%d r=%d %s at (%d,%d,%d): %d nodes",
                axis, length, r1, node, pos.x, pos.y, pos.z, count or 0),
            nodes=count}
    end,

    pyramid = function(name, args)
        local pos    = make_pos(args, name)
        local axis   = tostring(args.axis   or "y")
        local height = tonumber(args.height or 5)
        local node,err = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="pyramid: " .. err} end
        local hollow = args.hollow == true or args.hollow == "true"
        if not ({x=1,y=1,z=1})[axis] then
            return {ok=false, message="pyramid: axis must be x, y or z"}
        end
        if height < 1 or height > 64 then
            return {ok=false, message="pyramid: height must be 1–64"}
        end
        local count = worldedit.pyramid(pos, axis, height, node, hollow)
        return {ok=true,
            message=string.format("Pyramid axis=%s h=%d %s at (%d,%d,%d): %d nodes",
                axis, height, node, pos.x, pos.y, pos.z, count or 0),
            nodes=count}
    end,

    cube = function(name, args)
        local pos  = make_pos(args, name)
        local w    = tonumber(args.width  or args.w or 5)
        local h    = tonumber(args.height or args.h or 5)
        local l    = tonumber(args.length or args.l or 5)
        local node,err = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="cube: " .. err} end
        local hollow = args.hollow == true or args.hollow == "true"
        if w < 1 or h < 1 or l < 1 or w > 128 or h > 128 or l > 128 then
            return {ok=false, message="cube: dimensions must be 1–128"}
        end
        local count = worldedit.cube(pos, w, h, l, node, hollow)
        return {ok=true,
            message=string.format("Cube %dx%dx%d %s at (%d,%d,%d): %d nodes",
                w, h, l, node, pos.x, pos.y, pos.z, count or 0),
            nodes=count}
    end,
}

-- Executes a list of tool calls (from LLM JSON response).
-- Returns a results table: { {tool, ok, message}, ... }
function M.execute_tool_calls(player_name, tool_calls)
    if not M.is_available() then
        return {{tool="*", ok=false, message="WorldEdit not available"}}
    end

    -- Snapshot current region before any changes (Phase 3)
    -- Best-effort: if no selection yet, snapshot is skipped silently.
    take_snapshot(player_name)

    local results = {}
    for i, call in ipairs(tool_calls) do
        local tool_name = call.tool
        local args      = call.args or {}
        -- Check WEA dispatchers first if WEA is enabled
        local dispatcher = DISPATCHERS[tool_name]
            or (M.wea_dispatchers and M.wea_dispatchers[tool_name])

        if not dispatcher then
            table.insert(results, {
                tool    = tool_name,
                ok      = false,
                message = "Unknown tool: " .. tostring(tool_name)
            })
        else
            local ok, res = pcall(dispatcher, player_name, args)
            if ok then
                table.insert(results, {tool=tool_name, ok=res.ok, message=res.message})
            else
                table.insert(results, {
                    tool    = tool_name,
                    ok      = false,
                    message = "Dispatcher error: " .. tostring(res)
                })
            end
        end

        -- Abort chain on hard errors (skip non-fatal informational results)
        if not results[#results].ok then
            table.insert(results, {tool="*", ok=false,
                message="Chain aborted at step " .. i .. "."})
            break
        end
    end
    return results
end

-- ============================================================
-- Iterative Macro Loop (Phase 4b)
--
-- M.run_loop(player_name, goal, options, callback)
--
-- How it works:
--   1. Send goal + full context to LLM
--   2. LLM responds with {plan, tool_calls, done, reason}
--      - done=true  → LLM signals it's finished
--      - done=false → execute tool_calls, update context, iterate
--   3. After executing, rebuild context (new pos, new env scan)
--      and send the step results back to LLM as the next user turn
--   4. Repeat until: done=true, max_iterations reached, or hard error
--
-- Token budget strategy:
--   Each iteration gets a fresh context (NOT the full history).
--   Only the goal + last step results are sent. This keeps
--   token usage bounded at O(1) per step rather than O(n).
--
-- options:
--   max_iterations  int     Max loop iterations (default: 6)
--   timeout         int     Per-request timeout in seconds (default: 90)
--   on_step         func    Called after each step: on_step(i, plan, results)
--                           Use this to stream progress to the GUI.
-- ============================================================

-- Extended system prompt for loop mode — tells the LLM about the done signal

function M.run_loop(player_name, goal, options, callback)
    if not M.is_available() then
        callback({ok=false, error="WorldEdit not available"})
        return
    end

    local llm_api = _G.llm_api
    if not llm_api then
        callback({ok=false, error="llm_api not available"})
        return
    end

    options = options or {}
    local cfg       = _G.llm_api and _G.llm_api.config or {}
    local max_iter  = options.max_iterations or cfg.we_max_iterations or 6
    local timeout   = options.timeout        or (_G.llm_api and _G.llm_api.get_timeout("we")) or 90
    local on_step   = options.on_step        -- optional progress callback

    local iteration    = 0
    local all_results  = {}
    local step_history = {}   -- compact log of all steps so far

    local function make_user_msg()
        if iteration == 1 then
            return "Goal: " .. goal
        end
        -- Compact history: just plan + ok/fail per step, not full node counts
        local hist_lines = {"Goal: " .. goal, "", "Completed steps so far:"}
        for i, s in ipairs(step_history) do
            local ok_count  = 0
            local err_count = 0
            for _, r in ipairs(s.results or {}) do
                if r.ok then ok_count = ok_count + 1 else err_count = err_count + 1 end
            end
            table.insert(hist_lines, string.format("  Step %d: %s  [✓%d ✗%d]",
                i, s.plan, ok_count, err_count))
        end
        table.insert(hist_lines, "")
        table.insert(hist_lines, "Continue with the next step of your plan. Set done=true when finished.")
        return table.concat(hist_lines, "\n")
    end

    local function do_iteration()
        iteration = iteration + 1

        if iteration > max_iter then
            callback({ok=true, finished=false,
                reason="Reached max iterations (" .. max_iter .. ")",
                steps=all_results})
            return
        end

        local context  = M.get_context(player_name)
        local messages = {
            {role="system", content=(WE_PROMPTS and WE_PROMPTS.build_loop(wea_enabled()) or "") .. context},
            {role="user",   content=make_user_msg()},
        }

        llm_api.request(messages, function(result)
            if not result.success then
                callback({ok=false, error=result.error or "LLM request failed", steps=all_results})
                return
            end

            local raw = result.content or ""
            raw = raw:match("```json\n(.-)```") or raw:match("```\n(.-)```") or raw
            raw = raw:match("^%s*(.-)%s*$")

            local parsed = core.parse_json(raw)
            if not parsed or type(parsed) ~= "table" then
                callback({ok=false, error="Invalid JSON on iteration " .. iteration,
                    raw=result.content, steps=all_results})
                return
            end

            local plan       = parsed.plan       or "(no plan)"
            local tool_calls = parsed.tool_calls or {}
            local done       = parsed.done       == true
            local reason     = parsed.reason     or ""

            local exec_results = {}
            if #tool_calls > 0 then
                exec_results = M.execute_tool_calls(player_name, tool_calls)
            end

            local step = {iteration=iteration, plan=plan, results=exec_results, done=done}
            table.insert(all_results,  step)
            table.insert(step_history, step)

            if on_step then pcall(on_step, iteration, plan, exec_results) end

            local had_hard_error = false
            for _, r in ipairs(exec_results) do
                if r.tool == "*" and not r.ok then had_hard_error = true; break end
            end

            if done or had_hard_error then
                callback({
                    ok       = true,
                    finished = done and not had_hard_error,
                    reason   = had_hard_error
                                and ("Aborted: hard error on iteration " .. iteration)
                                or reason,
                    steps    = all_results,
                })
            else
                do_iteration()
            end
        end, {timeout=timeout})
    end

    -- Kick off
    do_iteration()
end

-- ============================================================
-- Format loop results for display
-- ============================================================

function M.format_loop_results(res)
    if not res.ok then
        return "✗ Loop error: " .. (res.error or "?")
    end
    local lines = {}
    local icon  = res.finished and "✓" or "⚠"
    table.insert(lines, icon .. " Loop finished after "
        .. #(res.steps or {}) .. " step(s). " .. (res.reason or ""))
    for _, step in ipairs(res.steps or {}) do
        table.insert(lines, string.format("\n— Step %d: %s", step.iteration, step.plan))
        for _, r in ipairs(step.results or {}) do
            table.insert(lines, string.format("   %s %s → %s",
                r.ok and "✓" or "✗", r.tool, r.message))
        end
    end
    return table.concat(lines, "\n")
end

-- ============================================================
-- LLM request wrapper for agency mode (single-shot)
-- Sends the WorldEdit context + user request to the LLM,
-- parses the JSON response, executes tool calls.
-- Phase 1: parses and logs; execution only for set_pos1/set_pos2/get_selection.
-- ============================================================

function M.request(player_name, user_message, callback)
    if not M.is_available() then
        callback({ok=false, error="WorldEdit is not installed or not loaded."})
        return
    end

    local llm_api = _G.llm_api
    if not llm_api then
        callback({ok=false, error="llm_api not available"})
        return
    end

    local context = M.get_context(player_name)

    local messages = {
        {role = "system", content = (WE_PROMPTS and WE_PROMPTS.build_single(wea_enabled()) or "") .. context},
        {role = "user",   content = user_message},
    }

    llm_api.request(messages, function(result)
        if not result.success then
            callback({ok=false, error=result.error or "LLM request failed"})
            return
        end

        -- Parse JSON response from LLM
        local raw = result.content or ""

        -- Strip markdown fences if present
        raw = raw:match("```json\n(.-)```") or raw:match("```\n(.-)```") or raw
        raw = raw:match("^%s*(.-)%s*$")  -- trim

        local parsed = core.parse_json(raw)
        if not parsed or type(parsed) ~= "table" then
            callback({
                ok      = false,
                error   = "LLM returned invalid JSON",
                raw     = result.content,
            })
            return
        end

        local plan       = parsed.plan or "(no plan)"
        local tool_calls = parsed.tool_calls or {}

        if type(tool_calls) ~= "table" or #tool_calls == 0 then
            callback({ok=true, plan=plan, results={}, message="No tool calls in response."})
            return
        end

        -- Execute
        local exec_results = M.execute_tool_calls(player_name, tool_calls)

        callback({
            ok       = true,
            plan     = plan,
            results  = exec_results,
            raw      = result.content,
        })
    end, {
        timeout = (_G.llm_api and _G.llm_api.get_timeout("we")) or 60,
        -- Note: NOT using native tool_calls API here because local models
        -- (Ollama) often don't support it reliably. We use JSON-in-text instead.
    })
end

-- ============================================================
-- Format results for display in chat_gui
-- ============================================================

function M.format_results(plan, results)
    local lines = {"Plan: " .. (plan or "?")}
    for i, r in ipairs(results) do
        local icon = r.ok and "✓" or "✗"
        table.insert(lines, string.format("  %s [%d] %s → %s",
            icon, i, r.tool, r.message))
    end
    return table.concat(lines, "\n")
end

core.log("action", "[llm_worldedit] Agency module loaded (Phase 2 – all dispatchers active)")

-- ============================================================
-- Phase 5: WorldEditAdditions (WEA) Integration
-- ============================================================
-- WEA exposes its operations via the global `worldeditadditions`
-- table AND as registered chat commands ("//torus" etc.).
-- We prefer the direct Lua API where available (worldeditadditions.*),
-- and fall back to chat-command dispatch where needed.
--
-- DETECTION: worldeditadditions table + at least one known function
-- SETTING:   llm_worldedit_additions (bool, default true)
-- ============================================================

local function wea_enabled()
    if not core.settings:get_bool("llm_worldedit_additions", true) then
        return false
    end
    return type(worldeditadditions) == "table"
        and type(worldeditadditions.torus) == "function"
end

-- Internal: dispatch a WEA chat command by calling its registered
-- handler directly. Returns {ok, message, nodes}.
-- This is used for commands where WEA's Lua API differs from the
-- chat command (erode, convolve, overlay, replacemix, layers).
local function wea_cmd(player_name, cmd_name, params_str)
    -- WEA registers commands as "/<name>" (single slash, WEA convention)
    -- The chat command is registered as "/<name>" by worldedit.register_command
    local full_name = cmd_name  -- e.g. "convolve", "erode"
    -- Try: registered_chatcommands["/convolve"] first
    local handler = core.registered_chatcommands["/" .. full_name]
    if not handler then
        -- Some WEA versions use double-slash: "//convolve"
        handler = core.registered_chatcommands["//" .. full_name]
    end
    if not handler or not handler.func then
        return {ok=false, message="WEA command '" .. full_name .. "' not registered"}
    end
    local ok, result = pcall(handler.func, player_name, params_str or "")
    if not ok then
        return {ok=false, message="WEA dispatch error: " .. tostring(result)}
    end
    -- WEA command handlers return (bool, message) or just bool
    if type(result) == "string" then
        return {ok=true, message=result}
    elseif type(result) == "boolean" then
        return {ok=result, message=(result and "OK" or "WEA command returned false")}
    end
    return {ok=true, message="OK"}
end

-- ── WEA DISPATCHERS ────────────────────────────────────────

local WEA_DISPATCHERS = {

    -- torus(pos1, radius_major, radius_minor, node, hollow)
    -- pos1 must be set first; torus is placed at pos1
    torus = function(name, args)
        if not wea_enabled() then return {ok=false, message="WEA not available"} end
        local p1 = worldedit.pos1[name]
        if not p1 then return {ok=false, message="torus: set pos1 first"} end
        local r_major = tonumber(args.radius_major or args.radius or 10)
        local r_minor = tonumber(args.radius_minor or args.tube_radius or 3)
        local node, err = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="torus: " .. err} end
        local hollow = args.hollow == true or args.hollow == "true"
        if r_major < 1 or r_major > 64 then return {ok=false, message="torus: radius_major 1–64"} end
        if r_minor < 1 or r_minor > 32 then return {ok=false, message="torus: radius_minor 1–32"} end
        -- Direct Lua API: worldeditadditions.torus(pos, radius_major, radius_minor, node, hollow)
        local ok, count = pcall(worldeditadditions.torus, p1, r_major, r_minor, node, hollow)
        if not ok then
            -- Fallback: chat command "//torus <major> <minor> <node> [hollow]"
            local params = r_major .. " " .. r_minor .. " " .. node .. (hollow and " hollow" or "")
            return wea_cmd(name, "torus", params)
        end
        return {ok=true,
            message=string.format("Torus r_major=%d r_minor=%d %s at (%d,%d,%d): %d nodes",
                r_major, r_minor, node, p1.x, p1.y, p1.z, count or 0),
            nodes=count}
    end,

    hollowtorus = function(name, args)
        args.hollow = true
        args.radius_major = args.radius_major or args.radius or 10
        return WEA_DISPATCHERS.torus(name, args)
    end,

    -- ellipsoid(pos1, rx, ry, rz, node, hollow)
    ellipsoid = function(name, args)
        if not wea_enabled() then return {ok=false, message="WEA not available"} end
        local p1 = worldedit.pos1[name]
        if not p1 then return {ok=false, message="ellipsoid: set pos1 first"} end
        local rx = tonumber(args.rx or args.radius_x or args.radius or 5)
        local ry = tonumber(args.ry or args.radius_y or rx)
        local rz = tonumber(args.rz or args.radius_z or rx)
        local node, err = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="ellipsoid: " .. err} end
        local hollow = args.hollow == true or args.hollow == "true"
        for _, r in ipairs({rx, ry, rz}) do
            if r < 1 or r > 64 then return {ok=false, message="ellipsoid: radii must be 1–64"} end
        end
        local ok, count = pcall(worldeditadditions.ellipsoid, p1, rx, ry, rz, node, hollow)
        if not ok then
            local params = rx .. " " .. ry .. " " .. rz .. " " .. node .. (hollow and " hollow" or "")
            return wea_cmd(name, "ellipsoid", params)
        end
        return {ok=true,
            message=string.format("Ellipsoid rx=%d ry=%d rz=%d %s at (%d,%d,%d): %d nodes",
                rx, ry, rz, node, p1.x, p1.y, p1.z, count or 0),
            nodes=count}
    end,

    hollowellipsoid = function(name, args)
        args.hollow = true
        return WEA_DISPATCHERS.ellipsoid(name, args)
    end,

    -- floodfill(pos1, node, radius)
    -- Fills from pos1 outward, replacing all air
    floodfill = function(name, args)
        if not wea_enabled() then return {ok=false, message="WEA not available"} end
        local p1 = worldedit.pos1[name]
        if not p1 then return {ok=false, message="floodfill: set pos1 first"} end
        local node, err = resolve_node(tostring(args.node or "default:stone"))
        if not node then return {ok=false, message="floodfill: " .. err} end
        local radius = tonumber(args.radius or 10)
        if radius < 1 or radius > 50 then return {ok=false, message="floodfill: radius 1–50"} end
        local ok, count = pcall(worldeditadditions.floodfill, p1, node, radius)
        if not ok then
            return wea_cmd(name, "floodfill", node .. " " .. radius)
        end
        return {ok=true,
            message=string.format("Floodfill %s r=%d from (%d,%d,%d): %d nodes",
                node, radius, p1.x, p1.y, p1.z, count or 0),
            nodes=count}
    end,

    -- overlay(pos1, pos2, node)
    -- Places node on top of every surface column in the selection
    overlay = function(name, args)
        if not wea_enabled() then return {ok=false, message="WEA not available"} end
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then return {ok=false, message="overlay: set pos1 and pos2 first"} end
        local node, err = resolve_node(tostring(args.node or "default:dirt_with_grass"))
        if not node then return {ok=false, message="overlay: " .. err} end
        local ok, count = pcall(worldeditadditions.overlay, p1, p2, node)
        if not ok then
            return wea_cmd(name, "overlay", node)
        end
        return {ok=true,
            message=string.format("Overlay %s on selection: %d nodes", node, count or 0),
            nodes=count}
    end,

    -- replacemix(pos1, pos2, target_node, {node=chance, ...})
    -- Replaces target with a weighted mix of replacement nodes
    -- args: target, replacements = [{node, chance}, ...]
    replacemix = function(name, args)
        if not wea_enabled() then return {ok=false, message="WEA not available"} end
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then return {ok=false, message="replacemix: set pos1/pos2 first"} end
        local target, err = resolve_node(tostring(args.target or args.search_node or "default:stone"))
        if not target then return {ok=false, message="replacemix: " .. err} end
        -- Build replacement list: [{node, chance}] or flat string for chat fallback
        local replacements = args.replacements or {}
        if #replacements == 0 then
            -- Simple single replacement
            local rnode = resolve_node(tostring(args.replace_node or args.node or "default:dirt"))
            replacements = {{node=rnode, chance=1}}
        end
        -- Build chat params string as fallback: "<target> <nodeA> [chanceA] <nodeB> [chanceB]..."
        local param_parts = {target}
        for _, r in ipairs(replacements) do
            table.insert(param_parts, tostring(r.node or "default:dirt"))
            if r.chance and r.chance ~= 1 then
                table.insert(param_parts, tostring(r.chance))
            end
        end
        -- Try direct API first
        local ok, count = pcall(worldeditadditions.replacemix, p1, p2, target, replacements)
        if not ok then
            return wea_cmd(name, "replacemix", table.concat(param_parts, " "))
        end
        return {ok=true,
            message=string.format("Replacemix %s → %d replacement(s): %d nodes affected",
                target, #replacements, count or 0),
            nodes=count}
    end,

    -- layers(pos1, pos2, layers_def)
    -- Applies terrain layers from top down. layers_def is a list of {node, depth}.
    -- E.g. layers_def = [{node="default:dirt_with_grass", depth=1}, {node="default:dirt", depth=3}]
    layers = function(name, args)
        if not wea_enabled() then return {ok=false, message="WEA not available"} end
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then return {ok=false, message="layers: set pos1/pos2 first"} end
        local layers_def = args.layers or {}
        if #layers_def == 0 then
            -- Simple single-layer shortcut
            local node = resolve_node(tostring(args.node or "default:dirt"))
            local depth = tonumber(args.depth or 1)
            layers_def = {{node=node, depth=depth}}
        end
        -- Build chat command params: "<node> <depth> [<node2> <depth2>...]"
        local param_parts = {}
        for _, layer in ipairs(layers_def) do
            table.insert(param_parts, tostring(layer.node or "default:dirt"))
            table.insert(param_parts, tostring(layer.depth or 1))
        end
        local ok, count = pcall(worldeditadditions.layers, p1, p2, layers_def)
        if not ok then
            return wea_cmd(name, "layers", table.concat(param_parts, " "))
        end
        return {ok=true,
            message=string.format("Layers (%d layer defs) on selection: %d nodes",
                #layers_def, count or 0),
            nodes=count}
    end,

    -- erode(pos1, pos2, [algorithm], [iterations])
    -- Applies erosion simulation to terrain in selection
    -- algorithm: "snowballs" (default) | "river" | "wind"
    erode = function(name, args)
        if not wea_enabled() then return {ok=false, message="WEA not available"} end
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then return {ok=false, message="erode: set pos1/pos2 first"} end
        local algorithm  = tostring(args.algorithm or "snowballs")
        local iterations = tonumber(args.iterations or 1)
        local valid_algos = {snowballs=true, river=true, wind=true}
        if not valid_algos[algorithm] then algorithm = "snowballs" end
        if iterations < 1 or iterations > 10 then iterations = 1 end
        -- Build param string for chat fallback
        local params = algorithm .. " " .. iterations
        -- erode Lua API: worldeditadditions.erode(pos1, pos2, params_table)
        local ok, count = pcall(worldeditadditions.erode, p1, p2,
            {algorithm=algorithm, iterations=iterations})
        if not ok then
            return wea_cmd(name, "erode", params)
        end
        return {ok=true,
            message=string.format("Erode algorithm=%s iterations=%d: %d nodes",
                algorithm, iterations, count or 0),
            nodes=count}
    end,

    -- convolve(pos1, pos2, [kernel], [size])
    -- Smooths terrain with a convolution kernel
    -- kernel: "gaussian" (default) | "box" | "pascal"
    convolve = function(name, args)
        if not wea_enabled() then return {ok=false, message="WEA not available"} end
        local p1 = worldedit.pos1[name]
        local p2 = worldedit.pos2[name]
        if not p1 or not p2 then return {ok=false, message="convolve: set pos1/pos2 first"} end
        local kernel = tostring(args.kernel or "gaussian")
        local size   = tonumber(args.size or 5)
        local valid_kernels = {gaussian=true, box=true, pascal=true}
        if not valid_kernels[kernel] then kernel = "gaussian" end
        if size < 3 then size = 3 end
        if size > 15 then size = 15 end
        if size % 2 == 0 then size = size + 1 end  -- must be odd
        local params = kernel .. " " .. size
        local ok, count = pcall(worldeditadditions.convolve, p1, p2,
            {kernel=kernel, size=size})
        if not ok then
            return wea_cmd(name, "convolve", params)
        end
        return {ok=true,
            message=string.format("Convolve kernel=%s size=%d: %d nodes",
                kernel, size, count or 0),
            nodes=count}
    end,
}

-- ── WEA Integration in get_context() ──────────────────────
-- Extend the context string with WEA capabilities when available

local original_get_context = M.get_context
function M.get_context(player_name)
    local base = original_get_context(player_name)
    if not wea_enabled() then return base end

    local wea_capabilities = table.concat({
        "torus(radius_major, radius_minor, node, hollow)",
        "hollowtorus(radius_major, radius_minor, node)",
        "ellipsoid(rx, ry, rz, node, hollow)",
        "hollowellipsoid(rx, ry, rz, node)",
        "floodfill(node, radius)",
        "overlay(node)",
        "replacemix(target, replacements=[{node,chance}])",
        "layers(layers=[{node,depth}])",
        "erode([algorithm=snowballs|river|wind], [iterations=1])",
        "convolve([kernel=gaussian|box|pascal], [size=5])",
    }, " | ")

    local wea_block = table.concat({
        "",
        "=== WorldEditAdditions Tools ===",
        "Available WEA tools (set pos1/pos2 first for region ops):",
        wea_capabilities,
        "torus/ellipsoid/floodfill use pos1 as center.",
        "overlay/replacemix/layers/erode/convolve operate on pos1..pos2 region.",
        "=== END WEA ===",
    }, "\n")

    -- Insert before "=== END CONTEXT ==="
    return base:gsub("=== END CONTEXT ===", wea_block .. "\n=== END CONTEXT ===")
end

-- ── WEA Integration in SYSTEM_PROMPT ──────────────────────


-- ── WEA TOOL_SCHEMA extension ──────────────────────────────

M.WEA_TOOL_SCHEMA = {
    {name="torus",          description="Generate a torus at pos1. Set pos1 first.",
     parameters={radius_major="integer (1–64)", radius_minor="integer (1–32)", node="string", hollow="boolean (optional)"}},
    {name="hollowtorus",    description="Generate a hollow torus at pos1.",
     parameters={radius_major="integer", radius_minor="integer", node="string"}},
    {name="ellipsoid",      description="Generate an ellipsoid at pos1 with per-axis radii.",
     parameters={rx="integer (1–64)", ry="integer (1–64)", rz="integer (1–64)", node="string", hollow="boolean (optional)"}},
    {name="hollowellipsoid",description="Generate a hollow ellipsoid at pos1.",
     parameters={rx="integer", ry="integer", rz="integer", node="string"}},
    {name="floodfill",      description="Flood-fill from pos1 outward, replacing air with node.",
     parameters={node="string", radius="integer (1–50)"}},
    {name="overlay",        description="Place node on top of every surface column in pos1..pos2.",
     parameters={node="string"}},
    {name="replacemix",     description="Replace target node with a weighted mix of nodes in selection.",
     parameters={target="string", replacements="array of {node, chance}"}},
    {name="layers",         description="Apply terrain layers top-down in selection.",
     parameters={layers="array of {node, depth}"}},
    {name="erode",          description="Apply erosion to terrain in selection.",
     parameters={algorithm="string (snowballs|river|wind, optional)", iterations="integer 1–10 (optional)"}},
    {name="convolve",       description="Smooth terrain with convolution kernel in selection.",
     parameters={kernel="string (gaussian|box|pascal, optional)", size="odd integer 3–15 (optional)"}},
}

-- ── WEA dispatcher registration in main dispatch table ─────
-- This hooks WEA_DISPATCHERS into the existing dispatch system

local original_dispatch = M._dispatch_tool
-- Wrap the main dispatch function to check WEA tools first
-- (M._dispatch_tool is set during request/run_loop execution)
M.wea_dispatchers = WEA_DISPATCHERS

-- ── wea_available() helper for external use ────────────────
function M.wea_is_available()
    return wea_enabled()
end

core.log("action", "[llm_worldedit] Phase 5: WEA integration loaded (wea_enabled=" .. tostring(wea_enabled()) .. ")")

return M
