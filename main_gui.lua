-- ===========================================================================
--  main_gui.lua — LLM Connect 1.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Main UI: chat interface + addon panel sub-formspec.
--  Replaces chat_gui.lua from 0.9.0.
--
--  Changes vs 0.9.0 chat_gui:
--    - WorldEdit mode buttons replaced by: Config | IDE | Skills
--    - Skills sub-formspec (llm_connect:main_addons) lists all registered
--      skills/addons and lets the player toggle them per-session
--    - v1.1.0-dev: llm_agent privilege gates Lua-first agent mode
--    - basic_context replaces chat_context.lua (1.0 context provider)
--    - All references to we_agency, material_picker removed
--
--  Formspec names used:
--    llm_connect:main         — main chat window
--    llm_connect:main_addons  — skills panel (sub-formspec, same session)
--
--  PUBLIC API:
--    M.show(player_name)
--    M.show_skills(player_name)
--    M.handle_fields(player_name, formname, fields) → bool
--
-- ===========================================================================

local core = core
local M    = {}

-- ===========================================================================
-- Privilege helpers
-- llm_root implies llm + llm_dev + llm_agent
-- ===========================================================================

local function get_policy()
    return _G.llm_connect and _G.llm_connect.policy
end

local function raw_priv(name, priv)
    local policy = get_policy()
    if policy and policy.raw_priv then return policy.raw_priv(name, priv) end
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

local function has_priv(name, priv)
    local policy = get_policy()
    if policy and policy.has_priv then return policy.has_priv(name, priv) end
    if raw_priv(name, "llm_root") then return true end
    return raw_priv(name, priv)
end

local function can_chat(name)
    local policy = get_policy()
    return policy and policy.can_chat and policy.can_chat(name) or has_priv(name, "llm")
end

local function can_ide(name)
    local policy = get_policy()
    return policy and policy.can_ide and policy.can_ide(name) or has_priv(name, "llm_dev")
end

local function can_agent(name)
    local policy = get_policy()
    return policy and policy.can_agent and policy.can_agent(name) or has_priv(name, "llm_agent")
end

local function can_config(name)
    local policy = get_policy()
    return policy and policy.can_config and policy.can_config(name) or raw_priv(name, "llm_root")
end

-- ===========================================================================
-- Registry / agent helpers (resolved at call time to avoid circular deps)
-- ===========================================================================

local function get_registry()
    return _G.llm_connect and _G.llm_connect.registry
end

local function get_agent()
    return _G.llm_connect and _G.llm_connect.agent
end

local function get_llm_api()
    if not _G.llm_api then error("[main_gui] llm_api not available") end
    return _G.llm_api
end

-- ===========================================================================
-- Session
-- ===========================================================================

local sessions = {}

local function get_session(name)
    if not sessions[name] then
        sessions[name] = {
            history         = {},   -- chat message history [{role, content, status_line?}]
            last_input      = "",   -- preserved across show() calls
            iter_preference = nil,  -- nil = use server default
                        chat_scroll     = 0,    -- 0 = top, 1000 = bottom
        }
    end
    return sessions[name]
end

core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

