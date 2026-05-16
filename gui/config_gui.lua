-- ===========================================================================
--  config_gui.lua — LLM Connect 1.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  In-game configuration GUI (llm_root only).
--  Two-tab layout: API | Agent
--
--  PUBLIC API:
--    M.show(player_name, tab)   tab = "api" | "agent" (default "api")
--    M.handle_fields(player_name, formname, fields) → bool
--
-- ===========================================================================

local core = core
local M    = {}

-- ===========================================================================
-- Helpers
-- ===========================================================================

local function can_config(name)
    local root = _G.llm_connect
    local runtime = root and root.runtime
    if runtime and runtime.check_policy then
        return runtime.check_policy(name, "config")
    end
    local p = core.get_player_privs(name) or {}
    return p.llm_root == true
end

local function get_api()
    local root = _G.llm_connect
    local api = root and root.api
    if api then return api end
    return {
        __unavailable = true,
        reload_config = function() return false, "api subsystem unavailable" end,
        get_config = function() return {} end,
        set_config = function() return false, "api subsystem unavailable" end,
        request = function(_, cb)
            if type(cb) == "function" then cb({ success = false, error = "api subsystem unavailable" }) end
            return false, "api subsystem unavailable"
        end,
    }
end

-- Per-player active tab (survives re-show within a session)
local active_tab = {}

-- Per-root selected skill target in the Agent config tab.
local selected_skill_target = {}
local skill_field_ids = {}

