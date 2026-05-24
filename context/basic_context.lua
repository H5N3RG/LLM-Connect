-- ===========================================================================
--  basic_context.lua — LLM Connect 1.1 Lua-first Basic Context Provider
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  ROLE:
--    Small, stable world/player/server context for chat and agent turns.
--    This module deliberately keeps plain chat separate from agent runtime
--    instructions. Skills provide their own context/schema through registry.lua
--    and context_registry.lua when enabled.
--
--  TWO LAYERS (per-player configurable, selectable in config_gui):
--
--  BASIC (internal value: "basis"; always active, cannot be disabled):
--    - Player name, position, HP, breath, held item
--    - Server name, game, engine version, in-game time, online player count
--    - All other players: name + position
--    - Chat mode excludes the Lua action contract; agent mode adds it explicitly
--
--  EXTENDED (internal value: "erweitert"; opt-in per player):
--    - Everything from BASIC
--    - Nodes / Items / Entities from Luanti registry
--    - Filtered by type toggle (Nodes ✓/✗, Items ✓/✗, Entities ✓/✗)
--    - Filtered by mod picker: player selects which mods to include
--    - Picker state is persisted per world (mod-filtered selection)
--
--  IMPORTANT ARCHITECTURE RULE:
--    Chatcommands, WorldEdit APIs, node manipulation helpers, Mesecons bridges,
--    etc. belong to Lua-first skills. basic_context.lua only gives general
--    orientation and a minimal safe Lua runtime contract.
--
--  PUBLIC API:
--    M.get_chat(player_name)                   → string  (plain chat context, no tools)
--    M.get_agent(player_name)                  → string  (agent context with Lua contract)
--    M.get(player_name)                        → string  (compat alias for get_agent)
--    M.get_layer(player_name)                  → "basis" | "erweitert"
--    M.set_layer(player_name, layer)           → void
--    M.get_types(player_name)                  → { nodes=bool, items=bool, entities=bool }
--    M.set_type(player_name, type_key, bool)   → void
--    M.get_mod_picker_state(player_name)       → { available=[], selected={} }
--    M.set_mod_selected(player_name, mod, bool)→ void
--    M.select_all_mods(player_name)            → void
--    M.select_no_mods(player_name)             → void
--    M.save_state()                            → void  (callable externally)
--
-- ===========================================================================

local core = core
local M    = {}

-- ===========================================================================
-- Persistent state
-- ===========================================================================

-- File storing all player states
local STATE_FILE = core.get_worldpath() .. "/llm_basic_context_state.json"

-- In-memory state: { [player_name] = { layer, types, mods } }
-- layer: "basis" | "erweitert"
-- types: { nodes=bool, items=bool, entities=bool }
-- mods:  { [mod_name] = bool }   — nil = not yet initialised (all mods on)
local player_states = {}

