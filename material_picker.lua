-- material_picker.lua  v2.0
-- Inventar-style Materialauswahl für LLM WorldEdit Kontext
--
-- UI: Kacheln mit Item-Icons (item_image) + farbiger Markierung wenn aktiv
--     Suchfilter oben, Toggle-All Button, Remove-All Button
--     Kacheln sind Buttons → Klick togglet Selektion
--
-- PUBLIC API (genutzt von chat_gui.lua / llm_worldedit.lua):
--   M.get_materials(player_name)           → sortierte Liste von Node-Strings
--   M.has_materials(player_name)           → bool
--   M.build_material_context(player_name)  → String für LLM-Systemprompt
--   M.show(player_name)                    → Formspec öffnen
--   M.handle_fields(player_name, formname, fields) → bool

local core = core
local M    = {}

-- ============================================================
-- Konfiguration
-- ============================================================

local COLS        = 8     -- Kacheln pro Zeile
local TILE_SIZE   = 1.4   -- Breite/Höhe einer Kachel in Formspec-Einheiten
local TILE_PAD    = 0.08  -- Abstand zwischen Kacheln
local MAX_NODES   = 128   -- max. Kandidaten die gerendert werden

-- ============================================================
-- Session-State
-- ============================================================

local sessions = {}

local function get_session(name)
    if not sessions[name] then
        sessions[name] = {
            materials  = {},   -- [node_name] = true
            filter     = "",
            page       = 1,    -- aktuelle Seite (Paginierung)
        }
    end
    return sessions[name]
end

core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

-- ============================================================
-- PUBLIC API
-- ============================================================

function M.get_materials(player_name)
    local sess = get_session(player_name)
    local list = {}
    for node in pairs(sess.materials) do
        table.insert(list, node)
    end
    table.sort(list)
    return list
end

function M.has_materials(player_name)
    local sess = get_session(player_name)
    for _ in pairs(sess.materials) do return true end
    return false
end

function M.build_material_context(player_name)
    local mats = M.get_materials(player_name)
    if #mats == 0 then return nil end
    return table.concat({
        "--- PLAYER-SELECTED BUILD MATERIALS ---",
        "The player has explicitly chosen the following node(s) for this build.",
        "Prefer these exact node names when generating tool_calls.",
        "Nodes: " .. table.concat(mats, ", "),
        "--- END MATERIALS ---",
    }, "\n")
end

-- ============================================================
-- Registry-Filter
-- ============================================================

local function build_candidate_list(filter)
    filter = (filter or ""):lower():trim()
    local candidates = {}

    for name, def in pairs(core.registered_nodes) do
        if not name:match("^__builtin")
            and name ~= "air" and name ~= "ignore"
        then
            if filter == ""
                or name:lower():find(filter, 1, true)
                or (def.description and def.description:lower():find(filter, 1, true))
            then
                table.insert(candidates, name)
            end
        end
    end

    table.sort(candidates)
    return candidates
end

-- ============================================================
-- Formspec Builder
-- ============================================================

-- Berechnet Seitenzahl
local function get_page_info(total, per_page, current_page)
    local total_pages = math.max(1, math.ceil(total / per_page))
    current_page = math.max(1, math.min(current_page, total_pages))
    local first = (current_page - 1) * per_page + 1
    local last  = math.min(total, current_page * per_page)
    return current_page, total_pages, first, last
end

local ITEMS_PER_PAGE = COLS * 6  -- 6 Zeilen = 48 Kacheln pro Seite

