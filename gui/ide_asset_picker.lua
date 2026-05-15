-- ===========================================================================
--  ide_asset_picker.lua — LLM Connect / Smart Lua IDE
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Three-tab asset browser (Nodes / Items+Tools / Sounds) for the IDE.
--  Selected assets are injected as structured metadata into CODE_GENERATOR
--  context via build_asset_context().
--
--  Ported from 0.9.0 — no changes required (no path references).
--
--  PUBLIC API (used by ide_gui.lua):
--    M.get_asset_count(player_name)        → int
--    M.build_asset_context(player_name)    → string | nil
--    M.show(player_name)
--    M.handle_fields(player_name, formname, fields) → bool
--
-- ===========================================================================

local core = core
local M    = {}

local COLS           = 8
local TILE_SIZE      = 1.4
local TILE_PAD       = 0.08
local ITEMS_PER_PAGE = COLS * 5   -- 40 tiles per page
local MAX_SOUNDS     = 256

local TAB_NODES  = "nodes"
local TAB_ITEMS  = "items"
local TAB_SOUNDS = "sounds"

-- ===========================================================================
-- Session state
-- ===========================================================================

local sessions = {}

local function get_session(name)
    if not sessions[name] then
        sessions[name] = {
            selected = {},
            tab      = TAB_NODES,
            filter   = "",
            page     = 1,
        }
    end
    return sessions[name]
end

core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

-- ===========================================================================
-- Asset key helpers
-- ===========================================================================

local function node_key(name)  return "n:" .. name end
local function item_key(name)  return "i:" .. name end
local function sound_key(name) return "s:" .. name end

-- ===========================================================================
-- PUBLIC: asset count and context builder
-- ===========================================================================

function M.get_asset_count(player_name)
    local sess = get_session(player_name)
    local n = 0
    for _ in pairs(sess.selected) do n = n + 1 end
    return n
end

local function trim(s) return s:match("^%s*(.-)%s*$") end

