-- ===========================================================================
--  basic_context.lua — LLM Connect 1.0 Basic Context Provider
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  ROLE: Basic context provider for all agents.
--
--  TWO LAYERS (per-player configurable, selectable in config_gui):
--
--  BASIS (always active, cannot be disabled):
--    - Player name, position, HP, breath, held item
--    - Server name, game, engine version, in-game time, online player count
--    - All other players: name + position
--    - ALL registered chat commands: name + description + params syntax
--
--  ERWEITERT (opt-in per player):
--    - Everything from BASIS
--    - Nodes / Items / Entities from Luanti registry
--    - Filtered by type toggle (Nodes ✓/✗, Items ✓/✗, Entities ✓/✗)
--    - Filtered by mod picker: player selects which mods to include
--    - Picker state is persisted per world (mod-filtered selection)
--
--  PICKER STATE PERSISTENCE:
--    Stored in <world_path>/llm_basic_context_state.json
--    Format: { [player_name] = { layer, types, mods } }
--    Loaded on first get() call per player, saved on every change.
--
--  PUBLIC API:
--    M.get(player_name)                        → string  (context string for LLM)
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
--  USAGE in agent.lua / do_iteration():
--    local basic_ctx = get_basic_context()
--    local ctx_str   = basic_ctx.get(player_name)
--
-- ===========================================================================

local core = core
local M    = {}

-- ===========================================================================
-- Persistenter State
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

-- Speichert den aktuellen State in die JSON-Datei
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
-- BASIS-LAYER Hilfsfunktionen
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

-- Alle registrierten Chat-Commands: Name + Beschreibung + Params-Syntax
-- Builds the command list for the LLM context.
-- Filters to commands the player actually has privilege to run.
-- Caps at MAX_COMMANDS to avoid token budget explosion on modded servers.
-- Standard well-known commands (teleport, give, time, etc.) are always shown
-- first; mod-specific commands fill the remaining slots.
local MAX_COMMANDS = 40

-- Commands the LLM should always see when the player has access,
-- because they are universally useful for agent actions.
local PRIORITY_COMMANDS = {
    "teleport", "tp", "give", "time", "weather", "set_password",
    "spawn", "home", "sethome", "kill", "kick", "ban", "unban",
    "grant", "revoke", "privs", "clearobjects", "deleteblocks",
}
local PRIORITY_SET = {}
for _, c in ipairs(PRIORITY_COMMANDS) do PRIORITY_SET[c] = true end

local function build_commands(player_name)
    local cmds = core.registered_chatcommands
    if not cmds then return "(no commands registered)" end

    local player_privs = core.get_player_privs(player_name) or {}
    local is_root      = player_privs["llm_root"] == true

    -- Helper: does the player have all required privs for a command?
    local function can_run(def)
        if is_root then return true end
        if not def.privs or next(def.privs) == nil then return true end
        for priv in pairs(def.privs) do
            if not player_privs[priv] then return false end
        end
        return true
    end

    -- Separate into priority and other, both filtered by privilege
    local priority, others = {}, {}
    for name, def in pairs(cmds) do
        if can_run(def) then
            local entry = { name = name, def = def }
            if PRIORITY_SET[name] then
                table.insert(priority, entry)
            else
                table.insert(others, entry)
            end
        end
    end

    table.sort(priority, function(a, b) return a.name < b.name end)
    table.sort(others,   function(a, b) return a.name < b.name end)

    -- Merge: priority first, then fill up to MAX_COMMANDS with others
    local merged = {}
    for _, e in ipairs(priority) do table.insert(merged, e) end
    for _, e in ipairs(others) do
        if #merged >= MAX_COMMANDS then break end
        table.insert(merged, e)
    end

    local total_accessible = #priority + #others
    local lines = { "Available chat commands (player-accessible, "
        .. #merged .. "/" .. total_accessible .. "):" }

    for _, entry in ipairs(merged) do
        local desc   = entry.def.description or ""
        local params = entry.def.params or ""
        if params ~= "" then
            table.insert(lines, string.format("  /%s %s — %s", entry.name, params, desc))
        else
            table.insert(lines, string.format("  /%s — %s", entry.name, desc))
        end
    end

    if total_accessible > MAX_COMMANDS then
        table.insert(lines, string.format(
            "  … and %d more (use run_chat_command with any valid command name)",
            total_accessible - MAX_COMMANDS))
    end

    return table.concat(lines, "\n")
end

-- ===========================================================================
-- ERWEITERT-LAYER Hilfsfunktionen
-- ===========================================================================

-- Builds the extended context block from registry cache + player filter state
local function build_extended(ps)
    local cache = build_registry_cache()
    ensure_mod_state(ps)

    local types    = ps.types
    local mod_sel  = ps.mods
    local parts    = {}

    -- Ordered mod list for deterministic output
    local selected_mods = {}
    for mod, selected in pairs(mod_sel) do
        if selected then table.insert(selected_mods, mod) end
    end
    table.sort(selected_mods)

    if #selected_mods == 0 then
        return "(extended context: no mods selected in picker)"
    end

    for _, mod in ipairs(selected_mods) do
        local mod_data = cache[mod]
        if not mod_data then goto continue end

        local mod_lines = {}

        if types.nodes and #mod_data.nodes > 0 then
            table.insert(mod_lines,
                "  nodes: " .. table.concat(mod_data.nodes, ", "))
        end
        if types.items and #mod_data.items > 0 then
            table.insert(mod_lines,
                "  items: " .. table.concat(mod_data.items, ", "))
        end
        if types.entities and #mod_data.entities > 0 then
            table.insert(mod_lines,
                "  entities: " .. table.concat(mod_data.entities, ", "))
        end

        if #mod_lines > 0 then
            table.insert(parts, "[" .. mod .. "]")
            for _, l in ipairs(mod_lines) do table.insert(parts, l) end
        end

        ::continue::
    end

    if #parts == 0 then
        return "(extended context: no matching entries for selected types/mods)"
    end

    return "Registered objects (filtered by picker):\n" .. table.concat(parts, "\n")
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
        core.log("warning", "[basic_context] set_type: unbekannter Typ: " .. tostring(type_key))
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
        -- Unbekannter Mod explizit deselektiert — zulassen
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
-- PUBLIC API — M.get(player_name)
-- Main function: returns the full context string.
-- Called by agent.lua's do_iteration() on every iteration.
-- ===========================================================================

function M.get(player_name)
    local ps     = get_state(player_name)
    local parts  = {}

    -- ── BASIS layer (always) ─────────────────────────────────────────────

    table.insert(parts, "=== GAME CONTEXT ===")

    table.insert(parts, "-- Server --")
    table.insert(parts, build_server_info())

    table.insert(parts, "-- Player --")
    table.insert(parts, build_player_info(player_name))

    table.insert(parts, "-- World --")
    table.insert(parts, build_other_players(player_name))

    table.insert(parts, "-- Commands --")
    table.insert(parts, build_commands(player_name))

    -- ── ERWEITERT layer (opt-in) ──────────────────────────────────────────

    if ps.layer == "erweitert" then
        table.insert(parts, "-- Extended Registry --")
        table.insert(parts, build_extended(ps))
    end

    table.insert(parts, "=== END CONTEXT ===")

    return table.concat(parts, "\n")
end

-- ===========================================================================

core.log("action", "[basic_context] module loaded")

return M