local function list_skill_targets(viewer_name)
    local names = {}
    local seen = {}
    for _, player in ipairs(core.get_connected_players() or {}) do
        local n = player and player:get_player_name()
        if n and n ~= "" and not seen[n] then
            names[#names + 1] = n
            seen[n] = true
        end
    end
    if viewer_name and viewer_name ~= "" and not seen[viewer_name] then
        names[#names + 1] = viewer_name
        seen[viewer_name] = true
    end
    table.sort(names)
    return names
end

local function get_selected_skill_target(viewer_name)
    local selected = selected_skill_target[viewer_name]
    local seen = {}
    for _, n in ipairs(list_skill_targets(viewer_name)) do seen[n] = true end
    if selected and seen[selected] then return selected end
    return viewer_name
end

local function skill_field_name(id)
    local key = tostring(id or ""):gsub("[^%w_]", "_")
    return "skill_attach_" .. key
end

-- ===========================================================================
-- Layout constants (shared)
-- ===========================================================================

local W        = 16.0
local H        = 14.0
local PAD      = 0.3
local HEADER_H = 0.8
local TAB_H    = 0.75
local FIELD_H  = 0.8
local CB_H     = 0.55    -- checkbox row height
local SEP_H    = 0.25    -- section separator
local BTN_H    = 0.9
local HALF_W   = (W - PAD * 3) / 2
local THIRD_W  = (W - PAD * 2 - 0.2 * 2) / 3

local function tx(i) return PAD + i * (THIRD_W + 0.2) end

local function add_tooltip(fs, field_name, text)
    table.insert(fs, "tooltip[" .. tostring(field_name or "") .. ";" .. core.formspec_escape(tostring(text or "")) .. "]")
end

-- ===========================================================================
-- Section separator helper
-- ===========================================================================

local function sep(fs, y, label)
    -- Optional label sits above the line, consuming LABEL_H of vertical space.
    -- Caller always gets back a consistent y-advance regardless of label presence.
    local LABEL_H = 0.35
    if label then
        table.insert(fs, string.format("label[%.2f,%.2f;%s]", PAD, y,
            core.colorize("#888888", label)))
        y = y + LABEL_H
    end
    -- Separator line
    table.insert(fs, string.format("box[%.2f,%.2f;%.2f,0.02;#333333]", PAD, y, W - PAD * 2))
    return y + SEP_H   -- position after line
end

-- ===========================================================================
-- Tab bar
-- ===========================================================================

local function build_tabs(fs, current_tab)
    local tabs = {
        { id = "api",   label = "API & Model" },
        { id = "agent", label = "Agent" },
    }
    local tab_w = (W - PAD * 2) / #tabs
    local y = HEADER_H
    for i, t in ipairs(tabs) do
        local tx_pos = PAD + (i - 1) * tab_w
        local active = current_tab == t.id
        local bg = active and "#1a2a3a" or "#141414"
        local fg = active and "#aaddff" or "#666666"
        table.insert(fs, string.format("style[tab_%s;bgcolor=%s;textcolor=%s]",
            t.id, bg, fg))
        table.insert(fs, string.format("button[%.2f,%.2f;%.2f,%.2f;tab_%s;%s]",
            tx_pos, y, tab_w, TAB_H, t.id, t.label))
    end
    return HEADER_H + TAB_H
end

-- ===========================================================================
-- Bottom button bar (shared across tabs)
-- ===========================================================================

local function build_bottom_buttons(fs, y)
    local btn_count   = 4
    local btn_spacing = 0.2
    local btn_w       = (W - PAD * 2 - btn_spacing * (btn_count - 1)) / btn_count
    local function bx(i) return PAD + i * (btn_w + btn_spacing) end

    -- separator line above buttons
    table.insert(fs, string.format("box[0,%.2f;%.2f,0.02;#222222]", y, W))
    y = y + 0.15

    table.insert(fs, string.format(
        "button[%.2f,%.2f;%.2f,%.2f;save;✓ Save]",
        bx(0), y, btn_w, BTN_H))
    table.insert(fs, string.format(
        "button[%.2f,%.2f;%.2f,%.2f;reload;↺ Reload]",
        bx(1), y, btn_w, BTN_H))
    table.insert(fs, string.format(
        "button[%.2f,%.2f;%.2f,%.2f;test;⚡ Test API]",
        bx(2), y, btn_w, BTN_H))
    table.insert(fs, "style[close;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, string.format(
        "button[%.2f,%.2f;%.2f,%.2f;close;✕ Close]",
        bx(3), y, btn_w, BTN_H))
    y = y + BTN_H + PAD * 0.5
    table.insert(fs, string.format(
        "label[%.2f,%.2f;%s]", PAD, y,
        core.colorize("#555555",
            "Runtime changes only — edit minetest.conf for persistence.")))
end

-- ===========================================================================
-- Tab: API & Model
-- ===========================================================================

local function build_tab_api(fs, cfg)
    local y = PAD   -- scroll_container-local coords start at 0

    -- API Key
    table.insert(fs, string.format("label[%.2f,%.2f;API Key:]", PAD, y))
    y = y + 0.45
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;api_key;;%s]",
        PAD, y, W - PAD*2, FIELD_H,
        core.formspec_escape(cfg.api_key or "")))
    table.insert(fs, "style[api_key;bgcolor=#1e1e1e]")
    y = y + FIELD_H + PAD

    -- API URL
    table.insert(fs, string.format("label[%.2f,%.2f;API URL:]", PAD, y))
    y = y + 0.45
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;api_url;;%s]",
        PAD, y, W - PAD*2, FIELD_H,
        core.formspec_escape(cfg.api_url or "")))
    table.insert(fs, "style[api_url;bgcolor=#1e1e1e]")
    y = y + FIELD_H + PAD

    -- Model
    table.insert(fs, string.format("label[%.2f,%.2f;Model:]", PAD, y))
    y = y + 0.45
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;model;;%s]",
        PAD, y, W - PAD*2, FIELD_H,
        core.formspec_escape(cfg.model or "")))
    table.insert(fs, "style[model;bgcolor=#1e1e1e]")
    y = y + FIELD_H + PAD

    y = sep(fs, y, "Response parameters")

    -- Max Tokens + Temperature
    table.insert(fs, string.format("label[%.2f,%.2f;Max Tokens:]", PAD, y))
    table.insert(fs, string.format("label[%.2f,%.2f;Temperature (0–2):]", W/2 + PAD, y))
    y = y + 0.45
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;max_tokens;;%s]",
        PAD, y, HALF_W, FIELD_H, tostring(cfg.max_tokens or 4000)))
    table.insert(fs, "style[max_tokens;bgcolor=#1e1e1e]")
    add_tooltip(fs, "max_tokens", "Response length limit (500-16384)")
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;temperature;;%s]",
        W/2 + PAD, y, HALF_W, FIELD_H, tostring(cfg.temperature or 0.7)))
    table.insert(fs, "style[temperature;bgcolor=#1e1e1e]")
    add_tooltip(fs, "temperature", "0 = deterministic, 1 = balanced, 2 = creative")
    y = y + FIELD_H + PAD

    y = sep(fs, y, "Chat behaviour")

    table.insert(fs, string.format("label[%.2f,%.2f;Chat system prompt (optional, empty = none):]", PAD, y))
    y = y + 0.45
    local chat_sys = core.settings:get("llm_chat_system_prompt") or ""
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;chat_system_prompt;;%s]",
        PAD, y, W - PAD*2, FIELD_H,
        core.formspec_escape(chat_sys)))
    table.insert(fs, "style[chat_system_prompt;bgcolor=#1e1e1e]")
    add_tooltip(fs, "chat_system_prompt", "Prepended as system message in plain chat, not agent mode. Basic context is added separately.")
    y = y + FIELD_H + PAD

    y = sep(fs, y, "Debug / trace")

    local trace_enabled = core.settings:get_bool("llm_trace_prompt_log", false)
    table.insert(fs, string.format("checkbox[%.2f,%.2f;trace_prompt_log;%s;%s]",
        PAD, y,
        core.formspec_escape("Trace raw LLM request/response payloads to world files"),
        trace_enabled and "true" or "false"))
    add_tooltip(fs, "trace_prompt_log", "Writes raw request/response payloads to world log files. Very verbose; keep disabled on public servers.")
    y = y + CB_H + PAD

    y = sep(fs, y, "Timeouts")

    -- Global timeout
    table.insert(fs, string.format("label[%.2f,%.2f;Global timeout (seconds, 30–600):]", PAD, y))
    y = y + 0.45
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;timeout;;%s]",
        PAD, y, HALF_W, FIELD_H, tostring(cfg.timeout or 120)))
    table.insert(fs, "style[timeout;bgcolor=#1e1e1e]")
    add_tooltip(fs, "timeout", "Fallback for all modes. Per-mode overrides below take precedence when greater than 0.")
    y = y + FIELD_H + PAD

    -- Per-mode timeout overrides
    table.insert(fs, string.format("label[%.2f,%.2f;Per-mode overrides (0 = use global):]", PAD, y))
    y = y + 0.45
    table.insert(fs, string.format("label[%.2f,%.2f;Chat:]",  tx(0), y))
    table.insert(fs, string.format("label[%.2f,%.2f;IDE:]",   tx(1), y))
    table.insert(fs, string.format("label[%.2f,%.2f;Agent:]", tx(2), y))
    y = y + 0.4
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;timeout_chat;;%s]",
        tx(0), y, THIRD_W, FIELD_H, tostring(cfg.timeout_chat or 0)))
    table.insert(fs, "style[timeout_chat;bgcolor=#1e1e1e]")
    add_tooltip(fs, "timeout_chat", "0 = global")
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;timeout_ide;;%s]",
        tx(1), y, THIRD_W, FIELD_H, tostring(cfg.timeout_ide or 0)))
    table.insert(fs, "style[timeout_ide;bgcolor=#1e1e1e]")
    add_tooltip(fs, "timeout_ide", "0 = global")
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;timeout_agent;;%s]",
        tx(2), y, THIRD_W, FIELD_H, tostring(cfg.timeout_agent or 0)))
    table.insert(fs, "style[timeout_agent;bgcolor=#1e1e1e]")
    add_tooltip(fs, "timeout_agent", "Agent loops often need more time. Set higher than global if needed.")
    y = y + FIELD_H + PAD

    return y