-- ===========================================================================
-- History renderer — scroll_container mit gestapelten read-only textareas
--
-- Je Nachricht eine textarea mit name="" (read-only, kein Luanti-Caching).
-- Request (user) und Response (assistant) visuell differenziert.
-- Höhenschätzung: ceil(#text / CHARS_PER_LINE) Zeilen × LINE_H + vertikal PAD.
-- ===========================================================================

local CHAT_W              = 15.5   -- Referenzbreite für die Wrap-Schätzung
local CHARS_PER_LINE      = 88     -- Zeichen pro Zeile bei CHAT_W
local LINE_H              = 0.52   -- Höhe einer Textzeile in Formspec-Einheiten
local MSG_HEADER_H        = 0.44   -- Platz für Sender / Statuszeile
local MSG_STATUS_H        = 0.34   -- zusätzliche Meta-Zeile für Live-Feedback
local MSG_TEXT_PAD_B      = 0.12   -- unterer Abstand des Textbereichs
local MSG_PAD_V           = 0.18   -- zusätzliches vertikales Kartenpadding
local MSG_GAP             = 0.16   -- Lücke zwischen Nachrichten
local USER_CARD_INSET     = 1.15   -- User-Karten leicht nach rechts versetzen
local ASSISTANT_CARD_INSET = 0.10  -- Assistant-Karten fast vollbreit

local function estimate_wrapped_lines(text, width)
    if not text or text == "" then return 1 end
    local chars_per_line = math.max(18, math.floor(CHARS_PER_LINE * (width / CHAT_W)))
    local lines = 0
    for _ in text:gmatch("\n") do lines = lines + 1 end
    for segment in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines = lines + math.max(0, math.ceil(#segment / chars_per_line) - 1)
    end
    return math.max(1, lines + 1)
end

local function estimate_msg_height(msg, card_w)
    local text = (msg and msg.content) or ""
    local status_line = (msg and msg.status_line) or ""
    local text_lines = estimate_wrapped_lines(text, math.max(2.0, card_w - 0.34))
    local h = MSG_HEADER_H + (text_lines * LINE_H) + MSG_TEXT_PAD_B + MSG_PAD_V
    if status_line ~= "" then
        h = h + MSG_STATUS_H
    end
    return h
end

local function build_chat_history(fs, session, x, y, w, scroll_h)
    -- scroll_container — Scrollbar rechts davon, außerhalb
    local SCROLLBAR_W = 0.3
    local inner_w     = w - SCROLLBAR_W - 0.1

    -- Gesamthöhe des Inhalts berechnen
    local total_h = MSG_GAP
    local msg_heights = {}
    for _, msg in ipairs(session.history) do
        if msg.role ~= "system" then
            local is_user = msg.role == "user"
            local card_inset = is_user and USER_CARD_INSET or ASSISTANT_CARD_INSET
            local card_w = inner_w - card_inset
            local h = estimate_msg_height(msg, card_w)
            table.insert(msg_heights, h)
            total_h = total_h + h + MSG_GAP
        end
    end
    total_h = math.max(total_h, scroll_h)

    local scroll_val  = session.chat_scroll or 0
    table.insert(fs, string.format(
        "scroll_container[%.2f,%.2f;%.2f,%.2f;chat_scroll;vertical;%.2f]",
        x, y, inner_w, scroll_h, scroll_val))

    -- Style einmalig setzen: transparenter Hintergrund, kein Border
    table.insert(fs, "style_type[textarea;textcolor=#d0d0d0;bgcolor=#00000000;border=false]")

    local cy    = MSG_GAP
    local msg_i = 0
    for _, msg in ipairs(session.history) do
        if msg.role ~= "system" then
            msg_i = msg_i + 1
            local mh          = msg_heights[msg_i]
            local is_user     = msg.role == "user"
            local content     = msg.content or ""
            local status_line = msg.status_line or ""

            -- Leicht versetzte Karten = chat-artiger statt Log-Fullwidth-Look
            local lx     = is_user and USER_CARD_INSET or ASSISTANT_CARD_INSET
            local card_w = inner_w - lx

            -- Hintergrundfarbe: User = blau getönt, Assistant = grün getönt
            local bg_color = is_user and "#142033" or "#101a13"

            -- Hintergrundbox
            table.insert(fs, string.format("box[%.2f,%.2f;%.2f,%.2f;%s]",
                lx, cy, card_w, mh, bg_color))

            -- Linker Akzentbalken: blau für User, grün für Assistant
            local accent = is_user and "#2e6cff" or "#2f9b52"
            table.insert(fs, string.format("box[%.2f,%.2f;0.06,%.2f;%s]",
                lx, cy, mh, accent))

            -- Subtiler Header-Streifen für bessere Trennung
            table.insert(fs, string.format("box[%.2f,%.2f;%.2f,0.34;%s]",
                lx + 0.06, cy, card_w - 0.06, is_user and "#172841" or "#132218"))

            -- Absender-Label oben links
            local sender_color = is_user and "#9bc0ff" or "#9be2a2"
            local sender_label = is_user and "You" or "LLM"
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                lx + 0.20, cy + 0.12,
                core.colorize(sender_color, sender_label)))

            local text_y = cy + MSG_HEADER_H
            if status_line ~= "" then
                table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                    lx + 1.00, cy + 0.12,
                    core.colorize(is_user and "#6f89b3" or "#6ab47c",
                        core.formspec_escape(status_line))))
                text_y = text_y + MSG_STATUS_H
            end

            -- Nachrichtentext als read-only textarea (name="" → kein Caching)
            local text_h = math.max(LINE_H, mh - (text_y - cy) - MSG_TEXT_PAD_B)
            table.insert(fs, string.format(
                "textarea[%.2f,%.2f;%.2f,%.2f;;;%s]",
                lx + 0.18, text_y, card_w - 0.28, text_h,
                core.formspec_escape(content)))

            cy = cy + mh + MSG_GAP
        end
    end

    -- Leerer Platzhalter wenn keine History
    if msg_i == 0 then
        table.insert(fs, string.format("label[%.2f,%.2f;%s]",
            0.3, 0.4,
            core.colorize("#444444", "Noch keine Nachrichten — schreib etwas!")))
    end

    table.insert(fs, "scroll_container_end[]")

    -- Scrollbar außerhalb des containers
    table.insert(fs, string.format(
        "scrollbar[%.2f,%.2f;%.2f,%.2f;vertical;chat_scroll;%.2f]",
        x + inner_w + 0.1, y, SCROLLBAR_W, scroll_h, scroll_val))