-- Loads persisted state from the JSON file
local function load_state()
    local f = io.open(STATE_FILE, "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return end
    local ok, data = pcall(core.parse_json, raw)
    if ok and type(data) == "table" then
        -- Migrate loaded data into player_states
        for pname, ps in pairs(data) do
            player_states[pname] = {
                layer = ps.layer or "basis",
                types = {
                    nodes    = ps.types and ps.types.nodes    ~= false or true,
                    items    = ps.types and ps.types.items    ~= false or true,
                    entities = ps.types and ps.types.entities ~= false or true,
                },
                mods = ps.mods or nil,
            }
        end
        core.log("action", "[basic_context] state loaded: "
            .. tostring((function() local n=0; for _ in pairs(data) do n=n+1 end; return n end)())
            .. " player(s)")
    else
        core.log("warning", "[basic_context] state file could not be parsed")
    end
end

-- Save the current state into the JSON file
function M.save_state()
    local ok, encoded = pcall(core.write_json, player_states)
    if not ok then
        core.log("error", "[basic_context] save_state: JSON encoding failed: "
            .. tostring(encoded))
        return
    end
    local f = io.open(STATE_FILE, "w")
    if not f then
        core.log("error", "[basic_context] save_state: could not open file: "
            .. STATE_FILE)
        return
    end
    f:write(encoded)
    f:close()
end

-- Get or initialise state for a player (lazy-init)
local function get_state(player_name)
    if not player_states[player_name] then
        player_states[player_name] = {
            layer = "basis",
            types = { nodes = true, items = true, entities = true },
            mods  = nil,   -- nil = all mods active until picker is opened
        }
    end
    return player_states[player_name]
end

-- Save state when player leaves (keeps player_states tidy,
-- avoids accumulating stale entries)
core.register_on_leaveplayer(function(player)
    M.save_state()
end)

-- ===========================================================================
-- Mod list (cached, does not change after mods_loaded)
-- ===========================================================================

local _mod_list_cache = nil

local function get_all_mods()
    if not _mod_list_cache then
        _mod_list_cache = core.get_modnames()
        table.sort(_mod_list_cache)
    end
    return _mod_list_cache
end

-- Lazy-init mod state for a player: all mods selected by default
local function ensure_mod_state(ps)
    if ps.mods == nil then
        ps.mods = {}
        for _, mod in ipairs(get_all_mods()) do
            ps.mods[mod] = true
        end
    end
end

local function safe_text(v, fallback)
    v = tostring(v or fallback or "")
    v = v:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return v
end

local function groups_preview(groups, max_items)
    if type(groups) ~= "table" then return "" end
    local keys = {}
    for k, val in pairs(groups) do
        if val and val ~= 0 then keys[#keys + 1] = tostring(k) end
    end
    table.sort(keys)
    local out = {}
    for i = 1, math.min(#keys, max_items or 4) do out[#out + 1] = keys[i] end
    if #keys > #out then out[#out + 1] = "…" end
    return table.concat(out, ",")
end

-- ===========================================================================
-- Caches for expensive registry queries.
-- Nodes/Items/Entities don't change after mods_loaded — build once.
-- ===========================================================================

-- { [mod_name] = { nodes={}, items={}, entities={} } }
local _registry_cache = nil

local function build_registry_cache()
    if _registry_cache then return _registry_cache end
    _registry_cache = {}

    local function mod_of(name)
        return name:match("^([^:]+):") or "?"
    end

    local function add_entry(cat, name)
        local mod = mod_of(name)
        if not _registry_cache[mod] then
            _registry_cache[mod] = { nodes = {}, items = {}, entities = {} }
        end
        table.insert(_registry_cache[mod][cat], name)
    end

    -- Nodes
    for name in pairs(core.registered_nodes) do
        if not name:match("^__builtin") and name ~= "air" and name ~= "ignore" then
            add_entry("nodes", name)
        end
    end

    -- Items (Tools + CraftItems zusammengefasst)
    for name in pairs(core.registered_tools) do
        add_entry("items", name)
    end
    for name in pairs(core.registered_craftitems) do
        add_entry("items", name)
    end

    -- Entities
    for name in pairs(core.registered_entities) do
        if not name:match("^__builtin") then
            add_entry("entities", name)
        end
    end

    -- Sort entries within each mod alphabetically
    for _, mod_data in pairs(_registry_cache) do
        table.sort(mod_data.nodes)
        table.sort(mod_data.items)
        table.sort(mod_data.entities)
    end

    return _registry_cache
end

-- Build registry cache after mods_loaded (all mods loaded, registry complete)
core.register_on_mods_loaded(function()
    build_registry_cache()
    load_state()
    core.log("action", "[basic_context] registry cache built, state loaded")
end)

-- ===========================================================================
-- BASIC LAYER HELPERS
-- ===========================================================================

-- Server name + game + engine + in-game time + player count
local function build_server_info()
    local parts = {}

    local version  = core.get_version()
    local gameinfo = core.get_game_info()

    -- Explicit engine identity first — prevents LLM from confusing this with Minecraft
    table.insert(parts, "Engine: " .. (version.project or "Luanti") .. " " .. (version.string or "")
        .. "  [Luanti/Minetest — NOT Minecraft. Lua API, not Java/Bedrock.]")
    table.insert(parts, "Game: "   .. (gameinfo.name or "Luanti"))
    table.insert(parts, "Server: " .. (core.settings:get("server_name") or "unnamed"))

    -- In-game time (time of day as HH:MM)
    local tod  = core.get_timeofday() * 24000
    local hour = math.floor(tod / 1000)
    local min  = math.floor((tod % 1000) / 1000 * 60)
    table.insert(parts, string.format("In-game time: %02d:%02d", hour, min))

    -- Online players
    local players = core.get_connected_players()
    table.insert(parts, "Players online: " .. #players)

    return table.concat(parts, "\n")
end

-- Player's own info
local function build_player_info(player_name)
    local player = core.get_player_by_name(player_name)
    if not player then return "(player not found)" end

    local pos     = player:get_pos()
    local hp      = player:get_hp()
    local breath  = player:get_breath()
    local wielded = player:get_wielded_item():get_name()

    local parts = {}
    table.insert(parts, string.format(
        "You: %s | HP: %d | Breath: %d | Pos: (%.1f, %.1f, %.1f)",
        player_name, hp, breath, pos.x, pos.y, pos.z))
    if wielded and wielded ~= "" then
        table.insert(parts, "Holding: " .. wielded)
    end

    return table.concat(parts, "\n")
end

-- All other players: name + position
local function build_other_players(player_name)
    local players = core.get_connected_players()
    local lines   = {}
    for _, p in ipairs(players) do
        local pname = p:get_player_name()
        if pname ~= player_name then
            local pos = p:get_pos()
            table.insert(lines, string.format(
                "  %s @ (%.1f, %.1f, %.1f)", pname, pos.x, pos.y, pos.z))
        end
    end
    if #lines == 0 then return "Other players: none" end
    return "Other players:\n" .. table.concat(lines, "\n")
end

-- Lua-first runtime contract for AGENT MODE only.
-- Keep this out of plain chat; detailed APIs are fetched on demand through context_registry.lua.
local function build_lua_runtime_contract(player_name)
    local player = core.get_player_by_name(player_name)
    local parts = {
        "Lua action runtime:",
        "- Normal chat should stay plain text. Use hidden ```lua_action blocks only when an enabled skill/action is needed.",
        "- In lua_action code, player_name is available as the current player's name.",
        "- core is available with the safe runtime subset configured by core_executor.lua.",
        "- Get the player with: local player = core.get_player_by_name(player_name)",
        "- Direct node writes use node tables: core.set_node(pos, {name=\"default:stone\"}); do not pass a bare node-name string.",
        '- Finish actions with: return { done = true, message = "short result" }',
        '- Ask for another action step only with: return { done = false, continue = true, message = "why" }',
        "- Check skill results before done=true; if a skill returns ok=false, return done=false with its message instead of claiming success.",
        "- Do not register nodes/items/entities/craftitems during runtime; Luanti registrations are load-time only.",
        "- Do not call core.set_time; use llm_connect.skills.command_agent.set_time({time=18000}, player_name) when command_agent is active.",
        "- Detailed skill/API/server docs are not injected by default. Use llm_connect.context.load(key), lookup(key), list_sections(), search(query), and get_section(id) when details are needed.",
        "- Context loading is an intermediate step only when another requested action still remains.",
    }

    if player then
        local pos = player:get_pos()
        table.insert(parts, string.format(
            "Common pattern: player:set_pos({x=%.1f, y=%.1f, z=%.1f})",
            pos.x, pos.y, pos.z))
    end

    return table.concat(parts, "\n")
end

-- ===========================================================================
-- EXTENDED LAYER HELPERS
-- ===========================================================================

-- Builds the extended context block from registry cache + player filter state
local function preview_registered_def(def)
    if type(def) ~= "table" then return "" end
    local desc = safe_text(def.description or def.short_description or "")
    local groups = groups_preview(def.groups, 4)
    local bits = {}
    if desc ~= "" then bits[#bits + 1] = desc end
    if groups ~= "" then bits[#bits + 1] = "groups=" .. groups end
    if #bits == 0 then return "" end
    return " (" .. table.concat(bits, "; ") .. ")"
end

local function append_named_entries(lines, label, names, registry, max_entries)
    if not names or #names == 0 then return end
    local shown = {}
    local limit = math.min(#names, max_entries or 24)
    for i = 1, limit do
        local name = names[i]
        shown[#shown + 1] = name .. preview_registered_def(registry and registry[name])
    end
    if #names > limit then shown[#shown + 1] = "…" .. tostring(#names - limit) .. " more" end
    lines[#lines + 1] = "  " .. label .. ": " .. table.concat(shown, ", ")
end

-- Builds the extended context block from registry cache + player filter state.
-- This remains opt-in because modded servers can expose huge registries.
local function build_extended(ps)
    local cache = build_registry_cache()
    ensure_mod_state(ps)

    local types    = ps.types
    local mod_sel  = ps.mods
    local parts    = {}

    local selected_mods = {}
    for mod, selected in pairs(mod_sel) do
        if selected then table.insert(selected_mods, mod) end
    end
    table.sort(selected_mods)

    if #selected_mods == 0 then
        return "(extended registry: no mods selected in picker)"
    end

    for _, mod in ipairs(selected_mods) do
        local mod_data = cache[mod]
        if mod_data then
            local mod_lines = {}

            if types.nodes and #mod_data.nodes > 0 then
                append_named_entries(mod_lines, "nodes", mod_data.nodes, core.registered_nodes, 18)
            end
            if types.items and #mod_data.items > 0 then
                local item_defs = {}
                for k, v in pairs(core.registered_tools or {}) do item_defs[k] = v end
                for k, v in pairs(core.registered_craftitems or {}) do item_defs[k] = v end
                append_named_entries(mod_lines, "items", mod_data.items, item_defs, 18)
            end
            if types.entities and #mod_data.entities > 0 then
                append_named_entries(mod_lines, "entities", mod_data.entities, core.registered_entities, 14)
            end

            if #mod_lines > 0 then
                table.insert(parts, "[" .. mod .. "]")
                for _, l in ipairs(mod_lines) do table.insert(parts, l) end
            end
        end
    end

    if #parts == 0 then
        return "(extended registry: no matching entries for selected types/mods)"
    end

    return "Extended registry objects (filtered by picker; use only when relevant):\n" .. table.concat(parts, "\n")
end

-- ===========================================================================
-- PUBLIC API — Layer & Type & Mod State
-- ===========================================================================

function M.get_layer(player_name)
    return get_state(player_name).layer
end

function M.set_layer(player_name, layer)
    if layer ~= "basis" and layer ~= "erweitert" then
        core.log("warning", "[basic_context] set_layer: invalid layer: " .. tostring(layer))
        return
    end
    get_state(player_name).layer = layer
    M.save_state()
end

function M.get_types(player_name)
    local ps = get_state(player_name)
    return {
        nodes    = ps.types.nodes,
        items    = ps.types.items,
        entities = ps.types.entities,
    }
end

function M.set_type(player_name, type_key, enabled)
    local ps = get_state(player_name)
    if ps.types[type_key] == nil then
        core.log("warning", "[basic_context] set_type: unknown type: " .. tostring(type_key))
        return
    end
    ps.types[type_key] = enabled == true
    M.save_state()
end

-- Picker-State: { available = [mod_name, ...], selected = { [mod_name]=bool } }
function M.get_mod_picker_state(player_name)
    local ps = get_state(player_name)
    ensure_mod_state(ps)
    return {
        available = get_all_mods(),
        selected  = ps.mods,
    }
end

function M.set_mod_selected(player_name, mod_name, enabled)
    local ps = get_state(player_name)
    ensure_mod_state(ps)
    if ps.mods[mod_name] == nil and enabled == false then
        -- Unknown mod explicitly deselected — allow it
    end
    ps.mods[mod_name] = enabled == true
    M.save_state()
end

function M.select_all_mods(player_name)
    local ps = get_state(player_name)
    ensure_mod_state(ps)
    for _, mod in ipairs(get_all_mods()) do
        ps.mods[mod] = true
    end
    M.save_state()
end

function M.select_no_mods(player_name)
    local ps = get_state(player_name)
    ensure_mod_state(ps)
    for _, mod in ipairs(get_all_mods()) do
        ps.mods[mod] = false
    end
    M.save_state()
end

-- ===========================================================================
-- PUBLIC API — mode-aware context builders
-- Plain chat must not receive agent/runtime/tool instructions.
-- Agent mode receives the Lua contract and optional extended registry.
-- ===========================================================================

local function build_common_context(player_name, opts)
    opts = opts or {}
    local ps    = get_state(player_name)
    local parts = {}

    table.insert(parts, "=== GAME CONTEXT ===")

    table.insert(parts, "-- Server --")
    table.insert(parts, build_server_info())

    table.insert(parts, "-- Player --")
    table.insert(parts, build_player_info(player_name))

    table.insert(parts, "-- World --")
    table.insert(parts, build_other_players(player_name))

    if opts.include_runtime_contract then
        table.insert(parts, "-- Lua Runtime Contract --")
        table.insert(parts, build_lua_runtime_contract(player_name))
    end

    if opts.include_extended and ps.layer == "erweitert" then
        table.insert(parts, "-- Extended Registry --")
        table.insert(parts, build_extended(ps))
    end

    table.insert(parts, "=== END CONTEXT ===")
    return table.concat(parts, "\n")
end

function M.get_chat(player_name)
    local ctx = build_common_context(player_name, {
        include_runtime_contract = false,
        include_extended = false,
    })

    return table.concat({
        "You are chatting with a player inside a Luanti server.",
        "Answer normally in natural language. Do not emit Lua code, lua_action fences, tool calls, or hidden actions.",
        "Use the game context only when it helps answer the player's question.",
        "",
        ctx,
    }, "\n")
end

function M.get_agent(player_name)
    return build_common_context(player_name, {
        include_runtime_contract = true,
        include_extended = true,
    })
end

-- Compatibility: existing agent/IDE paths that still call basic_context.get()
-- receive the agent-safe context. Plain chat must call get_chat() explicitly.
function M.get(player_name)
    return M.get_agent(player_name)
end

-- ===========================================================================

core.log("action", "[basic_context] module loaded — Lua-first basic context")

return M
