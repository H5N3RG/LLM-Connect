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

local function get_skills()
    local root = _G.llm_connect
    return root and (root.skills or root.skills_subsystem or root.registry)
end

local function get_agent()
    return _G.llm_connect and _G.llm_connect.agent
end

local function get_api()
    local root = _G.llm_connect
    local api = root and root.api
    if api then return api end
    return {
        request = function(_, callback) if callback then callback({ success = false, error = "api subsystem unavailable" }) end; return false end,
        chat = function(_, callback) if callback then callback({ success = false, error = "api subsystem unavailable" }) end; return false end,
        get_timeout = function() return 30 end,
    }
end

local function get_context()
    local root = _G.llm_connect
    return root and (root.context_modules or root.context or root.basic_context)
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
            agent_mode      = false, -- explicit opt-in for action-aware agent routing
            chat_scroll     = 0,    -- 0 = top, 1000 = bottom
        }
    end
    return sessions[name]
end

core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

-- ===========================================================================
-- History renderer — scroll_container with stacked read-only textareas
--
-- One textarea per message with name="" (read-only, no Luanti caching).
-- Request (user) and response (assistant) are visually distinguished.
-- Height estimate: ceil(#text / CHARS_PER_LINE) lines × LINE_H + vertical padding.
-- ===========================================================================

local CHAT_W              = 15.5   -- Reference width for the wrap estimate
local CHARS_PER_LINE      = 88     -- Characters per line at CHAT_W
local LINE_H              = 0.52   -- Height of one text line in formspec units
local MSG_HEADER_H        = 0.44   -- Space for sender / status line
local MSG_STATUS_H        = 0.34   -- Additional meta line for live feedback
local MSG_TEXT_PAD_B      = 0.12   -- Bottom spacing of the text area
local MSG_PAD_V           = 0.18   -- Additional vertical card padding
local MSG_GAP             = 0.16   -- Gap between messages
local STEP_LINE_H         = 0.34   -- Compact agent step ledger row height
local USER_CARD_INSET     = 1.15   -- Shift user cards slightly to the right
local ASSISTANT_CARD_INSET = 0.10  -- Assistant cards are almost full width

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
    local steps = (msg and type(msg.steps) == "table") and msg.steps or {}
    local text_lines = estimate_wrapped_lines(text, math.max(2.0, card_w - 0.34))
    local h = MSG_HEADER_H + (text_lines * LINE_H) + MSG_TEXT_PAD_B + MSG_PAD_V
    if status_line ~= "" then
        h = h + MSG_STATUS_H
    end
    if #steps > 0 then
        h = h + math.min(#steps, 8) * STEP_LINE_H + 0.14
    end
    return h
end

local function compact_line(text, max_len)
    text = tostring(text or ""):gsub("\n+", " "):gsub("%s+", " ")
    max_len = max_len or 96
    if #text > max_len then return text:sub(1, max_len - 3) .. "..." end
    return text
end

local function build_chat_history(fs, session, x, y, w, scroll_h)
    -- scroll_container — scrollbar to the right, outside the container
    local SCROLLBAR_W = 0.3
    local inner_w     = w - SCROLLBAR_W - 0.1

    -- Calculate total content height
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

    -- Luanti scroll_container math:
    --   * the standalone scrollbar stores a value in the 0..1000 range
    --   * scroll_container's last argument is NOT that value; it is a
    --     conversion factor from scrollbar units to formspec units
    -- Therefore the factor must be derived from the virtual overflow height.
    -- Passing the scrollbar value itself here makes the content jump out of
    -- view after the first tiny scroll movement.
    local scroll_val = math.max(0, math.min(1000, tonumber(session.chat_scroll) or 0))
    local overflow_h = math.max(0, total_h - scroll_h)
    local scroll_factor = overflow_h / 1000

    table.insert(fs, string.format(
        "scroll_container[%.2f,%.2f;%.2f,%.2f;chat_scroll;vertical;%.4f]",
        x, y, inner_w, scroll_h, scroll_factor))

    -- Set style once: transparent background, no border
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
            local steps       = type(msg.steps) == "table" and msg.steps or {}

            -- Slightly offset cards = more chat-like than log-style full width
            local lx     = is_user and USER_CARD_INSET or ASSISTANT_CARD_INSET
            local card_w = inner_w - lx

            -- Background color: user = blue tinted, assistant = green tinted
            local bg_color = is_user and "#142033" or "#101a13"

            -- Background box
            table.insert(fs, string.format("box[%.2f,%.2f;%.2f,%.2f;%s]",
                lx, cy, card_w, mh, bg_color))

            -- Left accent bar: blue for user, green for assistant
            local accent = is_user and "#2e6cff" or "#2f9b52"
            table.insert(fs, string.format("box[%.2f,%.2f;0.06,%.2f;%s]",
                lx, cy, mh, accent))

            -- Subtle header strip for clearer separation
            table.insert(fs, string.format("box[%.2f,%.2f;%.2f,0.34;%s]",
                lx + 0.06, cy, card_w - 0.06, is_user and "#172841" or "#132218"))

            -- Sender label in the top-left corner
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

            if #steps > 0 then
                local first = math.max(1, #steps - 7)
                for si = first, #steps do
                    local step = steps[si]
                    local mark = tostring(step.mark or "•")
                    local color = tostring(step.color or "#8a8a8a")
                    local line = compact_line(step.text or "", 86)
                    table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                        lx + 0.20, text_y + 0.02,
                        core.colorize(color, mark .. " " .. core.formspec_escape(line))))
                    text_y = text_y + STEP_LINE_H
                end
                text_y = text_y + 0.08
            end

            -- Message text as read-only textarea (name="" → no caching)
            local text_h = math.max(LINE_H, mh - (text_y - cy) - MSG_TEXT_PAD_B)
            table.insert(fs, string.format(
                "textarea[%.2f,%.2f;%.2f,%.2f;;;%s]",
                lx + 0.18, text_y, card_w - 0.28, text_h,
                core.formspec_escape(content)))

            cy = cy + mh + MSG_GAP
        end
    end

    -- Empty placeholder when there is no history
    if msg_i == 0 then
        table.insert(fs, string.format("label[%.2f,%.2f;%s]",
            0.3, 0.4,
            core.colorize("#444444", "No messages yet — write something!")))
    end

    table.insert(fs, "scroll_container_end[]")

    -- Scrollbar outside the container. Keep the value range stable; the
    -- scroll_container factor above maps this 0..1000 range to actual content
    -- overflow in formspec units.
    table.insert(fs, "scrollbaroptions[min=0;max=1000;smallstep=25;largestep=120]")
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
    local agent = get_agent()
    local pending_permission = agent and agent.get_pending_permission and agent.get_pending_permission(name) or nil

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
        local skills      = get_skills()
        local addon_count = 0
        local active_count = 0
        if skills then
            local status = skills.get_status(name)
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
        table.insert(fs, "tooltip[open_addons;Manage Lua-first skills. Skills can be attached without enabling Agent Mode.]")
        bx = bx + 3.6 + 0.15

        local agent_label = session.agent_mode and "Agent ON" or "Agent OFF"
        local agent_color = session.agent_mode and "#1a2a1a" or "#2a1a1a"
        table.insert(fs, "style[agent_mode_toggle;bgcolor=" .. agent_color .. ";textcolor=#aaffaa]")
        table.insert(fs, "button[" .. bx .. ",0.95;2.6,0.65;agent_mode_toggle;" .. agent_label .. "]")
        table.insert(fs, "tooltip[agent_mode_toggle;Toggle action-aware Agent Mode. OFF sends normal chat even when skills are attached.]")
        bx = bx + 2.6 + 0.15

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
    if pending_permission then
        table.insert(fs, "style[agent_permit;bgcolor=#183018;textcolor=#bfffc0]")
        table.insert(fs, string.format("button[%.2f,%.2f;2.15,0.75;agent_permit;%s]",
            PAD + 3.0, tb_y, core.formspec_escape("● Permit")))
        table.insert(fs, "tooltip[agent_permit;"
            .. core.formspec_escape("Allow pending agent action: " .. tostring(pending_permission.summary or pending_permission.kind or "permission request"))
            .. "]")
        table.insert(fs, "style[agent_deny;bgcolor=#301818;textcolor=#ffc0c0]")
        table.insert(fs, string.format("button[%.2f,%.2f;1.85,0.75;agent_deny;%s]",
            PAD + 5.25, tb_y, core.formspec_escape("● Deny")))
        table.insert(fs, "tooltip[agent_deny;"
            .. core.formspec_escape("Deny pending agent action: " .. tostring(pending_permission.summary or pending_permission.kind or "permission request"))
            .. "]")
    end

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

    local skills = get_skills()
    if not skills then
        core.chat_send_player(name, "[LLM] Skill registry not available")
        return
    end

    local status_list = skills.get_status(name)

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
    table.insert(fs, string.format("label[%.2f,%.2f;Attach Lua-first skills to this player session. Root can manage player attachments in Config → Agent.]",
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

            -- Card background — deliberately low-drama, not a traffic light.
            local card_bg
            if not s.available or (not s.has_priv and not s.manual_attached) then
                card_bg = "#171717"   -- unavailable / missing priv
            elseif s.effective then
                card_bg = "#182018"   -- attached
            else
                card_bg = "#1a1a1f"   -- available but detached
            end
            table.insert(fs, string.format("box[%.2f,%.2f;%.2f,%.2f;%s]",
                tx, ty, col_w, ROW_H, card_bg))

            -- Left accent bar: subtle state hint, not red/green alarm UI.
            local bar_color = s.effective and "#4a6a4a"
                or (not s.available or (not s.has_priv and not s.manual_attached)) and "#3a3a3a"
                or "#4a4a66"
            table.insert(fs, string.format("box[%.2f,%.2f;0.06,%.2f;%s]",
                tx, ty, ROW_H, bar_color))

            -- Toggle button
            local btn_name  = "addon_toggle_" .. sid
            local toggle_w  = 1.1
            local btn_off   = not s.available or (not s.has_priv and not s.manual_attached)
            local toggle_bg = btn_off    and "#252525"
                or s.enabled             and "#263026"
                or "#242436"
            local toggle_fg = btn_off    and "#666666"
                or s.enabled             and "#d0ffd0"
                or "#bbbbff"
            local toggle_lbl = btn_off and "N/A"
                or s.enabled            and "ATTACHED"
                or "DETACHED"
            table.insert(fs, string.format("style[%s;bgcolor=%s;textcolor=%s]",
                btn_name, toggle_bg, toggle_fg))
            table.insert(fs, string.format("button[%.2f,%.2f;%.2f,%.2f;%s;%s]",
                tx + 0.1, ty + (ROW_H - 0.6) / 2, toggle_w, 0.6,
                btn_name, toggle_lbl))

            -- Label block: skill name + short description + meta info
            local lx = tx + 0.1 + toggle_w + 0.15

            -- Name line
            local name_color = (not s.available or (not s.has_priv and not s.manual_attached)) and "#666666" or "#e0e0e0"
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
            local is_external = sorigin == "external" or sorigin == "extern"
            local origin_tag = (is_external and "ext" or "int")
            local meta = core.colorize("#6f6f6f", "v" .. sversion)
                .. "  " .. core.colorize("#666688", tostring(stool_count) .. " tools")
                .. "  " .. core.colorize(is_external and "#4a8844" or "#444488", "[" .. origin_tag .. "]")
            if not s.available then
                meta = meta .. "  " .. core.colorize("#aa4422", "dep")
            end
            if s.manual_attached then
                meta = meta .. "  " .. core.colorize("#88aa88", "root")
            elseif not s.has_priv then
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
    table.insert(fs, string.format("button[%.2f,%.2f;3.2,%.2f;addons_reset;↺ Reset Attachments]",
        PAD, btn_y, BTN_H))
    table.insert(fs, "tooltip[addons_reset;Clear per-player skill attachments — global defaults apply again]")

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

local function append_last_assistant_step(session, mark, text, color)
    for i = #session.history, 1, -1 do
        local msg = session.history[i]
        if msg.role == "assistant" then
            msg.steps = msg.steps or {}
            msg.steps[#msg.steps + 1] = {
                mark = mark or "•",
                text = text or "",
                color = color or "#8a8a8a",
            }
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

local function result_step_line(iter, result)
    local mark = (result and result.ok) and "✓" or "✗"
    local color = (result and result.ok) and "#8fcf8f" or "#e07a7a"
    local tool = tostring(result and result.tool or "action")
    local msg = tostring(result and (result.message or result.error) or "")
    return mark, string.format("Step %d: %s — %s", tonumber(iter) or 0, tool, compact_line(msg, 86)), color
end

local function make_agent_callbacks(name, session, iter_cap)
    return {
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
                    local step_mark, step_text, step_color = result_step_line(iter, r)
                    append_last_assistant_step(session, step_mark, step_text, step_color)
                    break
                end
            end
            if not first_tool_line then
                append_last_assistant_step(session, "•", "Step " .. tostring(iter) .. ": " .. compact_line(plan, 86), "#8a9ccf")
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
            local agent = get_agent()
            local pending = agent and agent.get_pending_permission and agent.get_pending_permission(name) or nil
            if pending then
                update_last_assistant_card(session, nil, "Permission required")
            else
                local summary = agent and agent.format_results and agent.format_results(result) or "(agent completed)"
                update_last_assistant_card(session, summary, "")
            end
            maybe_scroll_to_bottom(session)
            M.show(name)
        end,
        on_error = function(err)
            update_last_assistant_card(session, "✗ Error: " .. tostring(err), "Agent aborted")
            maybe_scroll_to_bottom(session)
            M.show(name)
        end,
    }
end

-- ===========================================================================
-- Send: dispatch to agent or plain chat
-- ===========================================================================

local function do_send(name, input, session)
    local api      = get_api()
    local agent    = get_agent()
    local skills   = get_skills()

    -- Dual-channel agent mode is explicit. Attached skills remain available
    -- without turning every message into an agent run.
    local active_skill_count = 0
    if skills and skills.get_status then
        local status = skills.get_status(name)
        for _, s in ipairs(status or {}) do
            if s.effective then active_skill_count = active_skill_count + 1 end
        end
    end
    local use_agent = core.settings:get_bool("llm_agent_enabled", true) ~= false
        and session.agent_mode == true and can_agent(name) and agent ~= nil and active_skill_count > 0

    if use_agent then
        table.insert(session.history, { role = "user", content = input, mode = "agent" })
        table.insert(session.history, {
            role = "assistant",
            content = "…",
            status_line = "Preparing action-aware chat…",
            mode = "agent",
        })
        maybe_scroll_to_bottom(session)
        M.show(name)

        local srv_max  = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
        local iter_cap = math.max(1, math.min(session.iter_preference or srv_max, srv_max))

        agent.run(name, input, { max_iterations = iter_cap }, make_agent_callbacks(name, session, iter_cap))

    else
        -- Plain chat mode: send history to LLM, append response
        local messages = {}
        local cfg = api.get_config()
        local max_h = cfg.context_max_history or 20

        local start = math.max(1, #session.history - max_h + 1)
        for i = start, #session.history do
            local msg = session.history[i]
            -- Keep the request history mode-clean. The UI may show both plain
            -- chat and agent turns, but the plain chat API request must not
            -- inherit previous action-aware/tool-runtime turns.
            if msg and (msg.mode == nil or msg.mode == "chat") then
                table.insert(messages, { role = msg.role, content = msg.content })
            end
        end

        table.insert(session.history, { role = "user", content = input, mode = "chat" })
        table.insert(messages,        { role = "user", content = input })

        local sys_prompt = core.settings:get("llm_chat_system_prompt") or ""
        sys_prompt = sys_prompt:match("^%s*(.-)%s*$")
        if sys_prompt ~= "" then
            table.insert(messages, 1, { role = "system", content = sys_prompt })
        end

        local context = get_context()
        if context then
            local ctx_fn = context.get_chat or context.get
            if type(ctx_fn) == "function" then
                local ok, ctx = pcall(ctx_fn, name, "chat")
                if ok and ctx and ctx ~= "" then
                    local pos = (sys_prompt ~= "") and 2 or 1
                    table.insert(messages, pos, { role = "system", content = ctx })
                elseif not ok then
                    core.log("warning", "[main_gui] chat context failed: " .. tostring(ctx))
                end
            end
        end

        table.insert(session.history, { role = "assistant", content = "…", mode = "chat" })
        maybe_scroll_to_bottom(session)
        M.show(name)

        api.request(messages, function(result)
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
        end, { timeout = api.get_timeout("chat") })
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

        local skills = get_skills()
        if not skills then return false end

        -- Toggle buttons: addon_toggle_<id>
        for field_name in pairs(fields) do
            local addon_id = field_name:match("^addon_toggle_(.+)$")
            if addon_id then
                local current = skills.is_enabled(name, addon_id)
                skills.set_enabled(name, addon_id, not current)
                M.show_skills(name)
                return true
            end
        end

        if fields.addons_reset then
            skills.reset_player(name)
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
        if can_ide(name) then
            local gui = _G.llm_connect and _G.llm_connect.gui
            if gui and gui.show then
                gui.show(name, "ide")
            elseif _G.ide_gui and _G.ide_gui.show then
                _G.ide_gui.show(name)
            else
                core.chat_send_player(name, "[LLM] IDE GUI unavailable. Use /llm_health for details.")
            end
        end
        return true

    elseif fields.open_config then
        if can_config(name) then
            local gui = _G.llm_connect and _G.llm_connect.gui
            if gui and gui.show then
                gui.show(name, "config")
            elseif _G.config_gui and _G.config_gui.show then
                _G.config_gui.show(name)
            else
                core.chat_send_player(name, "[LLM] Config GUI unavailable. Use /llm_health for details.")
            end
        end
        return true

    elseif fields.open_addons then
        if can_agent(name) then
            M.show_skills(name)
        end
        return true

    elseif fields.agent_mode_toggle and can_agent(name) then
        session.agent_mode = not session.agent_mode
        M.show(name)
        return true

    elseif fields.agent_cancel and can_agent(name) then
        local agent = get_agent()
        if agent then agent.cancel(name) end
        M.show(name)
        return true

    elseif fields.agent_permit and can_agent(name) then
        local agent = get_agent()
        local pending = agent and agent.resolve_permission and agent.resolve_permission(name, true)
        if pending then
            append_last_assistant_step(session, "✓", "Permit: " .. compact_line(pending.summary or pending.kind, 92), "#8fcf8f")
            update_last_assistant_card(session, nil, "Permission granted — resuming")
            local srv_max  = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
            local iter_cap = math.max(1, math.min(session.iter_preference or srv_max, srv_max))
            if agent.resume then
                agent.resume(name, make_agent_callbacks(name, session, iter_cap))
            end
        else
            core.chat_send_player(name, "[LLM] No pending permission request.")
        end
        M.show(name)
        return true

    elseif fields.agent_deny and can_agent(name) then
        local agent = get_agent()
        local pending = agent and agent.resolve_permission and agent.resolve_permission(name, false)
        if pending then
            append_last_assistant_step(session, "✗", "Deny: " .. compact_line(pending.summary or pending.kind, 92), "#e07a7a")
            update_last_assistant_card(session, "Permission denied: " .. tostring(pending.summary or pending.kind or "agent action"), "Permission denied")
            local srv_max  = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
            local iter_cap = math.max(1, math.min(session.iter_preference or srv_max, srv_max))
            if agent.resume then
                agent.resume(name, make_agent_callbacks(name, session, iter_cap))
            end
        else
            core.chat_send_player(name, "[LLM] No pending permission request.")
        end
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

        local api = get_api()
        if not api.is_configured() then
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