end

-- ===========================================================================
-- Tab: Agent
-- ===========================================================================

local function build_tab_agent(fs, name)
    local y = PAD   -- scroll_container-local coords start at 0

    -- ── Master switch ────────────────────────────────────────
    local agent_enabled = core.settings:get_bool("llm_agent_enabled", true)
    local agent_bg  = agent_enabled and "#0d1a0d" or "#1a0d0d"
    local agent_lbl = agent_enabled
        and core.colorize("#aaffaa", "Agent is ENABLED — players with llm_agent priv can use it")
        or  core.colorize("#ffaaaa", "Agent is DISABLED — no agent actions will be executed")
    table.insert(fs, string.format("box[%.2f,%.2f;%.2f,%.2f;%s]",
        PAD, y, W - PAD * 2, 0.75, agent_bg))
    table.insert(fs, string.format("checkbox[%.2f,%.2f;agent_enabled;%s;%s]",
        PAD + 0.15, y + 0.18,
        agent_lbl,
        agent_enabled and "true" or "false"))
    add_tooltip(fs, "agent_enabled", "Master switch. When disabled, all agent runs are blocked regardless of privilege.")
    y = y + 0.75 + PAD

    y = sep(fs, y, "Loop control")

    -- Max iterations
    table.insert(fs, string.format("label[%.2f,%.2f;Max iterations per run (1–32):]", PAD, y))
    y = y + 0.45
    local max_iter = tostring(tonumber(core.settings:get("llm_agent_max_iterations")) or 8)
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;agent_max_iter;;%s]",
        PAD, y, HALF_W, FIELD_H, max_iter))
    table.insert(fs, "style[agent_max_iter;bgcolor=#1e1e1e]")
    add_tooltip(fs, "agent_max_iter", "The agent stops after this many LLM calls even if done=false. Safety cap.")
    y = y + FIELD_H + PAD

    y = sep(fs, y, "Live trace")

    local live_trace = core.settings:get_bool("llm_live_trace_chat", false)
    local live_trace_lua = core.settings:get_bool("llm_live_trace_show_lua", false)
    local live_trace_verbosity = core.settings:get("llm_live_trace_verbosity") or "normal"
    local live_trace_categories = core.settings:get("llm_live_trace_categories") or "all"
    table.insert(fs, string.format("checkbox[%.2f,%.2f;live_trace_chat;%s;%s]",
        PAD, y,
        core.formspec_escape("Stream LLM Connect engine trace to root chat"),
        live_trace and "true" or "false"))
    add_tooltip(fs, "live_trace_chat", "Root-only live stream of LLM Connect trace events into in-game chat.")
    y = y + CB_H
    table.insert(fs, string.format("checkbox[%.2f,%.2f;live_trace_show_lua;%s;%s]",
        PAD, y,
        core.formspec_escape("Include raw lua_action code in live trace"),
        live_trace_lua and "true" or "false"))
    add_tooltip(fs, "live_trace_show_lua", "Very noisy. Shows compacted raw lua_action code in chat.")
    y = y + CB_H + 0.15
    table.insert(fs, string.format("label[%.2f,%.2f;Trace verbosity:]", PAD, y))
    table.insert(fs, string.format("label[%.2f,%.2f;Categories:]", PAD + HALF_W + 0.25, y))
    y = y + 0.42
    local verbosity_items = {"quiet", "normal", "verbose"}
    local verbosity_idx = 2
    for i, v in ipairs(verbosity_items) do
        if v == live_trace_verbosity then verbosity_idx = i end
    end
    table.insert(fs, string.format(
        "dropdown[%.2f,%.2f;%.2f,%.2f;live_trace_verbosity;%s;%d;false]",
        PAD, y, HALF_W, FIELD_H, table.concat(verbosity_items, ","), verbosity_idx))
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;live_trace_categories;;%s]",
        PAD + HALF_W + 0.25, y, HALF_W - 0.25, FIELD_H,
        core.formspec_escape(live_trace_categories)))
    add_tooltip(fs, "live_trace_categories", "Comma-separated categories or all.")
    y = y + FIELD_H + 0.2
    table.insert(fs, string.format("button[%.2f,%.2f;%.2f,%.2f;show_trace_panel;Open trace panel]",
        PAD, y, HALF_W, FIELD_H))
    table.insert(fs, string.format("button[%.2f,%.2f;%.2f,%.2f;clear_trace_buffer;Clear trace buffer]",
        PAD + HALF_W + 0.25, y, HALF_W - 0.25, FIELD_H))
    y = y + FIELD_H + PAD

    y = sep(fs, y, "Root override")

    local root_unrestricted = core.settings:get_bool("llm_root_agent_unrestricted", false)
    local root_bypass = core.settings:get_bool("llm_root_bypass_safety_filters", false)
    local root_startup = core.settings:get_bool("llm_root_allow_startup_execution", false)
    table.insert(fs, string.format("checkbox[%.2f,%.2f;root_agent_unrestricted;%s;%s]",
        PAD, y,
        core.formspec_escape("llm_root agent runs unrestricted (no sandbox)"),
        root_unrestricted and "true" or "false"))
    add_tooltip(fs, "root_agent_unrestricted", "Root-only opt-in. Runs llm_root agent actions without the normal sandbox.")
    y = y + CB_H
    table.insert(fs, string.format("checkbox[%.2f,%.2f;root_bypass_safety_filters;%s;%s]",
        PAD, y,
        core.formspec_escape("llm_root bypasses Lua precheck host-access filters"),
        root_bypass and "true" or "false"))
    add_tooltip(fs, "root_bypass_safety_filters", "Root-only opt-in. Disables forbidden-pattern precheck blocking for llm_root executions.")
    y = y + CB_H
    table.insert(fs, string.format("checkbox[%.2f,%.2f;root_allow_startup_execution;%s;%s]",
        PAD, y,
        core.formspec_escape("llm_root may execute startup-preferred code transiently"),
        root_startup and "true" or "false"))
    add_tooltip(fs, "root_allow_startup_execution", "Root-only experimental path for owner debugging.")
    y = y + CB_H + PAD

    y = sep(fs, y, "Root skill attachment")

    local skills = _G.llm_connect and (_G.llm_connect.skills or _G.llm_connect.skills_subsystem)
    local targets = list_skill_targets(name)
    local target = get_selected_skill_target(name)
    local selected_idx = 1
    for i, n in ipairs(targets) do
        if n == target then selected_idx = i; break end
    end
    if #targets == 0 then
        targets = { name }
        selected_idx = 1
        target = name
    end
    table.insert(fs, string.format("label[%.2f,%.2f;Target player:]", PAD, y))
    y = y + 0.42
    local escaped_targets = {}
    for _, n in ipairs(targets) do escaped_targets[#escaped_targets + 1] = core.formspec_escape(n) end
    table.insert(fs, string.format(
        "dropdown[%.2f,%.2f;%.2f,%.2f;agent_skill_target;%s;%d;true]",
        PAD, y, HALF_W, FIELD_H, table.concat(escaped_targets, ","), selected_idx))
    add_tooltip(fs, "agent_skill_target", "Root selects which player's agent session receives attached skills. Runtime only.")
    table.insert(fs, string.format("button[%.2f,%.2f;%.2f,%.2f;apply_skill_attach;Apply skill attachments]",
        PAD + HALF_W + 0.25, y, HALF_W - 0.25, FIELD_H))
    y = y + FIELD_H + 0.2

    table.insert(fs, string.format("label[%.2f,%.2f;%s]", PAD, y,
        core.colorize("#888888", "Manual root attachments override per-skill privilege gates for the selected player's agent session.")))
    y = y + 0.45

    skill_field_ids[name] = {}
    local status_list = {}
    if skills and skills.get_status then
        status_list = skills.get_status(target) or {}
    end
    if #status_list == 0 then
        table.insert(fs, string.format("label[%.2f,%.2f;No skills registered.]", PAD, y))
        y = y + 0.55
    else
        for _, s in ipairs(status_list) do
            local sid = tostring(s.id or "")
            local field = skill_field_name(sid)
            skill_field_ids[name][field] = sid
            local attached = s.enabled == true or s.attached == true
            local effective = s.effective == true
            local label = string.format("%s  [%s]", tostring(s.label or sid), effective and "attached" or "detached")
            table.insert(fs, string.format("checkbox[%.2f,%.2f;%s;%s;%s]",
                PAD, y, field, core.formspec_escape(label), attached and "true" or "false"))
            local meta = "id=" .. sid .. " | required_priv=" .. tostring(s.required_priv or "llm_agent")
            if s.manual_attached then meta = meta .. " | root override" end
            if not s.has_priv and not s.manual_attached then meta = meta .. " | target lacks priv" end
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                PAD + 6.2, y + 0.02, core.colorize("#777777", core.formspec_escape(meta))))
            y = y + CB_H
        end
    end
    table.insert(fs, string.format("button[%.2f,%.2f;%.2f,%.2f;reset_skill_attach;Reset selected player's attachments]",
        PAD, y, HALF_W, FIELD_H))
    add_tooltip(fs, "reset_skill_attach", "Clears explicit attachments for the selected player so defaults apply again.")
    y = y + FIELD_H + PAD

    -- Status info box
    local addon_count = 0
    if skills and skills.get_status then
        addon_count = #(skills.get_status(target or name) or {})
    end
    local agent_obj = _G.llm_connect and _G.llm_connect.agent
    local status_color = agent_enabled and "#0d1a0d" or "#1a1010"
    local status_lines = {
        "Registered Lua skills: " .. addon_count,
        "Agent module: " .. (agent_obj and "loaded" or "NOT LOADED"),
        "llm_agent_enabled: " .. tostring(agent_enabled),
    }
    table.insert(fs, string.format("box[%.2f,%.2f;%.2f,%.2f;%s]",
        PAD, y, W - PAD * 2, 1.2, status_color))
    for i, line in ipairs(status_lines) do
        table.insert(fs, string.format("label[%.2f,%.2f;%s]",
            PAD + 0.2, y + 0.1 + (i-1) * 0.38,
            core.colorize("#888888", line)))
    end
    y = y + 1.2 + PAD

    return y
