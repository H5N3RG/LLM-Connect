-- ide_asset_picker.lua
-- IDE Asset Picker for LLM Connect – v0.9.0
--
-- Provides a three-tab browser (Nodes / Items / Sounds) for the Smart Lua IDE.
-- Selected assets are injected into the CODE_GENERATOR context block, giving
-- the LLM exact node definitions, item metadata, and sound names to work with.
--
-- Differs from material_picker.lua (WorldEdit context, node names only) in that
-- it surfaces rich metadata: tiles, groups, sounds preset, tool_capabilities,
-- inventory_image – everything the LLM needs to write precise mod code.
--
-- PUBLIC API (used by ide_gui.lua):
--   M.get_asset_count(player_name)        → int  (total selected assets)
--   M.build_asset_context(player_name)    → string | nil  (LLM context block)
--   M.show(player_name)                   → open formspec
--   M.handle_fields(player_name, formname, fields) → bool

local core = core
local M    = {}

-- ============================================================
-- Config
-- ============================================================

local COLS         = 8
local TILE_SIZE    = 1.4
local TILE_PAD     = 0.08
local ITEMS_PER_PAGE = COLS * 5   -- 40 tiles per page (5 rows)
local MAX_SOUNDS   = 256           -- cap on sound name scan

-- ============================================================
-- Session state
-- ============================================================

local sessions = {}

local function get_session(name)
    if not sessions[name] then
        sessions[name] = {
            selected   = {},   -- [asset_key] = true  (key = "node:mod:name" etc.)
            tab        = "nodes",
            filter     = "",
            page       = 1,
        }
    end
    return sessions[name]
end

core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

-- ============================================================
-- Asset key helpers
-- ============================================================
-- Keys are prefixed to avoid collisions between tabs:
--   "n:" + node_name   (node)
--   "i:" + item_name   (craftitem / tool)
--   "s:" + sound_name  (sound)

local function node_key(name)  return "n:" .. name end
local function item_key(name)  return "i:" .. name end
local function sound_key(name) return "s:" .. name end

-- ============================================================
-- Registry helpers
-- ============================================================

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

local function matches_filter(filter, name, desc)
    if filter == "" then return true end
    return name:lower():find(filter, 1, true)
        or (desc and desc:lower():find(filter, 1, true))
end

-- Build sorted candidate list for nodes tab
local function node_candidates(filter)
    filter = trim(filter):lower()
    local list = {}
    for name, def in pairs(core.registered_nodes) do
        if not name:match("^__builtin") and name ~= "air" and name ~= "ignore" then
            if matches_filter(filter, name, def.description) then
                table.insert(list, name)
            end
        end
    end
    table.sort(list)
    return list
end

-- Build sorted candidate list for items tab (craftitems + tools, no nodes)
local function item_candidates(filter)
    filter = trim(filter):lower()
    local list = {}
    -- craftitems
    for name, def in pairs(core.registered_craftitems or {}) do
        if not name:match("^__builtin") then
            if matches_filter(filter, name, def.description) then
                table.insert(list, name)
            end
        end
    end
    -- tools
    for name, def in pairs(core.registered_tools or {}) do
        if not name:match("^__builtin") then
            if matches_filter(filter, name, def.description) then
                table.insert(list, name)
            end
        end
    end
    table.sort(list)
    return list
end

