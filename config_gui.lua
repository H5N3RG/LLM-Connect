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

local function has_priv(name, priv)
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

local function get_llm_api()
    if not _G.llm_api then error("[config_gui] llm_api not available") end
    return _G.llm_api
end

-- Per-player active tab (survives re-show within a session)
local active_tab = {}

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

-- ===========================================================================
-- Section separator helper
-- ===========================================================================

local function sep(fs, y, label)
    table.insert(fs, string.format("box[%.2f,%.2f;%.2f,0.02;#333333]",
        PAD, y, W - PAD * 2))
    if label then
        table.insert(fs, string.format("label[%.2f,%.2f;%s]",
            PAD, y - 0.02,
            core.colorize("#888888", label)))
    end
    return y + SEP_H
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
    local y = HEADER_H + TAB_H + PAD

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
    y = y + 0.2

    -- Max Tokens + Temperature
    table.insert(fs, string.format("label[%.2f,%.2f;Max Tokens:]", PAD, y))
    table.insert(fs, string.format("label[%.2f,%.2f;Temperature (0–2):]", W/2 + PAD, y))
    y = y + 0.45
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;max_tokens;;%s]",
        PAD, y, HALF_W, FIELD_H, tostring(cfg.max_tokens or 4000)))
    table.insert(fs, "style[max_tokens;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[max_tokens;Response length limit (500–16384)]")
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;temperature;;%s]",
        W/2 + PAD, y, HALF_W, FIELD_H, tostring(cfg.temperature or 0.7)))
    table.insert(fs, "style[temperature;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[temperature;0 = deterministic, 1 = balanced, 2 = creative]")
    y = y + FIELD_H + PAD

    y = sep(fs, y, "Chat behaviour")
    y = y + 0.2

    table.insert(fs, string.format("label[%.2f,%.2f;Chat system prompt (optional, empty = none):]", PAD, y))
    y = y + 0.45
    local chat_sys = core.settings:get("llm_chat_system_prompt") or ""
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;chat_system_prompt;;%s]",
        PAD, y, W - PAD*2, FIELD_H,
        core.formspec_escape(chat_sys)))
    table.insert(fs, "style[chat_system_prompt;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[chat_system_prompt;Prepended as system message in plain chat (not agent mode). Basic context is always added separately. Example: You are a friendly Luanti helper. Be concise.]")
    y = y + FIELD_H + PAD

    y = sep(fs, y, "Timeouts")
    y = y + 0.2

    -- Global timeout
    table.insert(fs, string.format("label[%.2f,%.2f;Global timeout (seconds, 30–600):]", PAD, y))
    y = y + 0.45
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;timeout;;%s]",
        PAD, y, HALF_W, FIELD_H, tostring(cfg.timeout or 120)))
    table.insert(fs, "style[timeout;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[timeout;Fallback for all modes. Per-mode overrides below take precedence when > 0.]")
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
    table.insert(fs, "tooltip[timeout_chat;0 = global]")
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;timeout_ide;;%s]",
        tx(1), y, THIRD_W, FIELD_H, tostring(cfg.timeout_ide or 0)))
    table.insert(fs, "style[timeout_ide;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[timeout_ide;0 = global]")
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;timeout_agent;;%s]",
        tx(2), y, THIRD_W, FIELD_H, tostring(cfg.timeout_agent or 0)))
    table.insert(fs, "style[timeout_agent;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[timeout_agent;Agent loops often need more time — set higher than global if needed]")
    y = y + FIELD_H + PAD

    return y
end

-- ===========================================================================
-- Tab: Agent
-- ===========================================================================