end

-- ===========================================================================
-- M.show — main chat window
-- ===========================================================================

function M.show(name)
    if not can_chat(name) then
        core.chat_send_player(name, "[LLM] Missing privilege: llm")
        return
    end

    local session = get_session(name)

    local W        = 16.0
    local H        = 12.0
    local PAD      = 0.25
    local HEADER_H = 1.8
    local INPUT_H  = 0.7
    local CHAT_H   = H - HEADER_H - INPUT_H - (PAD * 6)

    local fs = {
        "formspec_version[6]",
        "size[" .. W .. "," .. H .. "]",
        "bgcolor[#0f0f0f;both]",
        "style_type[*;bgcolor=#1a1a1a;textcolor=#e0e0e0]",
    }

    -- ── Header box ───────────────────────────────────────────
    table.insert(fs, "box[0,0;" .. W .. "," .. HEADER_H .. ";#202020]")
    table.insert(fs, "label[" .. PAD .. ",0.30;LLM Connect — " .. core.formspec_escape(name) .. "]")

    -- ── Header row 1 (right side): Config (root only) ────────
    local right_x = W - PAD
    if can_config(name) then
        right_x = right_x - 2.2
        table.insert(fs, "style[open_config;bgcolor=#2a2a1a;textcolor=#ffeeaa]")
        table.insert(fs, "button[" .. right_x .. ",0.08;2.2,0.65;open_config;⚙ Config]")
        table.insert(fs, "tooltip[open_config;Open LLM configuration (llm_root only)]")
    end

    -- ── Header row 2: IDE | Skills | [iter stepper] ──
    local bx = PAD

    if can_ide(name) then
        table.insert(fs, "style[open_ide;bgcolor=#1a1a2a;textcolor=#aaaaff]")
        table.insert(fs, "button[" .. bx .. ",0.95;2.5,0.65;open_ide;◈ IDE]")
        table.insert(fs, "tooltip[open_ide;Open Smart Lua IDE (llm_dev)]")
        bx = bx + 2.5 + 0.15
    end

    if can_agent(name) then
        local registry    = get_registry()
        local addon_count = 0
        local active_count = 0
        if registry then
            local status = registry.get_status(name)
            addon_count  = #status
            for _, s in ipairs(status) do
                if s.effective then active_count = active_count + 1 end
            end
        end
        local addon_label = "⬡ Skills"
        if addon_count > 0 then
            addon_label = "⬡ Skills (" .. active_count .. "/" .. addon_count .. ")"
        end
        local addon_color = active_count > 0 and "#1a2a1a" or "#252525"
        table.insert(fs, "style[open_addons;bgcolor=" .. addon_color .. ";textcolor=#aaffaa]")
        table.insert(fs, "button[" .. bx .. ",0.95;3.6,0.65;open_addons;" .. addon_label .. "]")
        table.insert(fs, "tooltip[open_addons;Manage Lua-first skills. Send uses action-aware mode only when at least one skill is active.]")
        bx = bx + 3.6 + 0.15

        -- ── Iteration stepper (right-aligned in row 2) ───────
        -- Shows as: [◀] N iter [▶]   e.g.  ◀ 4 iter ▶
        -- Player picks 1..server_max. nil = server default.
        local srv_max = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
        local iter    = session.iter_preference or srv_max
        -- Clamp in case server_max changed since last session
        iter = math.max(1, math.min(iter, srv_max))

        local STEP_W  = 1.0   -- dec/inc button width
        local DISP_W  = 2.4   -- centre display width
        local stepper_w = STEP_W * 2 + DISP_W
        local sx = W - PAD - stepper_w

        -- Dim dec button at minimum
        if iter <= 1 then
            table.insert(fs, "style[iter_dec;bgcolor=#1a1a1a;textcolor=#444444]")
        else
            table.insert(fs, "style[iter_dec;bgcolor=#252525;textcolor=#aaaaaa]")
        end
        table.insert(fs, "button[" .. string.format("%.2f", sx) .. ",0.95;" .. STEP_W .. ",0.65;iter_dec;◀]")

        -- Display: current / max
        local iter_color = (iter == srv_max) and "#ffaa44" or (iter == 1 and "#aaaaaa" or "#e0e0e0")
        local iter_lbl   = iter == srv_max and (iter .. " iter ⚠") or (iter .. " iter")
        table.insert(fs, "box[" .. string.format("%.2f", sx + STEP_W) .. ",0.95;" .. DISP_W .. ",0.65;#1a1a1a]")
        table.insert(fs, "label[" .. string.format("%.2f", sx + STEP_W + DISP_W/2 - 0.5) .. ",1.20;"
            .. core.colorize(iter_color, iter_lbl) .. "]")
        table.insert(fs, "tooltip[iter_dec;Fewer loop iterations — agent stops earlier]")

        -- Dim inc button at server max
        if iter >= srv_max then
            table.insert(fs, "style[iter_inc;bgcolor=#1a1a1a;textcolor=#444444]")
        else
            table.insert(fs, "style[iter_inc;bgcolor=#252525;textcolor=#aaaaaa]")
        end
        table.insert(fs, "button[" .. string.format("%.2f", sx + STEP_W + DISP_W) .. ",0.95;" .. STEP_W .. ",0.65;iter_inc;▶]")
        table.insert(fs, "tooltip[iter_inc;More loop iterations — max set by server (" .. srv_max .. ")]")
    end

    -- Agent running indicator
    local agent = get_agent()
    if agent and agent.is_running(name) then
        table.insert(fs, "style[agent_cancel;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
        table.insert(fs, "button[" .. PAD .. ",0.95;2.8,0.65;agent_cancel;✕ Stop Agent]")
        table.insert(fs, "tooltip[agent_cancel;Cancel the currently running agent loop]")
    end

    -- ── Chat history ─────────────────────────────────────────
    local history_y = HEADER_H + PAD
    build_chat_history(fs, session, PAD, history_y, W - PAD*2, CHAT_H)

    -- ── Input row ────────────────────────────────────────────
    local input_y = history_y + CHAT_H + PAD
    table.insert(fs, "field[" .. PAD .. "," .. input_y .. ";"
        .. (W - PAD*2 - 2.5) .. "," .. INPUT_H
        .. ";input;;" .. core.formspec_escape(session.last_input) .. "]")
    table.insert(fs, "button[" .. (W - PAD - 2.2) .. "," .. input_y
        .. ";2.2," .. INPUT_H .. ";send;Send]")
    table.insert(fs, "field_close_on_enter[input;false]")

    -- ── Toolbar ──────────────────────────────────────────────
    local tb_y = input_y + INPUT_H + PAD
    table.insert(fs, "button[" .. PAD .. "," .. tb_y .. ";2.8,0.75;clear;Clear Chat]")

    core.show_formspec(name, "llm_connect:main", table.concat(fs))
end

-- ===========================================================================
-- M.show_skills — skills panel sub-formspec
--
-- Layout modelled after the sound tab of ide_asset_picker:
--   - Two-column list of registered skills
--   - Each row: toggle button (green=active / grey=off) + label + tool count
--   - Availability and privilege indicated inline
--   - Reset + Close buttons at bottom
-- ===========================================================================

function M.show_skills(name)
    if not can_agent(name) then
        core.chat_send_player(name, "[LLM] Missing privilege: llm_agent (or llm_root)")
        return
    end

    local registry = get_registry()
    if not registry then
        core.chat_send_player(name, "[LLM] Skill registry not available")
        return
    end

    local status_list = registry.get_status(name)

    -- ── Layout — same outer dimensions as main_gui ────────────
    -- Asset-picker style: dark bg, coloured header, scrollable card grid
    local W       = 16.0
    local H       = 12.0
    local PAD     = 0.25
    local HDR_H   = 0.9
    local INFO_H  = 0.45
    local ROW_H   = 1.38     -- taller rows: room for label + description + meta
    local ROW_PAD = 0.12
    local ROW_STEP = ROW_H + ROW_PAD
    local BTN_H   = 0.75
    local COLS    = 2
    local col_gap = 0.2
    local col_w   = (W - PAD * 2 - col_gap) / COLS
    local rows_per_col = math.ceil(#status_list / COLS)
    local grid_h  = math.max(rows_per_col * ROW_STEP - ROW_PAD, ROW_H)

    -- Count effective addons for header badge
    local effective_n, total_n = 0, #status_list
    for _, s in ipairs(status_list) do
        if s.effective then effective_n = effective_n + 1 end
    end

    local fs = {
        "formspec_version[6]",
        string.format("size[%.2f,%.2f]", W, H),
        "bgcolor[#0d0d0d;both]",
        "style_type[*;bgcolor=#181818;textcolor=#e0e0e0]",
    }

    -- ── Header ───────────────────────────────────────────────
    table.insert(fs, string.format("box[0,0;%.2f,%.2f;#0d1a1a]", W, HDR_H))
    table.insert(fs, string.format("label[%.2f,0.35;Skills — %s   (%d/%d active)]",
        PAD, core.formspec_escape(name), effective_n, total_n))
    table.insert(fs, "style[addons_close;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, string.format("button[%.2f,0.12;2.0,0.65;addons_close;✕ Close]",
        W - PAD - 2.0))

    local y = HDR_H + PAD

    -- ── Info row ─────────────────────────────────────────────
    table.insert(fs, string.format("label[%.2f,%.2f;Toggle Lua-first skills for this session. Greyed = unavailable or missing privilege. JSON addons are deprecated.]",
        PAD, y + 0.05))
    y = y + INFO_H

    -- ── Addon card grid ───────────────────────────────────────
    if total_n == 0 then
        table.insert(fs, string.format("label[%.2f,%.2f;No skills registered yet.]",
            PAD, y + 0.3))
    else
        for i, s in ipairs(status_list) do
            local col_idx = math.floor((i - 1) / rows_per_col)
            local row_idx = (i - 1) % rows_per_col
            local tx = PAD + col_idx * (col_w + col_gap)
            local ty = y   + row_idx * ROW_STEP

            -- Normalize potentially partial skill status records defensively.
            local sid = tostring(s.id or ("skill_" .. tostring(i)))
            local slabel = tostring(s.label or s.name or sid)
            local sdesc = tostring(s.description or "")
            local sversion = tostring(s.version or "?")
            local sorigin = tostring(s.origin or "internal")
            local stool_count = tonumber(s.tool_count) or 0

            -- Card background — colour-coded by state
            local card_bg
            if not s.available or not s.has_priv then
                card_bg = "#1a1a1a"   -- greyed: dep missing or no priv
            elseif s.effective then
                card_bg = "#0d1a0d"   -- green tint: active
            else
                card_bg = "#1a1010"   -- red tint: disabled by player
            end
            table.insert(fs, string.format("box[%.2f,%.2f;%.2f,%.2f;%s]",
                tx, ty, col_w, ROW_H, card_bg))

            -- Left accent bar (3px wide) colour = state
            local bar_color = s.effective and "#2a6a2a"
                or (not s.available or not s.has_priv) and "#444444"
                or "#6a2a2a"
            table.insert(fs, string.format("box[%.2f,%.2f;0.06,%.2f;%s]",
                tx, ty, ROW_H, bar_color))

            -- Toggle button
            local btn_name  = "addon_toggle_" .. sid
            local toggle_w  = 1.1
            local btn_off   = not s.available or not s.has_priv
            local toggle_bg = btn_off    and "#252525"
                or s.enabled             and "#1a3a1a"
                or "#2a1a1a"
            local toggle_fg = btn_off    and "#555555"
                or s.enabled             and "#aaffaa"
                or "#aa4444"
            local toggle_lbl = btn_off and "N/A"
                or s.enabled            and "● ON"
                or "○ OFF"
            table.insert(fs, string.format("style[%s;bgcolor=%s;textcolor=%s]",
                btn_name, toggle_bg, toggle_fg))
            table.insert(fs, string.format("button[%.2f,%.2f;%.2f,%.2f;%s;%s]",
                tx + 0.1, ty + (ROW_H - 0.6) / 2, toggle_w, 0.6,
                btn_name, toggle_lbl))

            -- Label block: skill name + short description + meta info
            local lx = tx + 0.1 + toggle_w + 0.15

            -- Name line
            local name_color = (not s.available or not s.has_priv) and "#666666" or "#e0e0e0"
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                lx, ty + 0.18,
                core.colorize(name_color, core.formspec_escape(slabel))))

            -- Description line (truncated)
            local desc = sdesc
            if #desc > 42 then desc = desc:sub(1, 39) .. "…" end
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                lx, ty + 0.54,
                core.colorize("#888888", core.formspec_escape(desc))))

            -- Inline meta row lives inside the card instead of floating outside it
            local origin_tag = (sorigin == "extern" and "ext" or "int")
            local meta = core.colorize("#6f6f6f", "v" .. sversion)
                .. "  " .. core.colorize("#666688", tostring(stool_count) .. " tools")
                .. "  " .. core.colorize(sorigin == "extern" and "#4a8844" or "#444488", "[" .. origin_tag .. "]")
            if not s.available then
                meta = meta .. "  " .. core.colorize("#aa4422", "dep")
            end
            if not s.has_priv then
                meta = meta .. "  " .. core.colorize("#aa6622", "priv")
            end
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                lx, ty + 0.90,
                meta))

            -- Full tooltip
            table.insert(fs, "tooltip[" .. btn_name .. ";"
                .. core.formspec_escape(
                    s.label .. "  v" .. s.version
                    .. "\n" .. (s.description or "")
                    .. "\nTools: "      .. s.tool_count
                    .. "\nSource: "     .. s.origin
                    .. "\nAvailable: "  .. tostring(s.available)
                    .. "\nPrivilege: "  .. tostring(s.has_priv)
                    .. "\nEnabled: "    .. tostring(s.enabled)
                ) .. "]")
        end
    end

    -- ── Bottom bar ────────────────────────────────────────────
    local btn_y = H - BTN_H - PAD
    table.insert(fs, string.format("box[0,%.2f;%.2f,%.2f;#111111]",
        btn_y - PAD * 0.5, W, BTN_H + PAD * 1.5))
    table.insert(fs, string.format("button[%.2f,%.2f;3.2,%.2f;addons_reset;↺ Reset to Defaults]",
        PAD, btn_y, BTN_H))
    table.insert(fs, "tooltip[addons_reset;Clear per-player overrides — global defaults apply again]")

    core.show_formspec(name, "llm_connect:main_addons", table.concat(fs))
