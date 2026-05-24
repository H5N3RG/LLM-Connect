-- ===========================================================================
--  skills/mapgen_painter/mapgen_painter.lua — LLM Connect Mapgen Painter
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Prototype Lua-first skill for queued low-level terrain painting during
--  map generation. It validates requests up front, persists them in mod
--  storage, and applies matching operations through VoxelManip from the
--  on_generated callback.
-- ===========================================================================

local core = core

local SKILL_ID = "mapgen_painter"
local STORAGE_KEY = "mapgen_painter.requests.v1"

local DEFAULT_LIMITS = {
    max_operation_volume = 16 * 16 * 16,
    max_request_volume = 32 * 32 * 32,
    max_operations_per_request = 64,
    max_requests = 256,
    max_ops_per_generated_chunk = 96,
}

local NODE_ALIASES = {
    ["default:oak_log"]       = "default:tree",
    ["default:oak_tree"]      = "default:tree",
    ["default:oak_wood"]      = "default:wood",
    ["default:oak_planks"]    = "default:wood",
    ["default:wooden_planks"] = "default:wood",
    ["default:planks"]        = "default:wood",
    ["default:log"]           = "default:tree",
    ["default:cobblestone"]   = "default:cobble",
    ["default:grass"]         = "default:dirt_with_grass",
    ["minecraft:oak_log"]     = "default:tree",
    ["minecraft:oak_planks"]  = "default:wood",
    ["minecraft:cobblestone"] = "default:cobble",
}

local state = {
    loaded = false,
    requests = {},
    next_id = 1,
    content_ids = {},
}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function now()
    return os.time and os.time() or 0
end

local function copy_pos(p)
    return { x = math.floor(tonumber(p and p.x) or 0), y = math.floor(tonumber(p and p.y) or 0), z = math.floor(tonumber(p and p.z) or 0) }
end

local function make_pos(value, fallback)
    if type(value) == "table" then return copy_pos(value) end
    if type(value) == "string" then
        local x, y, z = value:match("^%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*$")
        if x then return { x = math.floor(tonumber(x) or 0), y = math.floor(tonumber(y) or 0), z = math.floor(tonumber(z) or 0) } end
    end
    return fallback and copy_pos(fallback) or nil
end

local function sorted_bounds(a, b)
    a = copy_pos(a)
    b = copy_pos(b)
    return {
        x = math.min(a.x, b.x),
        y = math.min(a.y, b.y),
        z = math.min(a.z, b.z),
    }, {
        x = math.max(a.x, b.x),
        y = math.max(a.y, b.y),
        z = math.max(a.z, b.z),
    }
end

local function volume(minp, maxp)
    if not minp or not maxp then return 0 end
    return (maxp.x - minp.x + 1) * (maxp.y - minp.y + 1) * (maxp.z - minp.z + 1)
end

local function intersects(a_min, a_max, b_min, b_max)
    return a_min.x <= b_max.x and a_max.x >= b_min.x
        and a_min.y <= b_max.y and a_max.y >= b_min.y
        and a_min.z <= b_max.z and a_max.z >= b_min.z
end

local function clip_bounds(a_min, a_max, b_min, b_max)
    if not intersects(a_min, a_max, b_min, b_max) then return nil, nil end
    return {
        x = math.max(a_min.x, b_min.x),
        y = math.max(a_min.y, b_min.y),
        z = math.max(a_min.z, b_min.z),
    }, {
        x = math.min(a_max.x, b_max.x),
        y = math.min(a_max.y, b_max.y),
        z = math.min(a_max.z, b_max.z),
    }
end

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
    local original = trim(node_str):lower()
    if original == "" then return nil, "node name is empty" end
    if original == "air" then return "air" end

    local candidates = { original }
    if NODE_ALIASES[original] then table.insert(candidates, 1, NODE_ALIASES[original]) end
    if not original:find(":", 1, true) then table.insert(candidates, "default:" .. original) end
    if original:find("cobble", 1, true) then table.insert(candidates, "default:cobble") end
    if original:find("wood", 1, true) or original:find("plank", 1, true) then table.insert(candidates, "default:wood") end
    if original:find("stone", 1, true) then table.insert(candidates, "default:stone") end
    if original:find("dirt", 1, true) then table.insert(candidates, "default:dirt") end

    local seen = {}
    for _, candidate in ipairs(candidates) do
        if candidate and not seen[candidate] then
            seen[candidate] = true
            if registered_node(candidate) then return candidate end
            local aliased = resolve_registered_alias(candidate)
            if aliased then return aliased end
        end
    end
    return nil, "unknown node '" .. tostring(node_str) .. "'"
