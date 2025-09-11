-- mods/llm_connect/llm_materials_context.lua

local M = {}

-- Function to collect available materials
function M.get_available_materials()
    local materials_info = {}
    local current_mod_name = core.get_current_modname() -- Useful for debugging or filtering

    -- Collect nodes
    for name, def in pairs(core.registered_nodes) do
        -- Filter out builtin nodes that aren't really "materials"
        if not name:match("^__builtin:") and not name:match("^ignore$") and not name:match("^air$") then
            table.insert(materials_info, "  - Node: " .. name .. " (Description: " .. (def.description or "N/A") .. ")")
            -- Optional: Add other relevant info like groups
            -- table.insert(materials_info, "    Groups: " .. core.privs_to_string(def.groups))
        end
    end

    -- Collect craftitems
    for name, def in pairs(core.registered_craftitems) do
        if not name:match("^__builtin:") then
            table.insert(materials_info, "  - Craftitem: " .. name .. " (Description: " .. (def.description or "N/A") .. ")")
        end
    end

    -- Collect tools
    for name, def in pairs(core.registered_tools) do
        if not name:match("^__builtin:") then
            table.insert(materials_info, "  - Tool: " .. name .. " (Description: " .. (def.description or "N/A") .. ")")
        end
    end

    -- Collect entities
    for name, def in pairs(core.registered_entities) do
        if not name:match("^__builtin:") then
            table.insert(materials_info, "  - Entity: " .. name .. " (Description: " .. (def.description or "N/A") .. ")")
        end
    end

    -- Limit the output to avoid exceeding the LLM's token limits
    local max_items_to_list = 100 -- You can adjust this value
    local total_items = #materials_info
    local output_string = ""

    if total_items > 0 then
        output_string = "Registered materials (" .. total_items .. " in total):\n"
        for i = 1, math.min(total_items, max_items_to_list) do
            output_string = output_string .. materials_info[i] .. "\n"
        end
        if total_items > max_items_to_list then
            output_string = output_string .. "  ... and " .. (total_items - max_items_to_list) .. " more materials (truncated for brevity).\n"
        end
    else
        output_string = "No registered materials found.\n"
    end

    return output_string
end

return M