end

-- ===========================================================================
-- Agent live card helpers
-- ===========================================================================

local function update_last_assistant_card(session, body, status_line)
    for i = #session.history, 1, -1 do
        if session.history[i].role == "assistant" then
            if body ~= nil then session.history[i].content = body end
            if status_line ~= nil then session.history[i].status_line = status_line end
            return
        end
    end
end

local function should_stick_to_bottom(session)
    if not session then return false end
    local scroll = tonumber(session.chat_scroll) or 0
    return scroll >= 900
end

local function maybe_scroll_to_bottom(session)
    if should_stick_to_bottom(session) then
        session.chat_scroll = 1000
    end
end

local function compact_status_line(iter, max_iter, plan, results)
    local ok_count, fail_count = 0, 0
    for _, r in ipairs(results or {}) do
        if r.tool ~= "*" then
            if r.ok then
                ok_count = ok_count + 1
            else
                fail_count = fail_count + 1
            end
        end
    end

    local prefix = string.format("Step %d/%d", iter, max_iter)
    local summary = tostring(plan or "working")
    summary = summary:gsub("\n+", " "):gsub("%s+", " ")
    if #summary > 46 then
        summary = summary:sub(1, 43) .. "..."
    end

    if ok_count == 0 and fail_count == 0 then
        return prefix .. " — " .. summary
    end
    return string.format("%s — %s  [✓%d ✗%d]", prefix, summary, ok_count, fail_count)
