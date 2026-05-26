-- ===========================================================================
--  skills/node_printer_preview/node_printer_preview.lua
--
--  Isolated experimental voxel-CSG builder for LLM Connect.
--  This skill owns its API, compiler, validation, documentation and workflow.
-- ===========================================================================

local core = core

local SKILL_ID = "node_printer_preview"
local DEFAULT_MAX_NODES = 20000

local NODE_ALIASES = {
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
    ["minecraft:oak_log"]     = "default:tree",
    ["minecraft:oak_planks"]  = "default:wood",
    ["minecraft:glass"]       = "default:glass",
    ["minecraft:cobblestone"] = "default:cobble",
}

local SEARCH_TOKEN_EXPANSIONS = {
    build = { "stone", "wood", "brick", "cracky", "choppy" },
    building = { "stone", "wood", "brick", "cracky", "choppy" },
    structure = { "stone", "wood", "brick", "cracky", "choppy" },
    wall = { "stone", "brick", "cobble", "cracky" },
    floor = { "stone", "wood", "brick", "cracky", "choppy" },
    roof = { "wood", "tree", "choppy", "flammable" },
    window = { "glass", "transparent" },
    transparent = { "glass", "transparent" },
    color = { "brick", "glass", "dye", "wool" },
    colored = { "brick", "glass", "dye", "wool" },
    accent = { "brick", "glass", "wood", "stone" },
    stripe = { "brick", "glass", "wood", "stone" },
    trim = { "brick", "glass", "wood", "stone" },
    red = { "red", "brick" },
    grey = { "grey", "gray", "stone", "cobble" },
    gray = { "gray", "grey", "stone", "cobble" },
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function table_len(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
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

local function pos_key(pos)
    return tostring(pos.x) .. "," .. tostring(pos.y) .. "," .. tostring(pos.z)
end

local function pos_string(pos)
    if core.pos_to_string then return core.pos_to_string(pos) end
    return "(" .. tostring(pos.x) .. "," .. tostring(pos.y) .. "," .. tostring(pos.z) .. ")"
end

local function update_bounds(bounds, pos)
    if not bounds.min then
        bounds.min = copy_pos(pos)
        bounds.max = copy_pos(pos)
        return
    end
    bounds.min.x = math.min(bounds.min.x, pos.x)
    bounds.min.y = math.min(bounds.min.y, pos.y)
    bounds.min.z = math.min(bounds.min.z, pos.z)
    bounds.max.x = math.max(bounds.max.x, pos.x)
    bounds.max.y = math.max(bounds.max.y, pos.y)
    bounds.max.z = math.max(bounds.max.z, pos.z)
end

local function registered_node(name)
    return type(name) == "string" and core.registered_nodes and core.registered_nodes[name]
end

local function sorted_keys(t)
    local keys = {}
    for key in pairs(t or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function normalize_search_text(s)
    return trim(s):lower():gsub("[^%w_:]+", " ")
end

local function search_tokens(query)
    local tokens = {}
    local seen = {}
    for token in normalize_search_text(query):gmatch("%S+") do
        if not seen[token] then
            seen[token] = true
            tokens[#tokens + 1] = token
        end
        for _, expanded in ipairs(SEARCH_TOKEN_EXPANSIONS[token] or {}) do
            if not seen[expanded] then
                seen[expanded] = true
                tokens[#tokens + 1] = expanded
            end
        end
    end
    return tokens
end

local function append_query_strings(out, value)
    if type(value) == "string" then
        local q = trim(value)
        if q ~= "" then out[#out + 1] = q end
        return
    end
    if type(value) ~= "table" then return end
    for _, item in ipairs(value) do append_query_strings(out, item) end
    for key, item in pairs(value) do
        if type(key) ~= "number" then append_query_strings(out, item) end
    end
end

local function asset_queries(args)
    local queries = {}
    append_query_strings(queries, args.query)
    append_query_strings(queries, args.queries)
    append_query_strings(queries, args.q)
    append_query_strings(queries, args.name)

    local seen = {}
    local out = {}
    for _, query in ipairs(queries) do
        local key = query:lower()
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = query
        end
    end
    return out
end

local function resolve_registered_alias(name)
    local aliases = rawget(core, "registered_aliases")
    local target = type(aliases) == "table" and aliases[name]
    if registered_node(target) then return target end
    return nil
end

local function resolve_node(node_str)
    local original = trim(node_str):lower()
    if original == "" then return nil, "node name is empty" end
    if original == "air" then return "air" end

    local candidates = { original }
    if NODE_ALIASES[original] then table.insert(candidates, 1, NODE_ALIASES[original]) end
    if not original:find(":", 1, true) then table.insert(candidates, "default:" .. original) end
    if original:find("oak", 1, true) and (original:find("log", 1, true) or original:find("trunk", 1, true)) then
        table.insert(candidates, "default:tree")
    end
    if original:find("wood", 1, true) or original:find("plank", 1, true) then table.insert(candidates, "default:wood") end
    if original:find("window", 1, true) or original:find("glass", 1, true) then table.insert(candidates, "default:glass") end
    if original:find("cobble", 1, true) or original:find("cobblestone", 1, true) then table.insert(candidates, "default:cobble") end
    if original:find("stone", 1, true) then table.insert(candidates, "default:stone") end

    local seen = {}
    for _, candidate in ipairs(candidates) do
        if candidate and not seen[candidate] then
            seen[candidate] = true
            if registered_node(candidate) then return candidate end
            local aliased = resolve_registered_alias(candidate)
            if aliased then return aliased end
        end
    end

    return nil, "unknown node '" .. tostring(node_str) .. "'; use asset_search with a semantic query before preview/print"
end

local function validate_vec3(value, label)
    if type(value) ~= "table" then return nil, label .. " must be {x=integer, y=integer, z=integer}" end
    local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
    if not x or not y or not z then return nil, label .. " requires numeric x, y and z" end
    if x ~= math.floor(x) or y ~= math.floor(y) or z ~= math.floor(z) then
        return nil, label .. " values must be integers"
    end
    return { x = x, y = y, z = z }
end

local function validate_vec2(value, label, a, b)
    a = a or "u"
    b = b or "v"
    if type(value) ~= "table" then return nil, label .. " must be {" .. a .. "=integer, " .. b .. "=integer}" end
    local av, bv = tonumber(value[a]), tonumber(value[b])
    if not av or not bv then return nil, label .. " requires numeric " .. a .. " and " .. b end
    if av ~= math.floor(av) or bv ~= math.floor(bv) then
        return nil, label .. " values must be integers"
    end
    local out = {}
    out[a] = av
    out[b] = bv
    return out
end

local function validate_positive_size(value, label)
    local size, err = validate_vec3(value, label)
    if not size then return nil, err end
    if size.x < 1 or size.y < 1 or size.z < 1 then
        return nil, label .. " values must be positive integers"
    end
    return size
end

local function validate_positive_size2(value, label)
    local size, err = validate_vec2(value, label, "u", "v")
    if not size then return nil, err end
    if size.u < 1 or size.v < 1 then
        return nil, label .. " values must be positive integers"
    end
    return size
end

local function validate_positive_int(value, label)
    local n = tonumber(value)
    if not n or n ~= math.floor(n) or n < 1 then return nil, label .. " must be a positive integer" end
    return n
end

local function player_origin(player_name)
    if type(player_name) ~= "string" or player_name == "" then
        return nil, "player-relative build requires player_name"
    end
    local player = core.get_player_by_name and core.get_player_by_name(player_name)
    if not player then return nil, "player-relative build requires an online player position" end
    return copy_pos(player:get_pos())
end

local function resolve_origin(build, player_name)
    build = build or {}
    if build.absolute == true then
        if build.origin ~= nil then
            local origin, err = validate_vec3(build.origin, "origin")
            if not origin then return nil, err end
            return origin
        end
        return { x = 0, y = 0, z = 0 }
    end

    local anchor = build.anchor or "player"
    if anchor ~= "player" then return nil, "anchor must be \"player\" in the MVP" end
    return player_origin(player_name)
end

local function map_write(state, local_pos, node)
    state.affected = state.affected + 1
    if state.affected > state.max_nodes then
        return false, "build exceeds max_nodes=" .. tostring(state.max_nodes)
    end

    local world_pos = add_pos(state.origin, local_pos)
    local key = pos_key(world_pos)
    state.voxel_map[key] = {
        pos = world_pos,
        local_pos = copy_pos(local_pos),
        node = node,
    }
    state.materials[node] = (state.materials[node] or 0) + 1
    update_bounds(state.local_bounds, local_pos)
    update_bounds(state.world_bounds, world_pos)
    if table_len(state.voxel_map) > state.max_nodes then
        return false, "build exceeds max_nodes=" .. tostring(state.max_nodes)
    end
    return true
end

local function write_box_to_map(state, at, size, node)
    for x = at.x, at.x + size.x - 1 do
        for y = at.y, at.y + size.y - 1 do
            for z = at.z, at.z + size.z - 1 do
                local ok, err = map_write(state, { x = x, y = y, z = z }, node)
                if not ok then return false, err end
            end
        end
    end
    return true
end

local function write_shell_box_to_map(state, at, size, node)
    local maxx = at.x + size.x - 1
    local maxy = at.y + size.y - 1
    local maxz = at.z + size.z - 1
    for x = at.x, maxx do
        for y = at.y, maxy do
            for z = at.z, maxz do
                local boundary = x == at.x or x == maxx or y == at.y or y == maxy or z == at.z or z == maxz
                if boundary then
                    local ok, err = map_write(state, { x = x, y = y, z = z }, node)
                    if not ok then return false, err end
                end
            end
        end
    end
    return true
end

local function write_column_to_map(state, at, height, node)
    for y = at.y, at.y + height - 1 do
        local ok, err = map_write(state, { x = at.x, y = y, z = at.z }, node)
        if not ok then return false, err end
    end
    return true
end

local function patch_bounds(ref_at, ref_size, face, patch_at, patch_size, depth)
    local maxx = ref_at.x + ref_size.x - 1
    local maxy = ref_at.y + ref_size.y - 1
    local maxz = ref_at.z + ref_size.z - 1
    face = tostring(face or "")

    if face == "front" or face == "back" then
        if patch_at.u < 0 or patch_at.v < 0 or patch_at.u + patch_size.u > ref_size.x or patch_at.v + patch_size.v > ref_size.y then
            return nil, "patch exceeds " .. face .. " face bounds"
        end
        if depth > ref_size.z then return nil, "patch depth exceeds box z size" end
        local z1 = face == "front" and ref_at.z or (maxz - depth + 1)
        local z2 = face == "front" and (ref_at.z + depth - 1) or maxz
        return {
            x = ref_at.x + patch_at.u,
            y = ref_at.y + patch_at.v,
            z = z1,
        }, {
            x = ref_at.x + patch_at.u + patch_size.u - 1,
            y = ref_at.y + patch_at.v + patch_size.v - 1,
            z = z2,
        }
    end

    if face == "left" or face == "right" then
        if patch_at.u < 0 or patch_at.v < 0 or patch_at.u + patch_size.u > ref_size.z or patch_at.v + patch_size.v > ref_size.y then
            return nil, "patch exceeds " .. face .. " face bounds"
        end
        if depth > ref_size.x then return nil, "patch depth exceeds box x size" end
        local x1 = face == "left" and ref_at.x or (maxx - depth + 1)
        local x2 = face == "left" and (ref_at.x + depth - 1) or maxx
        return {
            x = x1,
            y = ref_at.y + patch_at.v,
            z = ref_at.z + patch_at.u,
        }, {
            x = x2,
            y = ref_at.y + patch_at.v + patch_size.v - 1,
            z = ref_at.z + patch_at.u + patch_size.u - 1,
        }
    end

    if face == "top" or face == "bottom" then
        if patch_at.u < 0 or patch_at.v < 0 or patch_at.u + patch_size.u > ref_size.x or patch_at.v + patch_size.v > ref_size.z then
            return nil, "patch exceeds " .. face .. " face bounds"
        end
        if depth > ref_size.y then return nil, "patch depth exceeds box y size" end
        local y1 = face == "bottom" and ref_at.y or (maxy - depth + 1)
        local y2 = face == "bottom" and (ref_at.y + depth - 1) or maxy
        return {
            x = ref_at.x + patch_at.u,
            y = y1,
            z = ref_at.z + patch_at.v,
        }, {
            x = ref_at.x + patch_at.u + patch_size.u - 1,
            y = y2,
            z = ref_at.z + patch_at.v + patch_size.v - 1,
        }
    end

    return nil, "face must be front, back, left, right, top or bottom"
end

local function write_patch_to_map(state, ref_at, ref_size, face, patch_at, patch_size, depth, node)
    local minp, maxp_or_err = patch_bounds(ref_at, ref_size, face, patch_at, patch_size, depth)
    if not minp then return false, maxp_or_err end
    return write_box_to_map(state, minp, {
        x = maxp_or_err.x - minp.x + 1,
        y = maxp_or_err.y - minp.y + 1,
        z = maxp_or_err.z - minp.z + 1,
    }, node)
end

local function sorted_writes(voxel_map)
    local writes = {}
    for _, entry in pairs(voxel_map or {}) do writes[#writes + 1] = entry end
    table.sort(writes, function(a, b)
        if a.pos.y ~= b.pos.y then return a.pos.y < b.pos.y end
        if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
        return a.pos.z < b.pos.z
    end)
    return writes
end

local function compile_build(build, player_name)
    if type(build) ~= "table" then return nil, "build must be a table" end
    if build.ops ~= nil and type(build.ops) ~= "table" then return nil, "build.ops must be an array" end
    local ops = build.ops or {}
    if #ops == 0 then return nil, "build.ops must contain at least one operation" end

    local max_nodes = tonumber(build.max_nodes or DEFAULT_MAX_NODES)
    if not max_nodes or max_nodes ~= math.floor(max_nodes) or max_nodes < 1 then
        return nil, "max_nodes must be a positive integer"
    end

    local origin, origin_err = resolve_origin(build, player_name)
    if not origin then return nil, origin_err end

    local state = {
        origin = origin,
        max_nodes = max_nodes,
        affected = 0,
        voxel_map = {},
        materials = {},
        local_bounds = {},
        world_bounds = {},
    }

    for i, op in ipairs(ops) do
        if type(op) ~= "table" then return nil, "ops[" .. tostring(i) .. "] must be a table" end
        local op_name = tostring(op.op or "")
        local shape = tostring(op.shape or "")
        if op_name ~= "solid" and op_name ~= "shell" and op_name ~= "cut" and op_name ~= "paint" then
            return nil, "ops[" .. tostring(i) .. "]: unsupported op '" .. op_name .. "'"
        end

        local node = "air"
        if op_name ~= "cut" then
            local resolved, nerr = resolve_node(op.node)
            if not resolved then return nil, "ops[" .. tostring(i) .. "]: " .. nerr end
            node = resolved
        end

        local ok, err
        if shape == "box" then
            local at, aerr = validate_vec3(op.at, "ops[" .. tostring(i) .. "].at")
            if not at then return nil, aerr end
            local size, serr = validate_positive_size(op.size, "ops[" .. tostring(i) .. "].size")
            if not size then return nil, serr end
            if op_name == "shell" then
                ok, err = write_shell_box_to_map(state, at, size, node)
            else
                ok, err = write_box_to_map(state, at, size, node)
            end
        elseif shape == "column" then
            if op_name ~= "solid" and op_name ~= "paint" then
                return nil, "ops[" .. tostring(i) .. "]: column supports only solid and paint in the MVP"
            end
            local at, aerr = validate_vec3(op.at, "ops[" .. tostring(i) .. "].at")
            if not at then return nil, aerr end
            local height, herr = validate_positive_int(op.height, "ops[" .. tostring(i) .. "].height")
            if not height then return nil, herr end
            ok, err = write_column_to_map(state, at, height, node)
        elseif shape == "patch" then
            if op_name == "shell" then
                return nil, "ops[" .. tostring(i) .. "]: patch supports solid, cut and paint"
            end
            if type(op.on) ~= "table" then return nil, "ops[" .. tostring(i) .. "].on must describe a box face" end
            if tostring(op.on.shape or "") ~= "box" then return nil, "ops[" .. tostring(i) .. "].on.shape must be \"box\"" end
            local ref_at, raerr = validate_vec3(op.on.at, "ops[" .. tostring(i) .. "].on.at")
            if not ref_at then return nil, raerr end
            local ref_size, rserr = validate_positive_size(op.on.size, "ops[" .. tostring(i) .. "].on.size")
            if not ref_size then return nil, rserr end
            local patch_at, paerr = validate_vec2(op.at, "ops[" .. tostring(i) .. "].at", "u", "v")
            if not patch_at then return nil, paerr end
            local patch_size, pserr = validate_positive_size2(op.size, "ops[" .. tostring(i) .. "].size")
            if not patch_size then return nil, pserr end
            local depth, derr = validate_positive_int(op.depth or 1, "ops[" .. tostring(i) .. "].depth")
            if not depth then return nil, derr end
            ok, err = write_patch_to_map(state, ref_at, ref_size, op.on.face, patch_at, patch_size, depth, node)
        else
            return nil, "ops[" .. tostring(i) .. "]: unsupported shape '" .. shape .. "'; shape must be \"box\", \"column\" or \"patch\". Use op=\"" .. op_name .. "\" with shape=\"box\" for ordinary filled boxes."
        end
        if not ok then return nil, err end
    end

    local writes = sorted_writes(state.voxel_map)
    local materials = {}
    for _, entry in ipairs(writes) do materials[entry.node] = (materials[entry.node] or 0) + 1 end

    return {
        operations = #ops,
        nodes = #writes,
        affected = state.affected,
        materials = materials,
        origin = origin,
        min = state.world_bounds.min,
        max = state.world_bounds.max,
        world_min = state.world_bounds.min,
        world_max = state.world_bounds.max,
        local_min = state.local_bounds.min,
        local_max = state.local_bounds.max,
        writes = writes,
    }
end

local function preview_build(build, player_name)
    local compiled, err = compile_build(build, player_name)
    if not compiled then return { ok = false, success = false, message = "Build preview failed: " .. tostring(err) } end

    return {
        ok = true,
        success = true,
        message = string.format(
            "Build preview validated: %d operation(s), %d resulting node write(s)",
            compiled.operations,
            compiled.nodes
        ),
        data = {
            operations = compiled.operations,
            nodes = compiled.nodes,
            affected = compiled.affected,
            materials = compiled.materials,
            origin = compiled.origin,
            min = compiled.min,
            max = compiled.max,
            world_min = compiled.world_min,
            world_max = compiled.world_max,
            local_min = compiled.local_min,
            local_max = compiled.local_max,
        },
    }
end

local function verify_set_node(entry)
    local ok, err = pcall(core.set_node, entry.pos, { name = entry.node })
    if not ok then return false, "set_node failed at " .. pos_string(entry.pos) .. ": " .. tostring(err) end

    local read = core.get_node_or_nil and core.get_node_or_nil(entry.pos) or core.get_node(entry.pos)
    if not read then return false, "node write could not be verified at " .. pos_string(entry.pos) end
    if read.name == "ignore" then return false, "node write hit ignore at " .. pos_string(entry.pos) end
    if read.name ~= entry.node then
        return false, "node mismatch at " .. pos_string(entry.pos) .. ": expected " .. tostring(entry.node) .. ", got " .. tostring(read.name)
    end
    return true
end

local function print_build(build, player_name)
    local compiled, err = compile_build(build, player_name)
    if not compiled then return { ok = false, success = false, message = "Build print failed: " .. tostring(err) } end
    if compiled.nodes < 1 then return { ok = false, success = false, message = "Build print failed: no node writes compiled" } end

    local failures = {}
    for _, entry in ipairs(compiled.writes) do
        local ok, werr = verify_set_node(entry)
        if not ok then
            failures[#failures + 1] = werr
            if #failures >= 5 then break end
        end
    end

    local data = {
        operations = compiled.operations,
        nodes = compiled.nodes,
        affected = compiled.affected,
        materials = compiled.materials,
        origin = compiled.origin,
        min = compiled.min,
        max = compiled.max,
        world_min = compiled.world_min,
        world_max = compiled.world_max,
        local_min = compiled.local_min,
        local_max = compiled.local_max,
    }

    if #failures > 0 then
        data.failures = failures
        core.log("warning", "[node_printer_preview] print_build verification failed: " .. failures[1])
        return {
            ok = false,
            success = false,
            message = "Build print verification failed after write attempt: " .. failures[1],
            data = data,
        }
    end

    core.log("action", ("[node_printer_preview] print_build verified %d node write(s) | origin=%s min=%s max=%s"):format(
        compiled.nodes,
        pos_string(compiled.origin),
        pos_string(compiled.min),
        pos_string(compiled.max)
    ))

    return {
        ok = true,
        success = true,
        message = string.format("Printed and verified %d node write(s)", compiled.nodes),
        data = data,
    }
end

local function get_node(args)
    args = args or {}
    local pos, err = validate_vec3(args.pos or args, "pos")
    if not pos then return { ok = false, success = false, message = "get_node: " .. err } end
    local node = core.get_node(pos)
    return {
        ok = true,
        success = true,
        message = "Node at " .. pos_string(pos) .. ": " .. tostring(node and node.name or "unknown"),
        data = { pos = pos, node = node },
    }
end

local function asset_search(args)
    args = args or {}
    local queries = asset_queries(args)
    local query = table.concat(queries, " ")
    local limit = tonumber(args.limit or args.max_results or 12)
    if not limit or limit ~= math.floor(limit) or limit < 1 then limit = 12 end
    limit = math.min(limit, 32)

    if #queries == 0 then
        return {
            ok = false,
            success = false,
            message = "asset_search requires args.query or args.queries, for example {query=\"stone wall\"} or {queries={\"colored stripe\",\"brick\"}}",
        }
    end
    if type(core.registered_nodes) ~= "table" then
        return { ok = false, success = false, message = "asset_search failed: registered_nodes unavailable" }
    end

    local tokens = search_tokens(query)
    if #tokens == 0 then
        return { ok = false, success = false, message = "asset_search failed: query produced no search tokens" }
    end

    local explicit_tokens = {}
    for token in normalize_search_text(query):gmatch("%S+") do explicit_tokens[token] = true end

    local matches = {}
    for name, def in pairs(core.registered_nodes) do
        if type(name) == "string" and type(def) == "table" then
            local desc = tostring(def.description or "")
            local groups = sorted_keys(def.groups)
            local group_text = table.concat(groups, " ")
            local haystack = normalize_search_text(name .. " " .. desc .. " " .. group_text)
            local short_name = name:match("^[^:]+:(.+)$") or name
            local score = 0

            for _, token in ipairs(tokens) do
                local explicit_bonus = explicit_tokens[token] and 50 or 0
                if name:lower() == token or short_name:lower() == token then score = score + 100 + explicit_bonus end
                if name:lower():find(token, 1, true) then score = score + 30 + explicit_bonus end
                if normalize_search_text(desc):find(token, 1, true) then score = score + 12 + math.floor(explicit_bonus / 2) end
                if group_text:lower():find(token, 1, true) then score = score + 8 + math.floor(explicit_bonus / 4) end
                if haystack:find(token, 1, true) then score = score + 2 end
            end

            if score > 0 then
                matches[#matches + 1] = {
                    name = name,
                    description = desc ~= "" and desc or nil,
                    groups = groups,
                    score = score,
                }
            end
        end
    end

    table.sort(matches, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.name < b.name
    end)

    local results = {}
    for i = 1, math.min(limit, #matches) do
        results[i] = matches[i]
    end

    local names = {}
    for i, entry in ipairs(results) do names[i] = entry.name end
    return {
        ok = true,
        success = true,
        message = string.format(
            "asset_search '%s': %d result(s)%s",
            query,
            #results,
            #results > 0 and " - " .. table.concat(names, ", ") or ""
        ),
        data = {
            query = query,
            queries = queries,
            tokens = tokens,
            count = #results,
            total_matches = #matches,
            results = results,
            names = names,
        },
        results = results,
        matches = results,
        nodes = names,
        node = results[1] and results[1].name or nil,
        first = results[1],
    }
end

local function run_tool(tool_name, args, player_name)
    tool_name = trim(tool_name):lower()
    if type(player_name) == "table" and type(args) == "string" then
        local temp = args
        args = player_name
        player_name = temp
    end
    if type(args) ~= "table" then args = {} end
    if type(player_name) ~= "string" or player_name == "" then
        player_name = rawget(_G, "player_name")
    end

    if tool_name == "preview_build" then return preview_build(args, player_name) end
    if tool_name == "print_build" then return print_build(args, player_name) end
    if tool_name == "get_node" then return get_node(args) end
    if tool_name == "asset_search" then return asset_search(args) end
    return { ok = false, success = false, message = "unknown tool: " .. tostring(tool_name) }
end

local function get_context()
    return table.concat({
        "Node Printer Preview - experimental voxel-CSG builder.",
        "For complex construction requests, load its manual before acting:",
        "  llm_connect.context.load(\"skills.node_printer_preview\")",
        "Stable tools: preview_build, print_build, get_node. Optional material helper: asset_search.",
        "Builds use ordered operations: solid, shell, cut, paint.",
        "Use this skill as the construction path for node printing tasks.",
    }, "\n")
end

local function manual(player_name)
    return table.concat({
        get_context(player_name),
        "",
        "Canonical invocation:",
        "  llm_connect.skills.node_printer_preview.run(\"<tool_name>\", args, player_name)",
        "",
        "Workflow:",
        "  1. Build a table with anchor=\"player\", ops={...}, and optional max_nodes.",
        "  2. Use common registered nodes directly for ordinary builds.",
        "  3. Call preview_build and check preview.ok before writing anything.",
        "  4. If execution is still required, call print_build with the same build after preview succeeds.",
        "",
        "Operations are ordered. Later operations override earlier operations.",
        "  solid: fill the selected shape with node.",
        "  shell: write only the outer boundary of a box.",
        "  cut: write air to a box or patch.",
        "  paint: overwrite a box, column or patch with node.",
        "",
        "Coordinates:",
        "  anchor=\"player\" is the default. at={x=...,y=...,z=...} is relative to the player's integer position.",
        "  Do not use direction vectors, rotations, frames or facing systems in this skill.",
        "",
        "Box schema:",
        "  {op=\"solid\", shape=\"box\", at={x=-4,y=0,z=-3}, size={x=9,y=1,z=7}, node=\"default:stone\"}",
        "  size values must be positive integers. shell and cut support only shape=\"box\" in the MVP.",
        "",
        "Column schema:",
        "  {op=\"solid\", shape=\"column\", at={x=-3,y=1,z=-3}, height=5, node=\"default:tree\"}",
        "  A column is one node wide and grows upward along positive Y. column supports solid and paint only.",
        "",
        "Patch schema:",
        "  {op=\"cut\", shape=\"patch\", on={shape=\"box\", at={x=-4,y=1,z=-3}, size={x=9,y=5,z=7}, face=\"front\"}, at={u=4,v=0}, size={u=1,v=2}, depth=1}",
        "  A patch selects a rectangle on a box face using local surface coordinates u and v; depth controls how far it writes inward.",
        "  Faces: front/back use u=x and v=y; left/right use u=z and v=y; top/bottom use u=x and v=z.",
        "  patch supports solid, cut and paint. Use it for apertures, panels, trims, vents and inlays without object-specific helpers.",
        "",
        "Materials:",
        "  For ordinary builds prefer these common registered nodes directly: default:stone, default:cobble, default:wood, default:tree, default:glass, default:brick, air.",
        "  Use default:brick as the normal accent/stripe material unless the user asks for a specific unusual material.",
        "  asset_search is optional. Use it only when a requested material is unusual, unknown, or after an unknown-node error.",
        "  Optional search example: local assets = llm_connect.skills.node_printer_preview.run(\"asset_search\", {queries={\"copper\", \"metal\"}, limit=8}, player_name)",
        "  asset_search returns assets.data.results[i].name. Convenience aliases: assets.results, assets.matches, assets.nodes, assets.node and assets.first.",
        "  Do not invent nodes such as default:red_brick or default:gray_wool unless asset_search or get_node context confirms the node exists.",
        "  Unknown nodes fail during preview/print validation before writes.",
        "",
        "Composition example:",
        "  local build = {",
        "      anchor = \"player\",",
        "      ops = {",
        "          {op=\"solid\", shape=\"box\", at={x=-4,y=0,z=-3}, size={x=9,y=1,z=7}, node=\"default:stone\"},",
        "          {op=\"shell\", shape=\"box\", at={x=-4,y=1,z=-3}, size={x=9,y=5,z=7}, node=\"default:stone\"},",
        "          {op=\"solid\", shape=\"box\", at={x=-5,y=6,z=-4}, size={x=11,y=1,z=9}, node=\"default:wood\"},",
        "          {op=\"cut\", shape=\"patch\", on={shape=\"box\", at={x=-4,y=1,z=-3}, size={x=9,y=5,z=7}, face=\"front\"}, at={u=4,v=0}, size={u=1,v=3}, depth=1},",
        "          {op=\"paint\", shape=\"patch\", on={shape=\"box\", at={x=-4,y=1,z=-3}, size={x=9,y=5,z=7}, face=\"front\"}, at={u=2,v=2}, size={u=1,v=1}, depth=1, node=\"default:glass\"},",
        "          {op=\"paint\", shape=\"patch\", on={shape=\"box\", at={x=-4,y=1,z=-3}, size={x=9,y=5,z=7}, face=\"front\"}, at={u=6,v=2}, size={u=1,v=1}, depth=1, node=\"default:glass\"},",
        "          {op=\"paint\", shape=\"patch\", on={shape=\"box\", at={x=-4,y=1,z=-3}, size={x=9,y=5,z=7}, face=\"right\"}, at={u=1,v=3}, size={u=5,v=1}, depth=1, node=\"default:brick\"},",
        "      },",
        "      max_nodes = 20000,",
        "  }",
        "",
        "  local preview = llm_connect.skills.node_printer_preview.run(\"preview_build\", build, player_name)",
        "  if not (preview and preview.ok) then",
        "      return {done=false, continue=true, message=preview and preview.message or \"Build preview failed\"}",
        "  end",
        "  local printed = llm_connect.skills.node_printer_preview.run(\"print_build\", build, player_name)",
        "  if not (printed and printed.ok) then",
        "      return {done=false, continue=true, message=printed and printed.message or \"Build print failed\"}",
        "  end",
        "  return {done=true, message=printed.message or \"Voxel-CSG build printed\"}",
        "",
        "This example adds a floor, adds a stone hollow shell, adds a wood roof, cuts a doorway, paints two glass windows, and paints a narrow brick stripe on the right wall.",
        "",
        "Error avoidance:",
        "  Use only shape=\"box\", shape=\"column\" or shape=\"patch\"; sphere/cylinder/stairs/roof macros are not implemented.",
        "  Use size={x=...,y=...,z=...} for boxes, height=N for columns, and size={u=...,v=...} for patches.",
        "  Keep max_nodes conservative; plans exceeding it fail before world mutation.",
    }, "\n")
end

local function normalize_run_args(a, b, c)
    if type(a) == "string" and type(b) == "table" and type(c) == "string" then return a, b, c end
    if type(a) == "string" and type(b) == "string" and type(c) == "table" then return a, c, b end
    if type(a) == "table" and type(b) == "string" then
        local tool = a.tool or a.name or a.action
        local params = a.args or a.params or a.parameters or a
        return tool, params, b
    end
    if type(a) == "table" then
        local tool = a.tool or a.name or a.action
        local params = a.args or a.params or a.parameters or a
        local player = a.player_name or a.player or b or c
        return tool, params, player
    end
    return a, b, c
end

local function do_register()
    local root = rawget(_G, "llm_connect") or {}
    rawset(_G, "llm_connect", root)
    root.skills = root.skills or {}

    root.skills.node_printer_preview = {
        run = function(a, b, c)
            local tool_name, args, player_name = normalize_run_args(a, b, c)
            return run_tool(tool_name, args or {}, player_name)
        end,
        get_context = get_context,
    }

    if root.context and type(root.context.register_section) == "function" then
        root.context.register_section({
            id = "skills.node_printer_preview",
            title = "Node Printer Preview voxel-CSG manual",
            summary = "Build structures using ordered solid, shell, cut and paint operations.",
            tags = {
                "skill",
                "node_printer",
                "node_printer_preview",
                "building",
                "voxel",
                "csg",
                "construction",
            },
            required_priv = "llm_agent",
            provider = manual,
        })
        if type(root.context.register_aliases) == "function" then
            root.context.register_aliases({
                node_printer = "skills.node_printer_preview",
                node_printer_preview = "skills.node_printer_preview",
                voxel_csg = "skills.node_printer_preview",
                building_preview = "skills.node_printer_preview",
            })
        end
    end

    if root.registry and type(root.registry.register_skill) == "function" then
        root.registry.register_skill({
            id = SKILL_ID,
            label = "Node Printer Preview",
            version = "0.1.0-dev",
            description = "Experimental voxel-CSG builder using ordered solid, shell, cut and paint operations.",
            required_priv = "llm_agent",
            default_enabled = false,
            available = function()
                return type(core.set_node) == "function"
                    and type(core.registered_nodes) == "table"
            end,
            context_section = "skills.node_printer_preview",
            context_aliases = {
                "node_printer",
                "node_printer_preview",
                "voxel_csg",
                "building_preview",
            },
            get_context = get_context,
            tool_count = 4,
        })
    else
        core.log("warning", "[node_printer_preview] registry unavailable; skill API installed but not registered")
    end

    return root.skills.node_printer_preview
end

local api = do_register()
core.log("action", "[node_printer_preview] loaded")
return api
