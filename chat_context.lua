-- chat_context.lua
-- Collects game and world context for the LLM
-- Uses settings from settingtypes.txt

local core = core
local M = {}

local materials_cache = nil
local materials_hash = nil

-- Computes a hash of the registry to detect changes in nodes or items
local function compute_registry_hash()
    local count = 0
    for _ in pairs(core.registered_nodes) do count = count + 1 end
    for _ in pairs(core.registered_items) do count = count + 1 end
    return tostring(count)
end

-- Generates a string context of registered materials (nodes, tools, items)
local function get_materials_context()
    local current_hash = compute_registry_hash()
    if materials_cache and materials_hash == current_hash then
        return materials_cache
    end

    local lines = {}
    local categories = {
        {list = core.registered_nodes, label = "Nodes"},
        {list = core.registered_tools, label = "Tools"},
        {list = core.registered_craftitems, label = "Items"}
    }

    for _, cat in ipairs(categories) do
        local count = 0
        local items = {}
        for name, _ in pairs(cat.list) do
            -- Filter out internal engine nodes
            if not name:match("^__builtin") and not name:match("^ignore") and not name:match("^air") then
                count = count + 1
                if count <= 40 then
                    table.insert(items, name)
                end
            end
        end
        table.insert(lines, cat.label .. ": " .. table.concat(items, ", "))
    end

    materials_cache = table.concat(lines, "\n")
    materials_hash = current_hash
    return materials_cache
end

-- Returns general information about the server and game state
function M.get_server_info()
    local info = {}
    local version = core.get_version()
    table.insert(info, "Game: " .. (core.get_game_info().name or "Luanti/Minetest"))
    table.insert(info, "Engine Version: " .. (version.project or "unknown"))

    if core.settings:get_bool("llm_context_send_mod_list") then
        local mods = core.get_modnames()
        table.sort(mods)
        table.insert(info, "Active Mods: " .. table.concat(mods, ", "))
    end

    local time = core.get_timeofday() * 24000
    local hour = math.floor(time / 1000)
    local min = math.floor((time % 1000) / 1000 * 60)
    table.insert(info, string.format("In-game Time: %02d:%02d", hour, min))

    return table.concat(info, "\n")
end

-- Compiles all enabled context categories into a single string
function M.get_context(name)
    local ctx = {"--- START CONTEXT ---"}

    -- 1. Server Info
    if core.settings:get_bool("llm_context_send_server_info") ~= false then
        table.insert(ctx, "--- SERVER INFO ---")
        table.insert(ctx, M.get_server_info())
    end

    -- 2. Player Info
    if core.settings:get_bool("llm_context_send_player_pos") ~= false then
        local player = core.get_player_by_name(name)
        if player then
            local pos = player:get_pos()
            local hp = player:get_hp()
            local wielded = player:get_wielded_item():get_name()

            table.insert(ctx, string.format("Current Player (%s): HP: %d, Pos: (x=%.1f, y=%.1f, z=%.1f)",
                name, hp, pos.x, pos.y, pos.z))

            if wielded ~= "" then
                table.insert(ctx, "Holding item: " .. wielded)
            end
        end
    end

    -- 3. Chat Commands
    if core.settings:get_bool("llm_context_send_commands") then
        local cmds = {}
        for cmd, _ in pairs(core.registered_chatcommands) do
            table.insert(cmds, "/" .. cmd)
        end
        table.sort(cmds)
        table.insert(ctx, "Available Commands (Top 50): " .. table.concat(cmds, ", ", 1, math.min(50, #cmds)))
    end

    -- 4. Materials
    if core.settings:get_bool("llm_context_send_materials") then
        table.insert(ctx, "--- REGISTERED MATERIALS ---")
        table.insert(ctx, get_materials_context())
    end

    table.insert(ctx, "--- END CONTEXT ---")
    return table.concat(ctx, "\n")
end

-- Injects the game context as a system message into the messages table
function M.append_context(messages, name)
    local context_str = M.get_context(name)

    table.insert(messages, 1, {
        role = "system",
        content = "You are an AI assistant inside a Luanti (Minetest) game world. " ..
                  "Use the following game context to answer the user's questions accurately.\n\n" ..
                  context_str
    })

    return messages
end

return M