end

-- ===========================================================================
-- M.show
-- ===========================================================================

function M.show(name, tab)
    if not can_config(name) then
        core.chat_send_player(name, "Missing privilege: llm_root")
        return
    end

    tab = tab or active_tab[name] or "api"
    active_tab[name] = tab

    local api = get_api()
    local cfg     = api.get_config()

    local fs = {
        "formspec_version[6]",
        string.format("size[%.2f,%.2f]", W, H),
        "bgcolor[#0f0f0f;both]",
        "style_type[*;bgcolor=#1a1a1a;textcolor=#e0e0e0;font=mono]",
    }

    -- Header
    table.insert(fs, string.format("box[0,0;%.2f,%.2f;#202020]", W, HEADER_H))
    table.insert(fs, string.format("label[%.2f,%.2f;LLM Connect — Configuration]",
        PAD, HEADER_H/2 - 0.2))
    table.insert(fs, string.format("label[%.2f,%.2f;%s]",
        W - 3.5, HEADER_H/2 - 0.2,
        core.colorize("#555555", "llm_root only  " .. os.date("%H:%M"))))

    -- Tab bar
    build_tabs(fs, tab)

    -- Scrollable area
    local container_y = HEADER_H + TAB_H
    local btn_y = H - BTN_H - PAD * 2 - 0.4
    local scroll_area_height = btn_y - container_y - PAD * 0.5
    local inner_width = W - PAD * 2 - 0.3 - 0.1  -- SCROLLBAR_WIDTH 0.3, SPACING 0.1
    local inner_height = scroll_area_height

    -- Scroll container
    table.insert(fs, string.format("scroll_container[%.2f,%.2f;%.2f,%.2f;llm_cfg_scroll;vertical;0.1;0.2]",
        PAD, container_y, inner_width, inner_height))

    -- Tab content
    local content_bottom
    if tab == "api" then
        content_bottom = build_tab_api(fs, cfg)
    elseif tab == "agent" then
        content_bottom = build_tab_agent(fs, name)
    end

    table.insert(fs, "scroll_container_end[]")

    -- Scrollbar
    table.insert(fs, string.format("scrollbar[%.2f,%.2f;%.2f,%.2f;vertical;llm_cfg_scroll;0]",
        PAD + inner_width + 0.1, container_y, 0.3, inner_height))

    -- Bottom buttons (fixed at bottom of formspec)
    build_bottom_buttons(fs, btn_y)

    core.show_formspec(name, "llm_connect:config", table.concat(fs))