function M.show(player_name)
    local sess       = get_session(player_name)
    local filter     = sess.filter or ""
    local candidates = build_candidate_list(filter)
    local total      = #candidates

    local page, total_pages, first, last =
        get_page_info(total, ITEMS_PER_PAGE, sess.page)
    sess.page = page  -- korrigierte Seite zurückschreiben

    local selected_count = 0
    for _ in pairs(sess.materials) do selected_count = selected_count + 1 end

    -- ── Dimensionen ────────────────────────────────────────
    local W       = COLS * (TILE_SIZE + TILE_PAD) + 0.5
    local HDR_H   = 0.9
    local SRCH_H  = 0.7
    local INFO_H  = 0.4
    local GRID_H  = 6 * (TILE_SIZE + TILE_PAD)
    local NAV_H   = 0.7
    local BTN_H   = 0.75
    local PAD     = 0.25
    local H       = HDR_H + PAD + SRCH_H + PAD + INFO_H + PAD + GRID_H + PAD + NAV_H + PAD + BTN_H + PAD

    local fs = {
        "formspec_version[6]",
        "size[" .. string.format("%.2f", W) .. "," .. string.format("%.2f", H) .. "]",
        "bgcolor[#0d0d0d;both]",
        "style_type[*;bgcolor=#181818;textcolor=#e0e0e0]",
    }

    -- ── Header ─────────────────────────────────────────────
    table.insert(fs, "box[0,0;" .. string.format("%.2f", W) .. "," .. HDR_H .. ";#1e1e2e]")
    table.insert(fs, "label[" .. PAD .. ",0.35;⚙ Build Materials — "
        .. core.formspec_escape(player_name)
        .. " (" .. selected_count .. " selected)]")
    table.insert(fs, "style[close_picker;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, "button[" .. string.format("%.2f", W - PAD - 2.0) .. ",0.12;2.0,0.65;close_picker;✕ Close]")

    local y = HDR_H + PAD

    -- ── Suchfeld ────────────────────────────────────────────
    local field_w = W - PAD * 2 - 2.6
    table.insert(fs, "field[" .. PAD .. "," .. y .. ";" .. string.format("%.2f", field_w) .. "," .. SRCH_H
        .. ";filter;;" .. core.formspec_escape(filter) .. "]")
    table.insert(fs, "style[filter;bgcolor=#111122;textcolor=#ccccff]")
    table.insert(fs, "field_close_on_enter[filter;false]")
    table.insert(fs, "style[do_filter;bgcolor=#1a1a3a;textcolor=#aaaaff]")
    table.insert(fs, "button[" .. string.format("%.2f", PAD + field_w + 0.1) .. "," .. y
        .. ";2.4," .. SRCH_H .. ";do_filter;⟳ Search]")
    y = y + SRCH_H + PAD

    -- ── Info-Zeile + Toggle-All ─────────────────────────────
    local info_str
    if total == 0 then
        info_str = "No nodes found"
    else
        info_str = string.format("%d node(s) — page %d/%d", total, page, total_pages)
    end
    table.insert(fs, "label[" .. PAD .. "," .. (y + 0.05) .. ";" .. core.formspec_escape(info_str) .. "]")

    -- Toggle-All Button (alle auf dieser Seite ein/aus)
    local page_nodes = {}
    for i = first, last do
        table.insert(page_nodes, candidates[i])
    end
    local page_all_selected = #page_nodes > 0
    for _, n in ipairs(page_nodes) do
        if not sess.materials[n] then page_all_selected = false; break end
    end
    local toggle_label = page_all_selected and "☑ Deselect Page" or "☐ Select Page"
    local toggle_color = page_all_selected and "#2a4a2a" or "#333344"
    table.insert(fs, "style[toggle_page;bgcolor=" .. toggle_color .. ";textcolor=#ccffcc]")
    table.insert(fs, "button[" .. string.format("%.2f", W - PAD - 3.5) .. "," .. (y - 0.05)
        .. ";3.5," .. INFO_H+0.1 .. ";toggle_page;" .. toggle_label .. "]")
    y = y + INFO_H + PAD

    -- ── Kachel-Grid ────────────────────────────────────────
    -- Jede Kachel = item_image_button (Icon) + farbiger Hintergrund wenn aktiv
    local col = 0
    local row = 0
    local IMG  = TILE_SIZE - 0.25
    local STEP = TILE_SIZE + TILE_PAD

    for idx, node_name in ipairs(page_nodes) do
        local tx = PAD + col * STEP
        local ty = y  + row * STEP

        local is_sel = sess.materials[node_name] == true

        -- Hintergrund-Box: grün wenn selektiert, dunkel wenn nicht
        local bg_color = is_sel and "#1a3a1a" or "#1a1a1a"
        table.insert(fs, "box[" .. string.format("%.2f,%.2f;%.2f,%.2f", tx, ty, TILE_SIZE, TILE_SIZE)
            .. ";" .. bg_color .. "]")

        -- Item-Image-Button (klickbar, zeigt Icon)
        -- button-name enkodiert den Kandidaten-Index: "tile_N"
        local btn_name = "tile_" .. tostring((page - 1) * ITEMS_PER_PAGE + idx)
        -- item_image_button[x,y;w,h;item;name;label]
        table.insert(fs, "item_image_button["
            .. string.format("%.2f,%.2f;%.2f,%.2f", tx + 0.05, ty + 0.05, IMG, IMG)
            .. ";" .. core.formspec_escape(node_name)
            .. ";" .. btn_name .. ";]")

        -- Checkmark-Label oben rechts wenn selektiert
        if is_sel then
            table.insert(fs, "label["
                .. string.format("%.2f,%.2f", tx + TILE_SIZE - 0.38, ty + 0.18)
                .. ";§(c=#00ff00)✔]")
        end

        -- Tooltip: Node-Name
        local def = core.registered_nodes[node_name]
        local desc = (def and def.description and def.description ~= "")
            and def.description or node_name
        table.insert(fs, "tooltip[" .. btn_name .. ";"
            .. core.formspec_escape(desc .. "\n" .. node_name) .. "]")

        col = col + 1
        if col >= COLS then
            col = 0
            row = row + 1
        end
    end

    y = y + GRID_H + PAD

    -- ── Navigation ─────────────────────────────────────────
    local nav_btn_w = 2.2
    if total_pages > 1 then
        table.insert(fs, "style[page_prev;bgcolor=#222233;textcolor=#aaaaff]")
        table.insert(fs, "button[" .. PAD .. "," .. y .. ";" .. nav_btn_w .. "," .. NAV_H .. ";page_prev;◀ Prev]")
        table.insert(fs, "style[page_next;bgcolor=#222233;textcolor=#aaaaff]")
        table.insert(fs, "button[" .. string.format("%.2f", W - PAD - nav_btn_w) .. "," .. y
            .. ";" .. nav_btn_w .. "," .. NAV_H .. ";page_next;Next ▶]")
    end
    y = y + NAV_H + PAD

    -- ── Bottom Buttons ──────────────────────────────────────
    local b_w = (W - PAD * 3) / 2
    table.insert(fs, "style[clear_all;bgcolor=#3a1a1a;textcolor=#ff8888]")
    table.insert(fs, "button[" .. PAD .. "," .. y .. ";" .. string.format("%.2f", b_w) .. "," .. BTN_H
        .. ";clear_all;✕ Clear All Selected]")

    table.insert(fs, "style[close_and_back;bgcolor=#1a2a1a;textcolor=#aaffaa]")
    table.insert(fs, "button[" .. string.format("%.2f", PAD * 2 + b_w) .. "," .. y
        .. ";" .. string.format("%.2f", b_w) .. "," .. BTN_H .. ";close_and_back;✓ Done]")

    core.show_formspec(player_name, "llm_connect:material_picker", table.concat(fs))
end

-- ============================================================
-- Formspec Handler
-- ============================================================

function M.handle_fields(player_name, formname, fields)
    if not formname:match("^llm_connect:material_picker") then
        return false
    end

    local sess = get_session(player_name)
    local candidates = build_candidate_list(sess.filter)
    local total      = #candidates

    -- Filter aktualisieren (live)
    if fields.filter ~= nil then
        sess.filter = fields.filter
    end

    -- ── Search / Filter ──────────────────────────────────
    if fields.do_filter or fields.key_enter_field == "filter" then
        sess.page = 1
        M.show(player_name)
        return true
    end

    -- ── Paginierung ──────────────────────────────────────
    local page, total_pages = get_page_info(total, ITEMS_PER_PAGE, sess.page)

    if fields.page_prev then
        sess.page = math.max(1, page - 1)
        M.show(player_name)
        return true
    end

    if fields.page_next then
        sess.page = math.min(total_pages, page + 1)
        M.show(player_name)
        return true
    end

    -- ── Toggle Page ──────────────────────────────────────
    if fields.toggle_page then
        local _, _, first, last = get_page_info(total, ITEMS_PER_PAGE, sess.page)
        -- Prüfen ob alle selektiert
        local all_sel = true
        for i = first, last do
            if not sess.materials[candidates[i]] then all_sel = false; break end
        end
        -- Toggle
        for i = first, last do
            if all_sel then
                sess.materials[candidates[i]] = nil
            else
                sess.materials[candidates[i]] = true
            end
        end
        M.show(player_name)
        return true
    end

    -- ── Clear All ────────────────────────────────────────
    if fields.clear_all then
        sess.materials = {}
        M.show(player_name)
        return true
    end

    -- ── Close / Done ─────────────────────────────────────
    if fields.close_picker or fields.close_and_back or fields.quit then
        -- Signalisierung ans chat_gui: Picker schließen → Chat-GUI wieder öffnen
        -- (wird in handle_fields von chat_gui.lua / init.lua gehandelt)
        return true
    end

    -- ── Kachel-Buttons: tile_N ────────────────────────────
    -- Format: tile_<global_index>  (1-basiert über alle Seiten)
    for field_name, _ in pairs(fields) do
        local global_idx = field_name:match("^tile_(%d+)$")
        if global_idx then
            global_idx = tonumber(global_idx)
            local node = candidates[global_idx]
            if node then
                if sess.materials[node] then
                    sess.materials[node] = nil
                    core.chat_send_player(player_name, "[LLM] ✕ " .. node)
                else
                    sess.materials[node] = true
                    core.chat_send_player(player_name, "[LLM] ✓ " .. node)
                end
            end
            M.show(player_name)
            return true
        end
    end

    return true
end

-- ============================================================
core.log("action", "[llm_connect] material_picker.lua v2.0 loaded")
return M