end

local function get_content_id(node)
    if not state.content_ids[node] then
        local ok, id = pcall(core.get_content_id, node)
        if not ok or id == nil then return nil, "no content id for " .. tostring(node) end
        state.content_ids[node] = id
    end
    return state.content_ids[node]
end

local function storage()
    if type(core.get_mod_storage) ~= "function" then return nil end
    return core.get_mod_storage()
end

local function save_requests()
    local store = storage()
    if not store then return false, "mod storage unavailable" end
    local encoded = core.serialize({
        next_id = state.next_id,
        requests = state.requests,
    })
    store:set_string(STORAGE_KEY, encoded or "")
    return true
end

local function load_requests()
    if state.loaded then return true end
    state.loaded = true
    local store = storage()
    if not store then return false, "mod storage unavailable" end
    local raw = store:get_string(STORAGE_KEY)
    if raw and raw ~= "" then
        local ok, decoded = pcall(core.deserialize, raw)
        if ok and type(decoded) == "table" then
            state.requests = type(decoded.requests) == "table" and decoded.requests or {}
            state.next_id = tonumber(decoded.next_id) or (#state.requests + 1)
        else
            core.log("warning", "[mapgen_painter] stored queue could not be decoded; starting empty")
            state.requests = {}
            state.next_id = 1
        end
    end
    return true
end

local function normalize_limits(args)
    local limits = {}
    for k, v in pairs(DEFAULT_LIMITS) do limits[k] = v end
    if type(args) == "table" and type(args.limits) == "table" then
        for k, v in pairs(args.limits) do
            if limits[k] ~= nil then limits[k] = math.max(1, math.floor(tonumber(v) or limits[k])) end
        end
    end
    return limits
end

local function request_aabb(ops)
    local minp, maxp
    for _, op in ipairs(ops or {}) do
        local a = op.minp or op.pos
        local b = op.maxp or op.pos
        if a and b then
            if not minp then
                minp, maxp = copy_pos(a), copy_pos(b)
            else
                minp.x = math.min(minp.x, a.x); minp.y = math.min(minp.y, a.y); minp.z = math.min(minp.z, a.z)
                maxp.x = math.max(maxp.x, b.x); maxp.y = math.max(maxp.y, b.y); maxp.z = math.max(maxp.z, b.z)
            end
        end
    end
    return minp, maxp
end

local function parse_text_command(text)
    text = trim(text)
    local node, ax, ay, az, bx, by, bz = text:match("^fill%s+([%w_:%-]+)%s+from%s+([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s+to%s+([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*$")
    if node then
        return {{
            kind = "fill",
            node = node,
            from = { x = ax, y = ay, z = az },
            to = { x = bx, y = by, z = bz },
        }}
    end

    local x, y, z
    node, x, y, z = text:match("^set_node%s+([%w_:%-]+)%s+at%s+([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*$")
    if node then
        return {{
            kind = "set_node",
            node = node,
            pos = { x = x, y = y, z = z },
        }}
    end

    local from_node, to_node
    from_node, to_node, ax, ay, az, bx, by, bz = text:match("^replace_area%s+([%w_:%-]+)%s+with%s+([%w_:%-]+)%s+from%s+([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s+to%s+([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*,%s*([%-%.%d]+)%s*$")
    if from_node then
        return {{
            kind = "replace_area",
            from_node = from_node,
            to_node = to_node,
            from = { x = ax, y = ay, z = az },
            to = { x = bx, y = by, z = bz },
        }}
    end

    return nil, "could not parse text command"
end

local function input_operations(args)
    if type(args) ~= "table" then return nil, "args must be a table" end
    if type(args.text) == "string" or type(args.command) == "string" then
        return parse_text_command(args.text or args.command)
    end
    if type(args.operations) == "table" then return args.operations end
    if type(args.ops) == "table" then return args.ops end
    if type(args[1]) == "table" then return args end
    if type(args.kind or args.action or args.type) == "string" then return { args } end
    return nil, "missing operations"
end

local function normalize_operation(raw, index, limits)
    if type(raw) ~= "table" then return nil, "operation #" .. tostring(index) .. " must be a table" end
    local kind = trim(raw.kind or raw.action or raw.type):lower()
    if kind == "" then return nil, "operation #" .. tostring(index) .. " missing kind" end

    local op = {
        kind = kind,
        priority = math.floor(tonumber(raw.priority) or 0),
    }

    if kind == "set_node" then
        local pos = make_pos(raw.pos or raw.at or raw)
        if not pos then return nil, "set_node requires pos" end
        local node, err = resolve_node(raw.node or raw.name)
        if not node then return nil, err end
        op.pos = pos
        op.minp, op.maxp = pos, pos
        op.node = node
        return op
    end

    if kind == "fill" or kind == "replace_area" or kind == "carve_cave" or kind == "add_noise_layer" then
        local p1 = make_pos(raw.from or raw.min or raw.minp or raw.p1 or raw.pos1)
        local p2 = make_pos(raw.to or raw.max or raw.maxp or raw.p2 or raw.pos2)
        if not p1 or not p2 then return nil, kind .. " requires from/to bounds" end
        op.minp, op.maxp = sorted_bounds(p1, p2)
        local vol = volume(op.minp, op.maxp)
        if vol > limits.max_operation_volume then
            return nil, kind .. " volume " .. tostring(vol) .. " exceeds max_operation_volume=" .. tostring(limits.max_operation_volume)
        end
        if kind == "fill" then
            local node, err = resolve_node(raw.node or raw.name)
            if not node then return nil, err end
            op.node = node
        elseif kind == "replace_area" then
            local from_node, ferr = resolve_node(raw.from_node or raw.replace or raw.source or raw.old or raw.match)
            if not from_node then return nil, "replace_area source: " .. ferr end
            local to_node, terr = resolve_node(raw.to_node or raw.with or raw.target or raw.new or raw.node)
            if not to_node then return nil, "replace_area target: " .. terr end
            op.from_node = from_node
            op.to_node = to_node
        elseif kind == "carve_cave" then
            op.node = "air"
            op.radius = math.max(1, tonumber(raw.radius) or 4)
            op.seed = math.floor(tonumber(raw.seed) or 0)
            op.threshold = math.max(0, math.min(1, tonumber(raw.threshold) or 0.42))
        elseif kind == "add_noise_layer" then
            local node, err = resolve_node(raw.node or raw.name)
            if not node then return nil, err end
            op.node = node
            op.seed = math.floor(tonumber(raw.seed) or 0)
            op.threshold = math.max(0, math.min(1, tonumber(raw.threshold) or 0.55))
        end
        return op
    end

    return nil, "unknown operation kind '" .. kind .. "'"
end

local function normalize_request(args, player_name, dry_run)
    load_requests()
    local limits = normalize_limits(args)
    local raw_ops, err = input_operations(args)
    if not raw_ops then return nil, err end
    if #raw_ops == 0 then return nil, "no operations supplied" end
    if #raw_ops > limits.max_operations_per_request then
        return nil, "too many operations: " .. tostring(#raw_ops)
    end

    local ops = {}
    for i, raw in ipairs(raw_ops) do
        local op, oerr = normalize_operation(raw, i, limits)
        if not op then return nil, oerr end
        ops[#ops + 1] = op
    end
    table.sort(ops, function(a, b) return (a.priority or 0) < (b.priority or 0) end)

    local minp, maxp = request_aabb(ops)
    if not minp or not maxp then return nil, "request has no writable area" end
    local req_volume = volume(minp, maxp)
    if req_volume > limits.max_request_volume then
        return nil, "request bounds volume " .. tostring(req_volume) .. " exceeds max_request_volume=" .. tostring(limits.max_request_volume)
    end

    return {
        id = dry_run and 0 or state.next_id,
        label = trim(args.label or args.name or ""),
        player_name = player_name or args.player_name or "",
        created_at = now(),
        enabled = args.enabled ~= false,
        once = args.once == true,
        applied = 0,
        minp = minp,
        maxp = maxp,
        operations = ops,
    }
end

local function preview(args, player_name)
    local request, err = normalize_request(args or {}, player_name, true)
    if not request then return { ok = false, success = false, message = err } end
    return {
        ok = true,
        success = true,
        message = string.format("Mapgen paint request validated: %d operation(s), bounds (%d,%d,%d)..(%d,%d,%d)",
            #request.operations, request.minp.x, request.minp.y, request.minp.z, request.maxp.x, request.maxp.y, request.maxp.z),
        data = request,
    }
end

local function queue(args, player_name)
    local request, err = normalize_request(args or {}, player_name, false)
    if not request then return { ok = false, success = false, message = err } end
    if #state.requests >= DEFAULT_LIMITS.max_requests then
        return { ok = false, success = false, message = "request queue is full" }
    end
    state.next_id = state.next_id + 1
    state.requests[#state.requests + 1] = request
    local ok, serr = save_requests()
    if not ok then return { ok = false, success = false, message = serr } end
    return {
        ok = true,
        success = true,
        message = "Queued mapgen paint request #" .. tostring(request.id),
        data = request,
    }
end

local function list_requests(args)
    load_requests()
    args = args or {}
    local out = {}
    local only_enabled = args.enabled == true
    for _, req in ipairs(state.requests) do
        if not only_enabled or req.enabled ~= false then
            out[#out + 1] = {
                id = req.id,
                label = req.label,
                player_name = req.player_name,
                enabled = req.enabled ~= false,
                once = req.once == true,
                applied = req.applied or 0,
                minp = req.minp,
                maxp = req.maxp,
                operations = #(req.operations or {}),
            }
        end
    end
    return {
        ok = true,
        success = true,
        message = string.format("%d mapgen paint request(s)", #out),
        data = { requests = out, next_id = state.next_id },
    }
end

local function clear_requests(args)
    load_requests()
    args = args or {}
    local id = tonumber(args.id or args.request_id)
    local removed = 0
    if id then
        local kept = {}
        for _, req in ipairs(state.requests) do
            if tonumber(req.id) == id then removed = removed + 1 else kept[#kept + 1] = req end
        end
        state.requests = kept
    else
        removed = #state.requests
        state.requests = {}
    end
    local ok, err = save_requests()
    if not ok then return { ok = false, success = false, message = err } end
    return {
        ok = true,
        success = true,
        message = "Removed " .. tostring(removed) .. " mapgen paint request(s)",
        data = { removed = removed },
    }
end

local function deterministic_noise(x, y, z, seed)
    local n = (x * 734287 + y * 912271 + z * 438289 + seed * 19937) % 1000003
    n = (n * 1103515245 + 12345) % 2147483647
    return (n % 10000) / 10000
end

local function apply_fill(data, area, op, minp, maxp)
    local cid, err = get_content_id(op.node)
    if not cid then return 0, err end
    local count = 0
    for z = minp.z, maxp.z do
        for y = minp.y, maxp.y do
            for x = minp.x, maxp.x do
                data[area:index(x, y, z)] = cid
                count = count + 1
            end
        end
    end
    return count
end

local function apply_replace(data, area, op, minp, maxp)
    local from_cid, ferr = get_content_id(op.from_node)
    if not from_cid then return 0, ferr end
    local to_cid, terr = get_content_id(op.to_node)
    if not to_cid then return 0, terr end
    local count = 0
    for z = minp.z, maxp.z do
        for y = minp.y, maxp.y do
            for x = minp.x, maxp.x do
                local vi = area:index(x, y, z)
                if data[vi] == from_cid then
                    data[vi] = to_cid
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function apply_noise(data, area, op, minp, maxp)
    local cid, err = get_content_id(op.node)
    if not cid then return 0, err end
    local count = 0
    for z = minp.z, maxp.z do
        for y = minp.y, maxp.y do
            for x = minp.x, maxp.x do
                if deterministic_noise(x, y, z, op.seed or 0) >= (op.threshold or 0.5) then
                    data[area:index(x, y, z)] = cid
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function apply_cave(data, area, op, minp, maxp)
    local cid, err = get_content_id("air")
    if not cid then return 0, err end
    local cx = (op.minp.x + op.maxp.x) / 2
    local cy = (op.minp.y + op.maxp.y) / 2
    local cz = (op.minp.z + op.maxp.z) / 2
    local rx = math.max(1, (op.maxp.x - op.minp.x + 1) / 2)
    local ry = math.max(1, (op.maxp.y - op.minp.y + 1) / 2)
    local rz = math.max(1, (op.maxp.z - op.minp.z + 1) / 2)
    local count = 0
    for z = minp.z, maxp.z do
        for y = minp.y, maxp.y do
            for x = minp.x, maxp.x do
                local dx = (x - cx) / rx
                local dy = (y - cy) / ry
                local dz = (z - cz) / rz
                if (dx * dx + dy * dy + dz * dz) <= 1.0 and deterministic_noise(x, y, z, op.seed or 0) >= (op.threshold or 0.42) then
                    data[area:index(x, y, z)] = cid
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function apply_generated(minp, maxp)
    load_requests()
    if #state.requests == 0 then return end

    local vm = core.get_mapgen_object and core.get_mapgen_object("voxelmanip")
    if not vm then return end
    local emin, emax = vm:get_emerged_area()
    local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
    local data = vm:get_data()
    local changed = false
    local writes = 0
    local ops_seen = 0
    local queue_changed = false

    for _, req in ipairs(state.requests) do
        local req_writes = 0
        if req.enabled ~= false and intersects(req.minp, req.maxp, minp, maxp) then
            for _, op in ipairs(req.operations or {}) do
                if ops_seen >= DEFAULT_LIMITS.max_ops_per_generated_chunk then break end
                local op_min, op_max = op.minp or op.pos, op.maxp or op.pos
                local cmin, cmax = clip_bounds(op_min, op_max, minp, maxp)
                if cmin and cmax then
                    local count, err
                    if op.kind == "fill" or op.kind == "set_node" then
                        count, err = apply_fill(data, area, op, cmin, cmax)
                    elseif op.kind == "replace_area" then
                        count, err = apply_replace(data, area, op, cmin, cmax)
                    elseif op.kind == "add_noise_layer" then
                        count, err = apply_noise(data, area, op, cmin, cmax)
                    elseif op.kind == "carve_cave" then
                        count, err = apply_cave(data, area, op, cmin, cmax)
                    else
                        count, err = 0, "unknown op kind at execution: " .. tostring(op.kind)
                    end
                    if err then
                        core.log("warning", "[mapgen_painter] skipped op in request #" .. tostring(req.id) .. ": " .. tostring(err))
                    elseif count and count > 0 then
                        changed = true
                        writes = writes + count
                        req_writes = req_writes + count
                        req.applied = (req.applied or 0) + count
                    end
                    ops_seen = ops_seen + 1
                end
            end
            if req.once == true and req_writes > 0 then
                req.enabled = false
                queue_changed = true
            end
        end
    end

    if changed then
        vm:set_data(data)
        vm:write_to_map()
        if type(vm.update_map) == "function" then vm:update_map() end
        save_requests()
        core.log("action", "[mapgen_painter] applied " .. tostring(writes) .. " voxel writes in generated area")
    elseif queue_changed then
        save_requests()
    end
end

local function get_context(player_name)
    load_requests()
    local count = #state.requests
    return table.concat({
        "Mapgen Painter skill is active (experimental).",
        "Use it for queued low-level terrain paint operations during map generation.",
        "Preferred call form: llm_connect.skills.mapgen_painter.run('preview', {operations={...}}, player_name), then run('queue', ...).",
        "Supported operation kinds: set_node, fill, replace_area, carve_cave, add_noise_layer.",
        "Coordinates are absolute map coordinates and are clipped to generated chunks.",
        "Current queued requests: " .. tostring(count),
        "Limits: max op volume " .. tostring(DEFAULT_LIMITS.max_operation_volume) .. ", max request volume " .. tostring(DEFAULT_LIMITS.max_request_volume) .. ".",
    }, "\n")
end

local function run_tool(tool_name, args, player_name)
    if type(player_name) == "table" and type(args) == "string" then
        local temp = args
        args = player_name
        player_name = temp
    end
    tool_name = trim(tool_name):lower()
    if tool_name == "preview" or tool_name == "validate" then return preview(args or {}, player_name) end
    if tool_name == "queue" or tool_name == "enqueue" then return queue(args or {}, player_name) end
    if tool_name == "list" or tool_name == "list_requests" then return list_requests(args or {}) end
    if tool_name == "clear" or tool_name == "clear_requests" then return clear_requests(args or {}) end
    return { ok = false, success = false, message = "unknown tool '" .. tostring(tool_name) .. "'" }
end

local root = rawget(_G, "llm_connect") or {}
rawset(_G, "llm_connect", root)
root.skills = root.skills or {}
root.skills.mapgen_painter = {
    run = function(tool_name, args, player_name) return run_tool(tool_name, args or {}, player_name) end,
    preview = function(args, player_name) return preview(args or {}, player_name) end,
    queue = function(args, player_name) return queue(args or {}, player_name) end,
    list_requests = function(args) return list_requests(args or {}) end,
    clear_requests = function(args) return clear_requests(args or {}) end,
    get_context = get_context,
}

if root.context and type(root.context.register_section) == "function" then
    root.context.register_section({
        id = "skills.mapgen_painter",
        title = "Mapgen Painter skill manual",
        summary = "Queued VoxelManip terrain paint operations for map generation.",
        tags = {"skill", "mapgen", "terrain", "voxelmanip", "painter"},
        required_priv = "llm_agent",
        provider = function(player_name)
            return table.concat({
                get_context(player_name),
                "",
                "Experimental skill: preview carefully before queueing; full live-world behavioral testing is deferred.",
                "",
                "Examples:",
                "  llm_connect.skills.mapgen_painter.run('preview', {operations={{kind='fill', from={x=0,y=0,z=0}, to={x=15,y=8,z=15}, node='default:stone'}}}, player_name)",
                "  llm_connect.skills.mapgen_painter.run('queue', {label='stone block', operations={{kind='fill', from={x=0,y=0,z=0}, to={x=15,y=8,z=15}, node='default:stone'}}}, player_name)",
                "  llm_connect.skills.mapgen_painter.run('queue', {text='fill default:stone from 0,0,0 to 15,8,15'}, player_name)",
                "  llm_connect.skills.mapgen_painter.run('list', {}, player_name)",
                "  llm_connect.skills.mapgen_painter.run('clear', {id=1}, player_name)",
                "",
                "Operation table fields:",
                "  set_node: {kind='set_node', pos={x=0,y=0,z=0}, node='default:stone'}",
                "  fill: {kind='fill', from={x=0,y=0,z=0}, to={x=15,y=8,z=15}, node='default:stone'}",
                "  replace_area: {kind='replace_area', from=..., to=..., from_node='default:dirt', to_node='default:stone'}",
                "  carve_cave: {kind='carve_cave', from=..., to=..., seed=123, threshold=0.42}",
                "  add_noise_layer: {kind='add_noise_layer', from=..., to=..., node='default:stone', seed=123, threshold=0.55}",
                "All coordinates are absolute map coordinates. Preview before queueing large areas.",
            }, "\n")
        end,
    })
    if type(root.context.register_aliases) == "function" then
        root.context.register_aliases({
            mapgen = "skills.mapgen_painter",
            mapgen_painter = "skills.mapgen_painter",
            terrain_painter = "skills.mapgen_painter",
        })
    end
end

if type(core.register_on_generated) == "function" then
    core.register_on_generated(function(minp, maxp)
        local ok, err = pcall(apply_generated, minp, maxp)
        if not ok then core.log("warning", "[mapgen_painter] on_generated failed: " .. tostring(err)) end
    end)
else
    core.log("warning", "[mapgen_painter] core.register_on_generated unavailable; queue/preview only")
end

if root.registry and type(root.registry.register_skill) == "function" then
    root.registry.register_skill({
        id = SKILL_ID,
        label = "Mapgen Painter",
        version = "0.1.0-prototype",
        description = "Experimental queued low-level VoxelManip terrain painter for map generation experiments.",
        required_priv = "llm_agent",
        default_enabled = false,
        available = function()
            return type(core.register_on_generated) == "function"
                and type(core.get_mapgen_object) == "function"
                and type(core.get_content_id) == "function"
        end,
        context_section = "skills.mapgen_painter",
        context_aliases = {"mapgen", "mapgen_painter", "terrain_painter"},
        get_context = get_context,
        tool_count = 4,
    })
else
    core.log("warning", "[mapgen_painter] registry unavailable; skill API installed but not registered")
end

core.log("action", "[mapgen_painter] loaded as Lua-first skill prototype")
return root.skills.mapgen_painter