end

-- ===========================================================================
-- Send: dispatch to agent or plain chat
-- ===========================================================================

local function do_send(name, input, session)
    local llm_api  = get_llm_api()
    local agent    = get_agent()
    local registry = get_registry()

    -- v1.1.0-dev dual-channel: use agent only when at least one skill is active.
    -- Otherwise the same Send button is plain chat. Loaded skills are OFF by default.
    local active_skill_count = 0
    if registry and registry.get_status then
        local status = registry.get_status(name)
        for _, s in ipairs(status or {}) do
            if s.effective then active_skill_count = active_skill_count + 1 end
        end
    end
    local use_agent = can_agent(name) and agent ~= nil and active_skill_count > 0

    if use_agent then
        table.insert(session.history, { role = "user", content = input })
        table.insert(session.history, {
            role = "assistant",
            content = "…",
            status_line = "Preparing action-aware chat…",
        })
        maybe_scroll_to_bottom(session)
        M.show(name)

        local srv_max  = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
        local iter_cap = math.max(1, math.min(session.iter_preference or srv_max, srv_max))

        agent.run(name, input, { max_iterations = iter_cap }, {
            on_thought = function(thought)
                local preview = tostring(thought or "thinking")
                preview = preview:gsub("\n+", " "):gsub("%s+", " ")
                if #preview > 80 then
                    preview = preview:sub(1, 77) .. "..."
                end
                update_last_assistant_card(session, nil, "💭 " .. preview)
                maybe_scroll_to_bottom(session)
                M.show(name)
            end,
            on_step = function(iter, plan, results)
                local body = nil
                local first_tool_line
                for _, r in ipairs(results or {}) do
                    if r.tool ~= "*" then
                        local mark = r.ok and "✓" or "✗"
                        local msg = tostring(r.message or ""):gsub("\n+", " "):gsub("%s+", " ")
                        first_tool_line = string.format("%s %s — %s", mark, tostring(r.tool), msg)
                        break
                    end
                end
                if first_tool_line and #first_tool_line > 92 then
                    first_tool_line = first_tool_line:sub(1, 89) .. "..."
                end
                if first_tool_line and first_tool_line ~= "" then
                    body = first_tool_line
                end
                update_last_assistant_card(session, body, compact_status_line(iter, iter_cap, plan, results))
                maybe_scroll_to_bottom(session)
                M.show(name)
            end,
            on_done = function(result)
                local summary = agent.format_results(result)
                update_last_assistant_card(session, summary, "")
                maybe_scroll_to_bottom(session)
                M.show(name)
            end,
            on_error = function(err)
                update_last_assistant_card(session, "✗ Error: " .. tostring(err), "Agent aborted")
                maybe_scroll_to_bottom(session)
                M.show(name)
            end,
        })

    else
        -- Plain chat mode: send history to LLM, append response
        local messages = {}
        local cfg = llm_api.config
        local max_h = cfg.context_max_history or 20

        local start = math.max(1, #session.history - max_h + 1)
        for i = start, #session.history do
            table.insert(messages, session.history[i])
        end

        table.insert(session.history, { role = "user", content = input })
        table.insert(messages,        { role = "user", content = input })

        local sys_prompt = core.settings:get("llm_chat_system_prompt") or ""
        sys_prompt = sys_prompt:match("^%s*(.-)%s*$")
        if sys_prompt ~= "" then
            table.insert(messages, 1, { role = "system", content = sys_prompt })
        end

        local basic_ctx = _G.basic_context
        if basic_ctx and basic_ctx.get then
            local ctx = basic_ctx.get(name)
            if ctx and ctx ~= "" then
                local pos = (sys_prompt ~= "") and 2 or 1
                table.insert(messages, pos, { role = "system", content = ctx })
            end
        end

        table.insert(session.history, { role = "assistant", content = "…" })
        maybe_scroll_to_bottom(session)
        M.show(name)

        llm_api.request(messages, function(result)
            for i = #session.history, 1, -1 do
                if session.history[i].role == "assistant" and session.history[i].content == "…" then
                    if result.success then
                        session.history[i].content = result.content or "(no response)"
                    else
                        session.history[i].content = "✗ Error: " .. (result.error or "unknown")
                    end
                    session.history[i].status_line = nil
                    break
                end
            end
            maybe_scroll_to_bottom(session)
            M.show(name)
        end, { timeout = llm_api.get_timeout("chat") })
    end
end

-- ===========================================================================
-- M.handle_fields
-- ===========================================================================

function M.handle_fields(name, formname, fields)
    if not can_chat(name) then return true end

    -- ── Skill panel ───────────────────────────────────────────
    if formname:match("^llm_connect:main_addons") then
        if not can_agent(name) then
            core.chat_send_player(name, "[LLM] Missing privilege: llm_agent (or llm_root)")
            return true
        end

        local registry = get_registry()
        if not registry then return false end

        -- Toggle buttons: addon_toggle_<id>
        for field_name in pairs(fields) do
            local addon_id = field_name:match("^addon_toggle_(.+)$")
            if addon_id then
                local current = registry.is_addon_enabled(name, addon_id)
                registry.set_player_addon(name, addon_id, not current)
                M.show_skills(name)
                return true
            end
        end

        if fields.addons_reset then
            registry.reset_player_addons(name)
            M.show_skills(name)
            return true
        end

        if fields.addons_close or fields.quit then
            M.show(name)
            return true
        end

        return true
    end

    -- ── Main window ──────────────────────────────────────────
    if not formname:match("^llm_connect:main") then return false end

    local session = get_session(name)

    if fields.chat_scroll then
        local scroll_val = tonumber(tostring(fields.chat_scroll):match("([%-%d%.]+)$"))
        if scroll_val then
            session.chat_scroll = math.max(0, math.min(1000, scroll_val))
        end
    end

    -- ── Iteration stepper buttons ────────────────────────────
    if fields.iter_dec and can_agent(name) then
        local srv_max = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
        local cur = session.iter_preference or srv_max
        session.iter_preference = math.max(1, cur - 1)
        M.show(name); return true

    elseif fields.iter_inc and can_agent(name) then
        local srv_max = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
        local cur = session.iter_preference or srv_max
        session.iter_preference = math.min(srv_max, cur + 1)
        M.show(name); return true

    -- Navigation buttons
    elseif fields.open_ide then
        if can_ide(name) and _G.ide_gui then
            _G.ide_gui.show(name)
        end
        return true

    elseif fields.open_config then
        if can_config(name) and _G.config_gui then
            _G.config_gui.show(name)
        end
        return true

    elseif fields.open_addons then
        if can_agent(name) then
            M.show_skills(name)
        end
        return true

    elseif fields.agent_cancel and can_agent(name) then
        local agent = get_agent()
        if agent then agent.cancel(name) end
        M.show(name)
        return true

    elseif fields.clear then
        session.history    = {}
        session.last_input = ""
        session.chat_scroll = 0
        M.show(name)
        return true

    -- Send
    elseif fields.send or fields.key_enter_field == "input" then
        local input = (fields.input or ""):match("^%s*(.-)%s*$")
        session.last_input = fields.input or ""
        if input == "" then return true end

        session.last_input = ""

        local llm_api = get_llm_api()
        if not llm_api.is_configured() then
            core.chat_send_player(name, "[LLM] Not configured — use /llm_config to set API key, URL, and model.")
            return true
        end

        do_send(name, input, session)
        return true
    end

    return true
end

-- ===========================================================================

core.log("action", "[main_gui] module loaded")

return M