local function build_tab_agent(fs)
    local y = HEADER_H + TAB_H + PAD

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
    table.insert(fs, "tooltip[agent_enabled;Master switch. When disabled, all agent runs are blocked regardless of privilege.]")
    y = y + 0.75 + PAD

    y = sep(fs, y, "Loop control")
    y = y + 0.2

    -- Max iterations + Snapshot
    table.insert(fs, string.format("label[%.2f,%.2f;Max iterations per run (1–32):]", PAD, y))
    y = y + 0.45
    local max_iter = tostring(tonumber(core.settings:get("llm_agent_max_iterations")) or 8)
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;agent_max_iter;;%s]",
        PAD, y, HALF_W, FIELD_H, max_iter))
    table.insert(fs, "style[agent_max_iter;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[agent_max_iter;The agent stops after this many LLM calls even if done=false. Safety cap.]")
    y = y + FIELD_H + PAD

    local snapshot_on = core.settings:get_bool("llm_agent_snapshot", true)
    table.insert(fs, string.format("checkbox[%.2f,%.2f;agent_snapshot;Take world snapshot before each run (enables Undo);%s]",
        PAD, y, snapshot_on and "true" or "false"))
    table.insert(fs, "tooltip[agent_snapshot;Saves the affected region before the agent acts. Required for agent-level Undo to work.]")
    y = y + CB_H + PAD

    y = sep(fs, y, "Security")
    y = y + 0.2

    -- Command whitelist
    table.insert(fs, string.format("label[%.2f,%.2f;Command whitelist for run_chat_command (empty = all allowed):]", PAD, y))
    y = y + 0.45
    local whitelist = core.settings:get("llm_agent_command_whitelist") or ""
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;agent_cmd_whitelist;;%s]",
        PAD, y, W - PAD*2, FIELD_H,
        core.formspec_escape(whitelist)))
    table.insert(fs, "style[agent_cmd_whitelist;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[agent_cmd_whitelist;Comma-separated command names the agent may call. Example: teleport,give,time\nLeave empty to allow any command the player is already privileged to run.\nRecommended: restrict on public servers.]")
    y = y + FIELD_H + PAD

    y = sep(fs, y, "Addon defaults")
    y = y + 0.2

    local addons_default_on = core.settings:get_bool("llm_agent_addons_default_on", false)
    table.insert(fs, string.format(
        "checkbox[%.2f,%.2f;agent_addons_default_on;Addons active by default (players can still override per-session);%s]",
        PAD, y, addons_default_on and "true" or "false"))
    table.insert(fs, "tooltip[agent_addons_default_on;When off (default), players must explicitly enable addons in the Addons panel. When on, all addons are active unless the player disables them.]")
    y = y + CB_H + PAD * 0.5
    table.insert(fs, string.format("label[%.2f,%.2f;Addon IDs enabled by default (empty = all):]", PAD, y))
    y = y + 0.45
    local addons_enabled = core.settings:get("llm_agent_addons_enabled") or ""
    table.insert(fs, string.format(
        "field[%.2f,%.2f;%.2f,%.2f;agent_addons_enabled;;%s]",
        PAD, y, W - PAD*2, FIELD_H,
        core.formspec_escape(addons_enabled)))
    table.insert(fs, "style[agent_addons_enabled;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[agent_addons_enabled;Comma-separated addon IDs. Example: worldedit_agent,mobs_redo\nLeave empty to enable all registered addons by default.\nPer-player overrides set in the Addons panel always take precedence.]")
    y = y + FIELD_H + PAD

    -- Status info box
    local registry = _G.llm_connect and _G.llm_connect.registry
    local addon_count = 0
    if registry then
        for _ in pairs(registry.addons) do addon_count = addon_count + 1 end
    end
    local agent_obj = _G.llm_connect and _G.llm_connect.agent
    local status_color = agent_enabled and "#0d1a0d" or "#1a1010"
    local status_lines = {
        "Registered addons: " .. addon_count,
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
    if not has_priv(name, "llm_root") then
        core.chat_send_player(name, "Missing privilege: llm_root")
        return
    end

    tab = tab or active_tab[name] or "api"
    active_tab[name] = tab

    local llm_api = get_llm_api()
    local cfg     = llm_api.config

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
        content_bottom = build_tab_agent(fs)
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
    if not has_priv(name, "llm_root") then return true end

    local llm_api = get_llm_api()
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

    -- ── Agent addons default toggle (instant) ────────────────
    if fields.agent_addons_default_on ~= nil then
        local val = fields.agent_addons_default_on == "true"
        core.settings:set_bool("llm_agent_addons_default_on", val)
        M.show(name, "agent")
        return true
    end

    -- ── Agent snapshot toggle (instant) ──────────────────────
    if fields.agent_snapshot ~= nil then
        local val = fields.agent_snapshot == "true"
        core.settings:set_bool("llm_agent_snapshot", val)
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

            llm_api.set_config({
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

            -- Chat system prompt saved directly to settings (not in llm_api.config)
            local csp = (fields.chat_system_prompt or ""):match("^%s*(.-)%s*$")
            core.settings:set("llm_chat_system_prompt", csp)

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
            core.settings:set("llm_agent_command_whitelist",
                (fields.agent_cmd_whitelist or ""):match("^%s*(.-)%s*$"))
            core.settings:set("llm_agent_addons_enabled",
                (fields.agent_addons_enabled or ""):match("^%s*(.-)%s*$"))

            core.chat_send_player(name, "[LLM] ✓ Agent configuration saved (runtime only)")
            core.log("action", "[llm_connect] agent config updated by " .. name)
        end

        M.show(name, tab)
        return true

    -- ── Reload ───────────────────────────────────────────────
    elseif fields.reload then
        llm_api.reload_config()
        core.chat_send_player(name, "[LLM] ✓ Configuration reloaded from minetest.conf")
        core.log("action", "[llm_connect] config reloaded by " .. name)
        M.show(name, tab)
        return true

    -- ── Test connection ──────────────────────────────────────
    elseif fields.test then
        core.chat_send_player(name, "[LLM] Testing connection…")
        llm_api.request(
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
        if _G.main_gui then
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