-- Compact node metadata string for LLM context
local function node_meta_string(node_name)
    local def = core.registered_nodes[node_name]
    if not def then return node_name .. "  -- (unknown)" end
    local parts = {}
    if type(def.tiles) == "table" and #def.tiles > 0 then
        local tile_strs = {}
        for i = 1, math.min(#def.tiles, 3) do
            local t = def.tiles[i]
            if type(t) == "string" then table.insert(tile_strs, t)
            elseif type(t) == "table" and t.name then table.insert(tile_strs, t.name)
            end
        end
        if #tile_strs > 0 then
            parts[#parts+1] = "  tiles: [" .. table.concat(tile_strs, ", ") .. "]"
        end
    end
    if type(def.groups) == "table" and next(def.groups) then
        local g = {}
        for k, v in pairs(def.groups) do table.insert(g, k .. "=" .. tostring(v)) end
        table.sort(g)
        parts[#parts+1] = "  groups: {" .. table.concat(g, ", ") .. "}"
    end
    if type(def.sounds) == "table" then
        local grp = def.groups or {}
        local preset
        if     grp.stone  then preset = "default.node_sound_stone_defaults()"
        elseif grp.wood   then preset = "default.node_sound_wood_defaults()"
        elseif grp.dirt   then preset = "default.node_sound_dirt_defaults()"
        elseif grp.sand   then preset = "default.node_sound_sand_defaults()"
        elseif grp.gravel then preset = "default.node_sound_gravel_defaults()"
        elseif grp.glass  then preset = "default.node_sound_glass_defaults()"
        elseif grp.leaves then preset = "default.node_sound_leaves_defaults()"
        elseif grp.metal  then preset = "default.node_sound_metal_defaults()"
        elseif grp.water  then preset = "default.node_sound_water_defaults()"
        end
        if preset then parts[#parts+1] = "  sounds: " .. preset end
    end
    if def.drawtype and def.drawtype ~= "normal" and def.drawtype ~= "" then
        parts[#parts+1] = "  drawtype: " .. def.drawtype
    end
    if def.light_source and def.light_source > 0 then
        parts[#parts+1] = "  light_source: " .. def.light_source
    end
    local result = node_name
    if #parts > 0 then result = result .. "\n" .. table.concat(parts, "\n") end
    return result
end

-- Compact item/tool metadata string for LLM context
local function item_meta_string(item_name)
    local def = core.registered_tools[item_name] or core.registered_craftitems[item_name]
    if not def then return item_name .. "  -- (unknown)" end
    local parts = {}
    if def.inventory_image and def.inventory_image ~= "" then
        parts[#parts+1] = "  inventory_image: " .. def.inventory_image
    end
    if def.description and def.description ~= "" then
        parts[#parts+1] = "  description: " .. tostring(def.description)
    end
    if type(def.tool_capabilities) == "table" then
        local tc = def.tool_capabilities
        if tc.full_punch_interval then
            parts[#parts+1] = "  full_punch_interval: " .. tc.full_punch_interval
        end
        if type(tc.groupcaps) == "table" then
            local gc = {}
            for grp in pairs(tc.groupcaps) do table.insert(gc, grp) end
            table.sort(gc)
            if #gc > 0 then parts[#parts+1] = "  groupcaps: " .. table.concat(gc, ", ") end
        end
    end
    if type(def.groups) == "table" and next(def.groups) then
        local g = {}
        for k, v in pairs(def.groups) do table.insert(g, k .. "=" .. tostring(v)) end
        table.sort(g)
        parts[#parts+1] = "  groups: {" .. table.concat(g, ", ") .. "}"
    end
    local result = item_name
    if #parts > 0 then result = result .. "\n" .. table.concat(parts, "\n") end
    return result
end

function M.build_asset_context(player_name)
    local sess = get_session(player_name)
    if not next(sess.selected) then return nil end

    local node_lines, item_lines, sound_lines = {}, {}, {}
    for key in pairs(sess.selected) do
        if key:sub(1,2) == "n:" then table.insert(node_lines,  node_meta_string(key:sub(3)))
        elseif key:sub(1,2) == "i:" then table.insert(item_lines,  item_meta_string(key:sub(3)))
        elseif key:sub(1,2) == "s:" then table.insert(sound_lines, key:sub(3))
        end
    end
    table.sort(node_lines); table.sort(item_lines); table.sort(sound_lines)

    local parts = {"--- IDE ASSETS ---"}
    if #node_lines > 0 then
        parts[#parts+1] = "Nodes:"
        for _, l in ipairs(node_lines) do parts[#parts+1] = l end
    end
    if #item_lines > 0 then
        parts[#parts+1] = "Items/Tools:"
        for _, l in ipairs(item_lines) do parts[#parts+1] = l end
    end
    if #sound_lines > 0 then
        parts[#parts+1] = "Sounds: " .. table.concat(sound_lines, ", ")
    end
    parts[#parts+1] = "--- END ASSETS ---"
    return table.concat(parts, "\n")
end

-- ===========================================================================
-- Candidate list builders
-- ===========================================================================

local function node_candidates(filter)
    filter = trim(filter):lower()
    local list = {}
    for name in pairs(core.registered_nodes) do
        if not name:match("^__builtin") and name ~= "air" and name ~= "ignore" then
            if filter == "" or name:lower():find(filter, 1, true) then
                table.insert(list, name)
            end
        end
    end
    table.sort(list)
    return list
end

local function item_candidates(filter)
    filter = trim(filter):lower()
    local seen, list = {}, {}
    local function add(name)
        if not seen[name] then
            seen[name] = true
            if filter == "" or name:lower():find(filter, 1, true) then
                table.insert(list, name)
            end
        end
    end
    for name in pairs(core.registered_tools or {}) do add(name) end
    for name in pairs(core.registered_craftitems or {}) do add(name) end
    table.sort(list)
    return list
end

local _sound_cache = nil

local function sound_candidates(filter)
    filter = trim(filter):lower()
    if not _sound_cache then
        local seen = {}
        local function collect(spec)
            if type(spec) == "string" and spec ~= "" then seen[spec] = true
            elseif type(spec) == "table" and type(spec.name) == "string" and spec.name ~= "" then
                seen[spec.name] = true
            end
        end
        local node_sound_fields = {"footstep","dig","dug","place","place_failed","fall","climb","jump"}
        for _, def in pairs(core.registered_nodes) do
            if type(def.sounds) == "table" then
                for _, f in ipairs(node_sound_fields) do collect(def.sounds[f]) end
            end
        end
        for _, def in pairs(core.registered_tools or {}) do
            if type(def.sound) == "table" then
                collect(def.sound.breaks); collect(def.sound.use); collect(def.sound.use_fails)
            end
        end
        for _, def in pairs(core.registered_craftitems or {}) do
            if type(def.sound) == "table" then
                collect(def.sound.use); collect(def.sound.use_fails)
            end
        end
        local list = {}
        for k in pairs(seen) do
            table.insert(list, k)
            if #list >= MAX_SOUNDS then break end
        end
        table.sort(list)
        _sound_cache = list
    end
    if filter == "" then return _sound_cache end
    local filtered = {}
    for _, s in ipairs(_sound_cache) do
        if s:lower():find(filter, 1, true) then table.insert(filtered, s) end
    end
    return filtered
end

-- ===========================================================================
-- Pagination helper
-- ===========================================================================

local function paginate(total, per_page, current)
    local total_pages = math.max(1, math.ceil(total / per_page))
    current = math.max(1, math.min(current, total_pages))
    local first = (current - 1) * per_page + 1
    local last  = math.min(total, current * per_page)
    return current, total_pages, first, last
end

-- ===========================================================================
-- M.show
-- ===========================================================================

function M.show(player_name)
    local sess   = get_session(player_name)
    local tab    = sess.tab or TAB_NODES
    local filter = sess.filter or ""

    local candidates
    if     tab == TAB_NODES  then candidates = node_candidates(filter)
    elseif tab == TAB_ITEMS  then candidates = item_candidates(filter)
    else                          candidates = sound_candidates(filter)
    end

    local total          = #candidates
    local items_per_page = (tab == TAB_SOUNDS) and 24 or ITEMS_PER_PAGE
    local page, total_pages, first, last = paginate(total, items_per_page, sess.page)
    sess.page = page

    local selected_count = M.get_asset_count(player_name)

    local W      = COLS * (TILE_SIZE + TILE_PAD) + 0.5
    local HDR_H  = 0.9
    local TAB_H  = 0.75
    local SRCH_H = 0.7
    local INFO_H = 0.45
    local GRID_H = 5 * (TILE_SIZE + TILE_PAD)
    local NAV_H  = 0.7
    local BTN_H  = 0.75
    local PAD    = 0.25
    local H = HDR_H + TAB_H + PAD + SRCH_H + PAD + INFO_H + PAD + GRID_H + PAD + NAV_H + PAD + BTN_H + PAD

    local fs = {
        "formspec_version[6]",
        "size[" .. string.format("%.2f", W) .. "," .. string.format("%.2f", H) .. "]",
        "bgcolor[#0d0d0d;both]",
        "style_type[*;bgcolor=#181818;textcolor=#e0e0e0]",
    }

    -- Header
    table.insert(fs, "box[0,0;" .. string.format("%.2f", W) .. "," .. HDR_H .. ";#1a1a2e]")
    table.insert(fs, "label[" .. PAD .. ",0.35;IDE Assets — "
        .. core.formspec_escape(player_name) .. " (" .. selected_count .. " selected)]")
    table.insert(fs, "style[close_picker;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, "button["
        .. string.format("%.2f", W - PAD - 2.0) .. ",0.12;2.0,0.65;close_picker;✕ Close]")

    local y = HDR_H

    -- Tab row
    local tab_w = (W - PAD * 2) / 3
    local tabs  = {{id=TAB_NODES,label="Nodes"},{id=TAB_ITEMS,label="Items/Tools"},{id=TAB_SOUNDS,label="Sounds"}}
    for i, t in ipairs(tabs) do
        local tx     = PAD + (i-1) * tab_w
        local active = (tab == t.id)
        local bg     = active and "#2a2a4a" or "#141422"
        local fg     = active and "#ffffff" or "#888899"
        table.insert(fs, "style[tab_" .. t.id .. ";bgcolor=" .. bg .. ";textcolor=" .. fg .. "]")
        table.insert(fs, "button["
            .. string.format("%.2f", tx) .. "," .. y .. ";"
            .. string.format("%.2f", tab_w) .. "," .. TAB_H
            .. ";tab_" .. t.id .. ";" .. t.label .. "]")
    end
    y = y + TAB_H + PAD

    -- Search
    local field_w = W - PAD * 2 - 2.6
    table.insert(fs, "field[" .. PAD .. "," .. y .. ";"
        .. string.format("%.2f", field_w) .. "," .. SRCH_H
        .. ";filter;;" .. core.formspec_escape(filter) .. "]")
    table.insert(fs, "style[filter;bgcolor=#111122;textcolor=#ccccff]")
    table.insert(fs, "field_close_on_enter[filter;false]")
    table.insert(fs, "style[do_filter;bgcolor=#1a1a3a;textcolor=#aaaaff]")
    table.insert(fs, "button["
        .. string.format("%.2f", PAD + field_w + 0.1) .. "," .. y
        .. ";2.4," .. SRCH_H .. ";do_filter;⟳ Search]")
    y = y + SRCH_H + PAD

    -- Info row + Toggle Page button
    local info_str = total == 0 and "Nothing found"
        or string.format("%d item(s) — page %d/%d", total, page, total_pages)
    table.insert(fs, "label[" .. PAD .. "," .. (y + 0.05) .. ";"
        .. core.formspec_escape(info_str) .. "]")

    local page_items = {}
    for i = first, last do table.insert(page_items, candidates[i]) end

    local function key_for(name)
        if tab == TAB_NODES then return node_key(name)
        elseif tab == TAB_ITEMS then return item_key(name)
        else return sound_key(name) end
    end

    local page_all_sel = #page_items > 0
    for _, n in ipairs(page_items) do
        if not sess.selected[key_for(n)] then page_all_sel = false; break end
    end
    local toggle_label = page_all_sel and "☑ Deselect Page" or "☐ Select Page"
    local toggle_bg    = page_all_sel and "#2a3a2a" or "#333344"
    table.insert(fs, "style[toggle_page;bgcolor=" .. toggle_bg .. ";textcolor=#ccffcc]")
    table.insert(fs, "button["
        .. string.format("%.2f", W - PAD - 3.8) .. "," .. (y - 0.05)
        .. ";3.8," .. (INFO_H + 0.1) .. ";toggle_page;" .. toggle_label .. "]")
    y = y + INFO_H + PAD

    -- Tile grid
    local STEP = TILE_SIZE + TILE_PAD
    local IMG  = TILE_SIZE - 0.25

    if tab == TAB_SOUNDS then
        local S_COLS     = 2
        local S_BTN_H    = 0.52
        local S_PAD      = TILE_PAD
        local S_BTN_W    = (W - PAD * 2 - S_PAD * (S_COLS - 1)) / S_COLS
        local S_ROW_STEP = S_BTN_H + S_PAD
        local rows_per_col = math.ceil(#page_items / S_COLS)

        for idx, sname in ipairs(page_items) do
            local col_idx = math.floor((idx - 1) / rows_per_col)
            local row_idx = (idx - 1) % rows_per_col
            local tx  = PAD + col_idx * (S_BTN_W + S_PAD)
            local ty  = y   + row_idx * S_ROW_STEP
            local key = sound_key(sname)
            local sel = sess.selected[key] == true
            local btn = "stile_" .. tostring((page - 1) * items_per_page + idx)

            local bg = sel and "#1a2a3a" or "#111118"
            table.insert(fs, "box["
                .. string.format("%.2f,%.2f;%.2f,%.2f", tx, ty, S_BTN_W, S_BTN_H)
                .. ";" .. bg .. "]")
            table.insert(fs, "button["
                .. string.format("%.2f,%.2f;%.2f,%.2f", tx, ty, S_BTN_W, S_BTN_H)
                .. ";" .. btn .. ";" .. core.formspec_escape(sname) .. "]")
            table.insert(fs, "tooltip[" .. btn .. ";" .. core.formspec_escape(sname) .. "]")
            if sel then
                table.insert(fs, "label["
                    .. string.format("%.2f,%.2f", tx + S_BTN_W - 0.35, ty + 0.17)
                    .. ";" .. core.colorize("#00aaff", "✔") .. "]")
            end
        end
    else
        -- Node / Item tab: item_image_button tiles
        local col = 0
        local row = 0
        for idx, asset_name in ipairs(page_items) do
            local tx   = PAD + col * STEP
            local ty   = y   + row * STEP
            local key  = (tab == TAB_NODES) and node_key(asset_name) or item_key(asset_name)
            local sel  = sess.selected[key] == true
            local btn  = "atile_" .. tostring((page - 1) * items_per_page + idx)

            if sel then
                table.insert(fs, "box["
                    .. string.format("%.2f,%.2f;%.2f,%.2f", tx-0.05, ty-0.05, TILE_SIZE+0.1, TILE_SIZE+0.1)
                    .. ";#2244aa]")
            end
            table.insert(fs, "item_image_button["
                .. string.format("%.2f,%.2f;%.2f,%.2f", tx, ty, TILE_SIZE, TILE_SIZE)
                .. ";" .. asset_name .. ";" .. btn .. ";]")
            table.insert(fs, "tooltip[" .. btn .. ";" .. core.formspec_escape(asset_name) .. "]")

            col = col + 1
            if col >= COLS then col = 0; row = row + 1 end
        end
    end

    -- Navigation
    local nav_w = 3.0
    if page > 1 then
        table.insert(fs, "style[page_prev;bgcolor=#222233;textcolor=#aaaaff]")
        table.insert(fs, "button[" .. PAD .. "," .. (y + GRID_H + PAD)
            .. ";" .. nav_w .. "," .. NAV_H .. ";page_prev;◀ Prev]")
    end
    if page < total_pages then
        table.insert(fs, "style[page_next;bgcolor=#222233;textcolor=#aaaaff]")
        table.insert(fs, "button["
            .. string.format("%.2f", W - PAD - nav_w) .. "," .. (y + GRID_H + PAD)
            .. ";" .. nav_w .. "," .. NAV_H .. ";page_next;Next ▶]")
    end
    local btn_y = y + GRID_H + PAD + NAV_H + PAD

    -- Bottom buttons
    local bw = (W - PAD * 3) / 2
    table.insert(fs, "style[clear_all;bgcolor=#3a1a1a;textcolor=#ff8888]")
    table.insert(fs, "button[" .. PAD .. "," .. btn_y .. ";"
        .. string.format("%.2f", bw) .. "," .. BTN_H .. ";clear_all;✕ Clear All]")
    table.insert(fs, "style[close_and_back;bgcolor=#1a2a1a;textcolor=#aaffaa]")
    table.insert(fs, "button["
        .. string.format("%.2f", PAD * 2 + bw) .. "," .. btn_y .. ";"
        .. string.format("%.2f", bw) .. "," .. BTN_H .. ";close_and_back;✓ Done]")

    core.show_formspec(player_name, "llm_connect:ide_asset_picker", table.concat(fs))
end

-- ===========================================================================
-- M.handle_fields
-- ===========================================================================

function M.handle_fields(player_name, formname, fields)
    if not formname:match("^llm_connect:ide_asset_picker") then return false end

    local sess   = get_session(player_name)
    local tab    = sess.tab or TAB_NODES
    local filter = sess.filter or ""

    if fields.filter ~= nil then sess.filter = fields.filter end

    -- Tab switches
    if fields.tab_nodes  then sess.tab = TAB_NODES;  sess.page = 1; sess.filter = ""; M.show(player_name); return true end
    if fields.tab_items  then sess.tab = TAB_ITEMS;  sess.page = 1; sess.filter = ""; M.show(player_name); return true end
    if fields.tab_sounds then sess.tab = TAB_SOUNDS; sess.page = 1; sess.filter = ""; _sound_cache = nil; M.show(player_name); return true end

    -- Search
    if fields.do_filter or fields.key_enter_field == "filter" then
        sess.page = 1; M.show(player_name); return true
    end

    -- Rebuild candidates
    local candidates
    if     tab == TAB_NODES  then candidates = node_candidates(filter)
    elseif tab == TAB_ITEMS  then candidates = item_candidates(filter)
    else                          candidates = sound_candidates(filter)
    end
    local total          = #candidates
    local items_per_page = (tab == TAB_SOUNDS) and 24 or ITEMS_PER_PAGE
    local page, total_pages, first, last = paginate(total, items_per_page, sess.page)

    local function key_for_tab(name)
        if tab == TAB_NODES then return node_key(name)
        elseif tab == TAB_ITEMS then return item_key(name)
        else return sound_key(name) end
    end

    -- Pagination
    if fields.page_prev then sess.page = math.max(1, page - 1);            M.show(player_name); return true end
    if fields.page_next then sess.page = math.min(total_pages, page + 1);  M.show(player_name); return true end

    -- Toggle page
    if fields.toggle_page then
        local page_items = {}
        for i = first, last do table.insert(page_items, candidates[i]) end
        local all_sel = #page_items > 0
        for _, n in ipairs(page_items) do
            if not sess.selected[key_for_tab(n)] then all_sel = false; break end
        end
        for _, n in ipairs(page_items) do
            local k = key_for_tab(n)
            if all_sel then sess.selected[k] = nil else sess.selected[k] = true end
        end
        M.show(player_name); return true
    end

    -- Clear all
    if fields.clear_all then
        sess.selected = {}; M.show(player_name); return true
    end

    -- Close / Done
    if fields.close_picker or fields.close_and_back or fields.quit then
        return true
    end

    -- Tile clicks (nodes / items): button name "atile_N"
    for field_name in pairs(fields) do
        local abs_idx = tonumber(field_name:match("^atile_(%d+)$"))
        if abs_idx then
            local asset_name = candidates[abs_idx]
            if asset_name then
                local k = key_for_tab(asset_name)
                if sess.selected[k] then sess.selected[k] = nil else sess.selected[k] = true end
            end
            M.show(player_name); return true
        end
    end

    -- Sound tile clicks: button name "stile_N"
    for field_name in pairs(fields) do
        local abs_idx = tonumber(field_name:match("^stile_(%d+)$"))
        if abs_idx then
            local sname = candidates[abs_idx]
            if sname then
                local k = sound_key(sname)
                if sess.selected[k] then
                    sess.selected[k] = nil
                else
                    sess.selected[k] = true
                    core.sound_play(sname, {to_player = player_name, gain = 1.0})
                end
            end
            M.show(player_name); return true
        end
    end

    return false
end

-- ===========================================================================

core.log("action", "[ide_asset_picker] module loaded")

return M