-- Build sorted sound name list
-- Luanti doesn't expose a registered_sounds table, so we collect names
-- from node defs (sounds fields) and deduplicate. This covers the vast
-- majority of in-game sounds without filesystem access.
local _sound_cache = nil
local function sound_candidates(filter)
    filter = trim(filter):lower()

    if not _sound_cache then
        local seen = {}
        local collect = function(spec)
            if type(spec) == "string" and spec ~= "" then
                seen[spec] = true
            elseif type(spec) == "table" and type(spec.name) == "string" and spec.name ~= "" then
                seen[spec.name] = true
            end
        end
        -- Node sounds: field names are WITHOUT "sound_" prefix in Luanti API
        -- def.sounds = { footstep=spec, dig=spec, dug=spec, place=spec, ... }
        local node_sound_fields = {
            "footstep", "dig", "dug", "place", "place_failed",
            "fall", "climb", "jump",
        }
        for _, def in pairs(core.registered_nodes) do
            if type(def.sounds) == "table" then
                for _, field in ipairs(node_sound_fields) do
                    collect(def.sounds[field])
                end
            end
        end
        -- Tool sounds: def.sound = { breaks=spec, use=spec, use_fails=spec }
        for _, def in pairs(core.registered_tools or {}) do
            if type(def.sound) == "table" then
                collect(def.sound.breaks)
                collect(def.sound.use)
                collect(def.sound.use_fails)
            end
        end
        -- Craftitem sounds
        for _, def in pairs(core.registered_craftitems or {}) do
            if type(def.sound) == "table" then
                collect(def.sound.use)
                collect(def.sound.use_fails)
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
        if s:lower():find(filter, 1, true) then
            table.insert(filtered, s)
        end
    end
    return filtered
end

-- ============================================================
-- Metadata extraction for context output
-- ============================================================

