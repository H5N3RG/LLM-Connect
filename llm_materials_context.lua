-- mods/llm_connect/llm_materials_context.lua

local M = {}

-- Cache for materials to avoid recomputation
local materials_cache = nil
local materials_cache_hash = nil

-- Compute a hash for registered items to detect changes
local function compute_materials_hash()
    local str = ""
    for name, _ in pairs(core.registered_nodes) do str = str .. name end
    for name, _ in pairs(core.registered_craftitems) do str = str .. name end
    for name, _ in pairs(core.registered_tools) do str = str .. name end
    for name, _ in pairs(core.registered_entities) do str = str .. name end
    return core.sha1(str)
end

-- Function to collect available materials
function M.get_available_materials()
    local current_hash = compute_materials_hash()
    if materials_cache and materials_cache_hash == current_hash then
        return materials_cache
    end

    local materials_info = {}
    local current_mod_name = core.get_current_modname()

    -- Collect nodes
    for name, def in pairs(core.registered_nodes) do
        if not name:match("^__builtin:") and not name:match("^ignore$") and not name:match("^air$") then
            table.insert(materials_info, "Node: " .. name)
        end
    end

    -- Collect craftitems
    for name, def in pairs(core.registered_craftitems) do
        if not name:match("^__builtin:") then
            table.insert(materials_info, "Craftitem: " .. name)
        end
    end

    -- Collect tools
    for name, def in pairs(core.registered_tools) do
        if not name:match("^__builtin:") then
            table.insert(materials_info, "Tool: " .. name)
        end
    end

    -- Collect entities
    for name, def in pairs(core.registered_entities) do
        if not name:match("^__builtin:") then
            table.insert(materials_info, "Entity: " .. name)
        end
    end

    -- Limit the output
    local max_items_to_list = 50 -- Reduced for token efficiency
    local total_items = #materials_info
    local output_string = ""

    if total_items > 0 then
        output_string = "Registered materials (" .. total_items .. " in total):\n"
        for i = 1, math.min(total_items, max_items_to_list) do
            output_string = output_string .. "  - " .. materials_info[i] .. "\n"
        end
        if total_items > max_items_to_list then
            output_string = output_string .. "  ... and " .. (total_items - max_items_to_list) .. " more materials (truncated).\n"
        end
    else
        output_string = "No registered materials found.\n"
    end

    materials_cache = output_string
    materials_cache_hash = current_hash
    return output_string
end

return M