end

-- ===========================================================================
-- M.handle_fields
-- ===========================================================================

function M.handle_fields(name, formname, fields)
    if not formname:match("^llm_connect:config") then return false end
    if not can_config(name) then return true end

    local api = get_api()
    local tab     = active_tab[name] or "api"

    -- ── Tab switches ─────────────────────────────────────────
    if fields.tab_api then
        M.show(name, "api"); return true
    elseif fields.tab_agent then
        M.show(name, "agent"); return true
    end

    -- ── Agent toggle (instant — no Save needed) ───────────────
    if fields.agent_enabled ~= nil then
        local val = fields.agent_enabled == "true"
        core.settings:set_bool("llm_agent_enabled", val)
        core.log("action", string.format(
            "[llm_connect] agent_enabled set to %s by %s", tostring(val), name))
        M.show(name, "agent")
        return true
    end

    -- ── Agent-tab skill target / attachment controls ──────────
    if tab == "agent" and fields.agent_skill_target then
        local raw_idx = tostring(fields.agent_skill_target or "")
        local idx = tonumber(raw_idx:match("(%d+)$"))
        local targets = list_skill_targets(name)
        if idx and targets[idx] then
            selected_skill_target[name] = targets[idx]
            M.show(name, "agent")
            return true
        end
    end

    if tab == "agent" and fields.apply_skill_attach then
        local skills = _G.llm_connect and (_G.llm_connect.skills or _G.llm_connect.skills_subsystem)
        local target = get_selected_skill_target(name)
        if not skills or not skills.set_enabled then
            core.chat_send_player(name, "[LLM] Skill subsystem unavailable")
            return true
        end
        local map = skill_field_ids[name] or {}
        local changed = 0
        for field, sid in pairs(map) do
            if fields[field] ~= nil then
                local ok, err = skills.set_enabled(target, sid, fields[field] == "true")
                if ok then changed = changed + 1 else core.chat_send_player(name, "[LLM] Skill attach failed: " .. tostring(err)) end
            end
        end
        core.chat_send_player(name, "[LLM] ✓ Applied " .. changed .. " skill attachment setting(s) for " .. target)
        M.show(name, "agent")
        return true
    end

    if tab == "agent" and fields.reset_skill_attach then
        local skills = _G.llm_connect and (_G.llm_connect.skills or _G.llm_connect.skills_subsystem)
        local target = get_selected_skill_target(name)
        if skills and skills.reset_player then
            skills.reset_player(target)
            core.chat_send_player(name, "[LLM] ✓ Reset skill attachments for " .. target)
        end
        M.show(name, "agent")
        return true
    end

    -- ── Save ─────────────────────────────────────────────────
    if fields.save then
        if tab == "api" then
            -- Validate API tab fields
            local max_tokens  = tonumber(fields.max_tokens)
            local temperature = tonumber(fields.temperature)
            local timeout     = tonumber(fields.timeout)

            if not max_tokens or max_tokens < 1 or max_tokens > 100000 then
                core.chat_send_player(name, "[LLM] Error: max_tokens must be 1–100000")
                return true
            end
            if not temperature or temperature < 0 or temperature > 2 then
                core.chat_send_player(name, "[LLM] Error: temperature must be 0–2")
                return true
            end
            if not timeout or timeout < 30 or timeout > 600 then
                core.chat_send_player(name, "[LLM] Error: timeout must be 30–600 seconds")
                return true
            end

            local timeout_chat  = tonumber(fields.timeout_chat)  or 0
            local timeout_ide   = tonumber(fields.timeout_ide)   or 0
            local timeout_agent = tonumber(fields.timeout_agent) or 0

            for _, t in ipairs({ timeout_chat, timeout_ide, timeout_agent }) do
                if t ~= 0 and (t < 30 or t > 600) then
                    core.chat_send_player(name, "[LLM] Error: per-mode timeouts must be 0 or 30–600")
                    return true
                end
            end

            api.set_config({
                api_key       = fields.api_key or "",
                api_url       = fields.api_url or "",
                model         = fields.model   or "",
                max_tokens    = max_tokens,
                temperature   = temperature,
                timeout       = timeout,
                timeout_chat  = timeout_chat,
                timeout_ide   = timeout_ide,
                timeout_agent = timeout_agent,
            })

            -- Chat system prompt and trace toggle are saved directly to settings.
            local csp = (fields.chat_system_prompt or ""):match("^%s*(.-)%s*$")
            core.settings:set("llm_chat_system_prompt", csp)
            if fields.trace_prompt_log ~= nil then
                core.settings:set_bool("llm_trace_prompt_log", fields.trace_prompt_log == "true")
            end

            core.chat_send_player(name, "[LLM] ✓ API configuration saved (runtime only)")
            core.log("action", "[llm_connect] API config updated by " .. name)

        elseif tab == "agent" then
            -- Validate Agent tab fields
            local max_iter = tonumber(fields.agent_max_iter)
            if not max_iter or max_iter < 1 or max_iter > 32 then
                core.chat_send_player(name, "[LLM] Error: max iterations must be 1–32")
                return true
            end

            core.settings:set("llm_agent_max_iterations",
                tostring(math.floor(max_iter)))
            if fields.root_agent_unrestricted ~= nil then
                core.settings:set_bool("llm_root_agent_unrestricted", fields.root_agent_unrestricted == "true")
            end
            if fields.root_bypass_safety_filters ~= nil then
                core.settings:set_bool("llm_root_bypass_safety_filters", fields.root_bypass_safety_filters == "true")
            end
            if fields.root_allow_startup_execution ~= nil then
                core.settings:set_bool("llm_root_allow_startup_execution", fields.root_allow_startup_execution == "true")
            end
            if fields.live_trace_chat ~= nil then
                core.settings:set_bool("llm_live_trace_chat", fields.live_trace_chat == "true")
            end
            if fields.live_trace_show_lua ~= nil then
                core.settings:set_bool("llm_live_trace_show_lua", fields.live_trace_show_lua == "true")
            end
            if fields.live_trace_verbosity and fields.live_trace_verbosity ~= "" then
                core.settings:set("llm_live_trace_verbosity", fields.live_trace_verbosity)
            end
            if fields.live_trace_categories ~= nil then
                core.settings:set("llm_live_trace_categories", fields.live_trace_categories)
            end
            core.chat_send_player(name, "[LLM] ✓ Agent configuration saved (runtime only)")
            core.log("action", "[llm_connect] agent config updated by " .. name)
        end

        M.show(name, tab)
        return true

    -- ── Reload ───────────────────────────────────────────────
    elseif fields.reload then
        api.reload_config()
        core.chat_send_player(name, "[LLM] ✓ Configuration reloaded from minetest.conf")
        core.log("action", "[llm_connect] config reloaded by " .. name)
        M.show(name, tab)
        return true

    elseif tab == "agent" and fields.clear_trace_buffer then
        local trace = _G.llm_connect and _G.llm_connect.live_trace
        if trace and trace.clear then
            trace.clear()
            core.chat_send_player(name, "[LLM] ✓ Live trace buffer cleared")
        else
            core.chat_send_player(name, "[LLM] Live trace unavailable")
        end
        M.show(name, "agent")
        return true

    elseif tab == "agent" and fields.show_trace_panel then
        local trace = _G.llm_connect and _G.llm_connect.live_trace
        if trace and trace.show_formspec then
            trace.show_formspec(name)
        else
            core.chat_send_player(name, "[LLM] Live trace unavailable")
        end
        return true

    -- ── Test connection ──────────────────────────────────────
    elseif fields.test then
        core.chat_send_player(name, "[LLM] Testing connection…")
        api.request(
            {{ role = "user",
               content = "Reply with exactly: OK (Luanti LLM Connect test)" }},
            function(result)
                if result.success then
                    core.chat_send_player(name,
                        "[LLM] ✓ Connection OK — " .. (result.content or "no content"))
                else
                    core.chat_send_player(name,
                        "[LLM] ✗ Connection failed — " .. (result.error or "unknown error"))
                end
            end,
            { timeout = 30 }
        )
        return true

    -- ── Close ────────────────────────────────────────────────
    elseif fields.close or fields.quit then
        active_tab[name] = nil
        local gui = _G.llm_connect and _G.llm_connect.gui
        if gui and gui.show then
            gui.show(name, "main")
        elseif _G.main_gui and _G.main_gui.show then
            _G.main_gui.show(name)
        else
            core.close_formspec(name, "llm_connect:config")
        end
        return true
    end

    return true
end

-- ===========================================================================

core.log("action", "[config_gui] module loaded")

return M