-- Extract a compact, LLM-useful string for a node def
local function node_meta_string(node_name)
    local def = core.registered_nodes[node_name]
    if not def then return node_name .. "  -- (unknown)" end

    local parts = {}

    -- tiles: first tile only to keep it short; full list if <= 3
    if type(def.tiles) == "table" and #def.tiles > 0 then
        local tile_strs = {}
        for i = 1, math.min(#def.tiles, 3) do
            local t = def.tiles[i]
            if type(t) == "string" then
                table.insert(tile_strs, t)
            elseif type(t) == "table" and t.name then
                table.insert(tile_strs, t.name)
            end
        end
        if #tile_strs > 0 then
            parts[#parts+1] = "  tiles: [" .. table.concat(tile_strs, ", ") .. "]"
        end
    end

    -- groups: all of them (compact)
    if type(def.groups) == "table" and next(def.groups) then
        local g = {}
        for k, v in pairs(def.groups) do
            table.insert(g, k .. "=" .. tostring(v))
        end
        table.sort(g)
        parts[#parts+1] = "  groups: {" .. table.concat(g, ", ") .. "}"
    end

    -- sounds preset hint
    if type(def.sounds) == "table" then
        -- Guess the default sound preset from common group patterns
        local grp = def.groups or {}
        local preset
        if     grp.stone   then preset = "default.node_sound_stone_defaults()"
        elseif grp.wood    then preset = "default.node_sound_wood_defaults()"
        elseif grp.dirt    then preset = "default.node_sound_dirt_defaults()"
        elseif grp.sand    then preset = "default.node_sound_sand_defaults()"
        elseif grp.gravel  then preset = "default.node_sound_gravel_defaults()"
        elseif grp.glass   then preset = "default.node_sound_glass_defaults()"
        elseif grp.leaves  then preset = "default.node_sound_leaves_defaults()"
        elseif grp.metal   then preset = "default.node_sound_metal_defaults()"
        elseif grp.water   then preset = "default.node_sound_water_defaults()"
        end
        if preset then
            parts[#parts+1] = "  sounds: " .. preset
        end
    end

    -- drawtype if non-standard
    if def.drawtype and def.drawtype ~= "normal" and def.drawtype ~= "" then
        parts[#parts+1] = "  drawtype: " .. def.drawtype
    end

    -- light_source if set
    if def.light_source and def.light_source > 0 then
        parts[#parts+1] = "  light_source: " .. def.light_source
    end

    if #parts == 0 then
        return "node: " .. node_name
    end
    return "node: " .. node_name .. "\n" .. table.concat(parts, "\n")
end

-- Extract a compact string for an item/tool def
local function item_meta_string(item_name)
    -- Check both craftitems and tools
    local def = (core.registered_craftitems or {})[item_name]
              or (core.registered_tools or {})[item_name]
    if not def then return item_name .. "  -- (unknown)" end

    local parts = {}
    local kind = (core.registered_tools or {})[item_name] and "tool" or "item"

    if type(def.inventory_image) == "string" and def.inventory_image ~= "" then
        parts[#parts+1] = "  image: " .. def.inventory_image
    end

    if def.stack_max and def.stack_max ~= 99 then
        parts[#parts+1] = "  stack_max: " .. tostring(def.stack_max)
    end

    if type(def.tool_capabilities) == "table" then
        -- Compact repr: maxlevel + group names only
        local tc = def.tool_capabilities
        local gc = {}
        if type(tc.groupcaps) == "table" then
            for g in pairs(tc.groupcaps) do
                table.insert(gc, g)
            end
            table.sort(gc)
        end
        local tc_str = "tool_capabilities: {maxlevel=" .. tostring(tc.maxlevel or 1)
        if #gc > 0 then
            tc_str = tc_str .. ", groupcaps: [" .. table.concat(gc, ", ") .. "]"
        end
        tc_str = tc_str .. "}"
        parts[#parts+1] = "  " .. tc_str
    end

    if type(def.groups) == "table" and next(def.groups) then
        local g = {}
        for k, v in pairs(def.groups) do
            table.insert(g, k .. "=" .. tostring(v))
        end
        table.sort(g)
        parts[#parts+1] = "  groups: {" .. table.concat(g, ", ") .. "}"
    end

    if #parts == 0 then
        return kind .. ": " .. item_name
    end
    return kind .. ": " .. item_name .. "\n" .. table.concat(parts, "\n")
end

-- ============================================================
-- PUBLIC API
-- ============================================================

function M.get_asset_count(player_name)
    local sess = get_session(player_name)
    local n = 0
    for _ in pairs(sess.selected) do n = n + 1 end
    return n
end

function M.build_asset_context(player_name)
    local sess = get_session(player_name)
    if not next(sess.selected) then return nil end

    local node_lines  = {}
    local item_lines  = {}
    local sound_lines = {}

    for key in pairs(sess.selected) do
        if key:sub(1,2) == "n:" then
            table.insert(node_lines, node_meta_string(key:sub(3)))
        elseif key:sub(1,2) == "i:" then
            table.insert(item_lines, item_meta_string(key:sub(3)))
        elseif key:sub(1,2) == "s:" then
            table.insert(sound_lines, key:sub(3))
        end
    end

    table.sort(node_lines)
    table.sort(item_lines)
    table.sort(sound_lines)

    local parts = {"--- IDE ASSETS ---"}

    if #node_lines > 0 then
        parts[#parts+1] = "Nodes:"
        for _, l in ipairs(node_lines) do
            parts[#parts+1] = l
        end
    end

    if #item_lines > 0 then
        parts[#parts+1] = "Items/Tools:"
        for _, l in ipairs(item_lines) do
            parts[#parts+1] = l
        end
    end

    if #sound_lines > 0 then
        parts[#parts+1] = "Sounds: " .. table.concat(sound_lines, ", ")
    end

    parts[#parts+1] = "--- END ASSETS ---"
    return table.concat(parts, "\n")
end

-- ============================================================
-- Pagination helper
-- ============================================================

local function paginate(total, per_page, current)
    local total_pages = math.max(1, math.ceil(total / per_page))
    current = math.max(1, math.min(current, total_pages))
    local first = (current - 1) * per_page + 1
    local last  = math.min(total, current * per_page)
    return current, total_pages, first, last
end

-- ============================================================
-- Formspec builder
-- ============================================================

local TAB_NODES  = "nodes"
local TAB_ITEMS  = "items"
local TAB_SOUNDS = "sounds"

function M.show(player_name)
    local sess   = get_session(player_name)
    local tab    = sess.tab or TAB_NODES
    local filter = sess.filter or ""

    -- Build candidate list for current tab
    local candidates
    if tab == TAB_NODES then
        candidates = node_candidates(filter)
    elseif tab == TAB_ITEMS then
        candidates = item_candidates(filter)
    else
        candidates = sound_candidates(filter)
    end

    local total = #candidates
    local page, total_pages, first, last = paginate(total, ITEMS_PER_PAGE, sess.page)
    sess.page = page

    local selected_count = M.get_asset_count(player_name)

    -- ── Layout constants ──────────────────────────────────────
    local W       = COLS * (TILE_SIZE + TILE_PAD) + 0.5
    local HDR_H   = 0.9
    local TAB_H   = 0.75
    local SRCH_H  = 0.7
    local INFO_H  = 0.45
    local GRID_H  = 5 * (TILE_SIZE + TILE_PAD)
    local NAV_H   = 0.7
    local BTN_H   = 0.75
    local PAD     = 0.25
    local H = HDR_H + TAB_H + PAD + SRCH_H + PAD + INFO_H + PAD + GRID_H + PAD + NAV_H + PAD + BTN_H + PAD

    local fs = {
        "formspec_version[6]",
        "size[" .. string.format("%.2f", W) .. "," .. string.format("%.2f", H) .. "]",
        "bgcolor[#0d0d0d;both]",
        "style_type[*;bgcolor=#181818;textcolor=#e0e0e0]",
    }

    -- ── Header ────────────────────────────────────────────────
    table.insert(fs, "box[0,0;" .. string.format("%.2f", W) .. "," .. HDR_H .. ";#1a1a2e]")
    table.insert(fs, "label[" .. PAD .. ",0.35;IDE Assets — "
        .. core.formspec_escape(player_name)
        .. " (" .. selected_count .. " selected)]")
    table.insert(fs, "style[close_picker;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, "button[" .. string.format("%.2f", W - PAD - 2.0) .. ",0.12;2.0,0.65;close_picker;✕ Close]")

    local y = HDR_H

    -- ── Tab row ───────────────────────────────────────────────
    local tab_w = (W - PAD * 2) / 3
    local tabs  = {
        {id = TAB_NODES,  label = "Nodes"},
        {id = TAB_ITEMS,  label = "Items/Tools"},
        {id = TAB_SOUNDS, label = "Sounds"},
    }
    for i, t in ipairs(tabs) do
        local tx   = PAD + (i - 1) * tab_w
        local active = (tab == t.id)
        local bg   = active and "#2a2a4a" or "#141422"
        local fg   = active and "#ffffff" or "#888899"
        table.insert(fs, "style[tab_" .. t.id .. ";bgcolor=" .. bg .. ";textcolor=" .. fg .. "]")
        table.insert(fs, "button[" .. string.format("%.2f", tx) .. "," .. y
            .. ";" .. string.format("%.2f", tab_w) .. "," .. TAB_H
            .. ";tab_" .. t.id .. ";" .. t.label .. "]")
    end
    y = y + TAB_H + PAD

    -- ── Search field ──────────────────────────────────────────
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

    -- ── Info row ──────────────────────────────────────────────
    local info_str = total == 0
        and "Nothing found"
        or  string.format("%d item(s) — page %d/%d", total, page, total_pages)
    table.insert(fs, "label[" .. PAD .. "," .. (y + 0.05) .. ";"
        .. core.formspec_escape(info_str) .. "]")

    -- Toggle-page button
    local page_items = {}
    for i = first, last do
        table.insert(page_items, candidates[i])
    end

    local function key_for(item_name)
        if tab == TAB_NODES  then return node_key(item_name)  end
        if tab == TAB_ITEMS  then return item_key(item_name)  end
        return sound_key(item_name)
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

    -- ── Tile grid ─────────────────────────────────────────────
    local STEP = TILE_SIZE + TILE_PAD
    local IMG  = TILE_SIZE - 0.25

    if tab == TAB_SOUNDS then
        -- Sound tab: text buttons instead of item images (no icon available)
        -- NOTE: style[] does not work with runtime-generated button names in Luanti.
        -- Use a box[] behind the button for selection highlight instead.
        local col = 0
        local row = 0
        local BTN_W = (W - PAD * 2 - TILE_PAD * (COLS - 1)) / COLS
        local BTN_H = TILE_SIZE  -- same height as tile grid for consistent layout
        local ROW_STEP = BTN_H + TILE_PAD

        for idx, sname in ipairs(page_items) do
            local tx  = PAD + col * (BTN_W + TILE_PAD)
            local ty  = y   + row * ROW_STEP
            local key = sound_key(sname)
            local sel = sess.selected[key] == true
            local btn = "stile_" .. tostring((page - 1) * ITEMS_PER_PAGE + idx)

            -- Background box for selection highlight (box[] works at runtime)
            local bg = sel and "#1a2a3a" or "#111118"
            table.insert(fs, "box["
                .. string.format("%.2f,%.2f;%.2f,%.2f", tx, ty, BTN_W, BTN_H)
                .. ";" .. bg .. "]")

            -- Button on top (transparent bgcolor via style_type override not needed –
            -- the box behind provides the color; button itself uses default dark theme)
            table.insert(fs, "button["
                .. string.format("%.2f,%.2f;%.2f,%.2f", tx, ty, BTN_W, BTN_H)
                .. ";" .. btn .. ";" .. core.formspec_escape(
                    (sel and "✔ " or "") .. sname) .. "]")
            table.insert(fs, "tooltip[" .. btn .. ";" .. core.formspec_escape(sname) .. "]")

            col = col + 1
            if col >= COLS then col = 0; row = row + 1 end
        end
    else
        -- Node / Item tab: item_image_button tiles
        local col = 0
        local row = 0

        for idx, asset_name in ipairs(page_items) do
            local tx  = PAD + col * STEP
            local ty  = y   + row * STEP
            local key = key_for(asset_name)
            local sel = sess.selected[key] == true
            local bg  = sel and "#1a3a1a" or "#1a1a1a"
            local btn = "atile_" .. tostring((page - 1) * ITEMS_PER_PAGE + idx)

            table.insert(fs, "box["
                .. string.format("%.2f,%.2f;%.2f,%.2f", tx, ty, TILE_SIZE, TILE_SIZE)
                .. ";" .. bg .. "]")
            table.insert(fs, "item_image_button["
                .. string.format("%.2f,%.2f;%.2f,%.2f", tx + 0.05, ty + 0.05, IMG, IMG)
                .. ";" .. core.formspec_escape(asset_name)
                .. ";" .. btn .. ";]")

            -- Checkmark when selected
            if sel then
                table.insert(fs, "label["
                    .. string.format("%.2f,%.2f", tx + TILE_SIZE - 0.38, ty + 0.18)
                    .. ";" .. core.colorize("#00ff00", "✔") .. "]")
            end

            -- Tooltip: description + name
            local def = tab == TAB_NODES
                and core.registered_nodes[asset_name]
                or  (core.registered_craftitems or {})[asset_name]
                or  (core.registered_tools or {})[asset_name]
            local desc = (def and type(def.description) == "string" and def.description ~= "")
                and def.description or asset_name
            table.insert(fs, "tooltip[" .. btn .. ";"
                .. core.formspec_escape(desc .. "\n" .. asset_name) .. "]")

            col = col + 1
            if col >= COLS then col = 0; row = row + 1 end
        end
    end

    y = y + GRID_H + PAD

    -- ── Navigation ────────────────────────────────────────────
    if total_pages > 1 then
        local nav_w = 2.2
        table.insert(fs, "style[page_prev;bgcolor=#222233;textcolor=#aaaaff]")
        table.insert(fs, "button[" .. PAD .. "," .. y .. ";"
            .. nav_w .. "," .. NAV_H .. ";page_prev;◀ Prev]")
        table.insert(fs, "style[page_next;bgcolor=#222233;textcolor=#aaaaff]")
        table.insert(fs, "button["
            .. string.format("%.2f", W - PAD - nav_w) .. "," .. y
            .. ";" .. nav_w .. "," .. NAV_H .. ";page_next;Next ▶]")
    end
    y = y + NAV_H + PAD

    -- ── Bottom buttons ────────────────────────────────────────
    local bw = (W - PAD * 3) / 2
    table.insert(fs, "style[clear_all;bgcolor=#3a1a1a;textcolor=#ff8888]")
    table.insert(fs, "button[" .. PAD .. "," .. y .. ";"
        .. string.format("%.2f", bw) .. "," .. BTN_H .. ";clear_all;✕ Clear All]")

    table.insert(fs, "style[close_and_back;bgcolor=#1a2a1a;textcolor=#aaffaa]")
    table.insert(fs, "button["
        .. string.format("%.2f", PAD * 2 + bw) .. "," .. y .. ";"
        .. string.format("%.2f", bw) .. "," .. BTN_H .. ";close_and_back;✓ Done]")

    core.show_formspec(player_name, "llm_connect:ide_asset_picker", table.concat(fs))
end

-- ============================================================
-- Formspec handler
-- ============================================================

function M.handle_fields(player_name, formname, fields)
    if not formname:match("^llm_connect:ide_asset_picker") then
        return false
    end

    local sess       = get_session(player_name)
    local tab        = sess.tab or TAB_NODES
    local filter     = sess.filter or ""

    local function key_for_tab(asset_name)
        if tab == TAB_NODES  then return node_key(asset_name)  end
        if tab == TAB_ITEMS  then return item_key(asset_name)  end
        return sound_key(asset_name)
    end

    -- Live filter capture
    if fields.filter ~= nil then
        sess.filter = fields.filter
    end

    -- ── Tab switches ──────────────────────────────────────────
    if fields.tab_nodes then
        sess.tab = TAB_NODES; sess.page = 1; sess.filter = ""
        M.show(player_name); return true
    end
    if fields.tab_items then
        sess.tab = TAB_ITEMS; sess.page = 1; sess.filter = ""
        M.show(player_name); return true
    end
    if fields.tab_sounds then
        sess.tab = TAB_SOUNDS; sess.page = 1; sess.filter = ""
        -- Invalidate sound cache so it rebuilds on next open
        _sound_cache = nil
        M.show(player_name); return true
    end

    -- ── Search ────────────────────────────────────────────────
    if fields.do_filter or fields.key_enter_field == "filter" then
        sess.page = 1
        M.show(player_name); return true
    end

    -- ── Rebuild candidates for current tab/filter ─────────────
    local candidates
    if tab == TAB_NODES  then candidates = node_candidates(filter)
    elseif tab == TAB_ITEMS  then candidates = item_candidates(filter)
    else                     candidates = sound_candidates(filter)
    end
    local total = #candidates
    local page, total_pages, first, last = paginate(total, ITEMS_PER_PAGE, sess.page)

    -- ── Pagination ────────────────────────────────────────────
    if fields.page_prev then
        sess.page = math.max(1, page - 1)
        M.show(player_name); return true
    end
    if fields.page_next then
        sess.page = math.min(total_pages, page + 1)
        M.show(player_name); return true
    end

    -- ── Toggle page ───────────────────────────────────────────
    if fields.toggle_page then
        local page_items = {}
        for i = first, last do table.insert(page_items, candidates[i]) end
        local all_sel = #page_items > 0
        for _, n in ipairs(page_items) do
            if not sess.selected[key_for_tab(n)] then all_sel = false; break end
        end
        for _, n in ipairs(page_items) do
            local k = key_for_tab(n)
            if all_sel then
                sess.selected[k] = nil
            else
                sess.selected[k] = true
            end
        end
        M.show(player_name); return true
    end

    -- ── Clear all ─────────────────────────────────────────────
    if fields.clear_all then
        sess.selected = {}
        M.show(player_name); return true
    end

    -- ── Close / Done ──────────────────────────────────────────
    if fields.close_picker or fields.close_and_back or fields.quit then
        -- ide_gui.handle_fields forwards back to IDE on these
        return true
    end

    -- ── Tile clicks (nodes/items) ─────────────────────────────
    -- Button names: "atile_N" where N = absolute index
    for field_name in pairs(fields) do
        local abs_idx = tonumber(field_name:match("^atile_(%d+)$"))
        if abs_idx then
            local asset_name = candidates[abs_idx]
            if asset_name then
                local k = key_for_tab(asset_name)
                if sess.selected[k] then
                    sess.selected[k] = nil
                else
                    sess.selected[k] = true
                end
            end
            M.show(player_name); return true
        end
    end

    -- ── Sound tile clicks ─────────────────────────────────────
    -- Button names: "stile_N"
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
                end
            end
            M.show(player_name); return true
        end
    end

    return false
end

return M
