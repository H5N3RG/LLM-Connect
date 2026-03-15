-- ===========================================================================
--  main_gui.lua — LLM Connect 1.0
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  Main UI: chat interface + addon panel sub-formspec.
--  Replaces chat_gui.lua from 0.9.0.
--
--  Changes vs 0.9.0 chat_gui:
--    - WorldEdit mode buttons replaced by: Config | IDE | Addons
--    - Addons sub-formspec (llm_connect:main_addons) lists all registered
--      addons and lets the player toggle them per-session
--    - Agent mode: "send" dispatches through agent.lua when an addon is active
--    - basic_context replaces chat_context.lua (1.0 context provider)
--    - All references to we_agency, material_picker removed
--
--  Formspec names used:
--    llm_connect:main         — main chat window
--    llm_connect:main_addons  — addon panel (sub-formspec, same session)
--
--  PUBLIC API:
--    M.show(player_name)
--    M.show_addons(player_name)
--    M.handle_fields(player_name, formname, fields) → bool
--
-- ===========================================================================

local core = core
local M    = {}

-- ===========================================================================
-- Privilege helpers
-- llm_root implies llm + llm_dev + llm_agent
-- ===========================================================================

local function raw_priv(name, priv)
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

local function has_priv(name, priv)
    if raw_priv(name, "llm_root") then return true end
    return raw_priv(name, priv)
end

local function can_chat(name)   return has_priv(name, "llm") end
local function can_ide(name)    return has_priv(name, "llm_dev") end
local function can_agent(name)  return has_priv(name, "llm_agent") end
local function can_config(name) return raw_priv(name, "llm_root") end

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
            history        = {},  -- chat message history [{role, content}]
            last_input     = "",  -- preserved across show() calls
            iter_preference = nil, -- nil = use server default
        }
    end
    return sessions[name]
end

core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

-- ===========================================================================
-- History renderer
-- ===========================================================================

local function render_history(session)
    if #session.history == 0 then
        return "Welcome to LLM Connect!\nType your question below."
    end
    local lines = {}
    for _, msg in ipairs(session.history) do
        if msg.role ~= "system" then
            local prefix = msg.role == "user" and "You: " or "[LLM]: "
            table.insert(lines, prefix .. (msg.content or ""))
        end
    end
    return table.concat(lines, "\n\n")
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

    -- ── Header row 2: IDE | Addons | [iter stepper] ────────
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
        local addon_label = "⬡ Addons"
        if addon_count > 0 then
            addon_label = "⬡ Addons (" .. active_count .. "/" .. addon_count .. ")"
        end
        local addon_color = active_count > 0 and "#1a2a1a" or "#252525"
        table.insert(fs, "style[open_addons;bgcolor=" .. addon_color .. ";textcolor=#aaffaa]")
        table.insert(fs, "button[" .. bx .. ",0.95;3.6,0.65;open_addons;" .. addon_label .. "]")
        table.insert(fs, "tooltip[open_addons;Manage addons available to the agent]")
        bx = bx + 3.6 + 0.15

        -- ── Iteration stepper (right-aligned in row 2) ───────
        -- Shows as: [◀] N iter [▶]   e.g.  ◀ 4 iter ▶
        -- Player picks 1..server_max. nil = server default.
        local srv_max = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
        local iter    = session.iter_preference or srv_max
        -- Clamp in case server_max changed since last session
        iter = math.max(1, math.min(iter, srv_max))
        session.iter_preference = iter

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
    table.insert(fs, "textarea[" .. PAD .. "," .. history_y .. ";"
        .. (W - PAD*2) .. "," .. CHAT_H
        .. ";history_display;;" .. core.formspec_escape(render_history(session)) .. "]")
    table.insert(fs, "style[history_display;textcolor=#e0e0e0;bgcolor=#1a1a1a;border=false]")

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
-- M.show_addons — addon panel sub-formspec
--
-- Layout modelled after the sound tab of ide_asset_picker:
--   - Two-column list of registered addons
--   - Each row: toggle button (green=active / grey=off) + label + tool count
--   - Availability and privilege indicated inline
--   - Reset + Close buttons at bottom
-- ===========================================================================

function M.show_addons(name)
    local registry = get_registry()
    if not registry then
        core.chat_send_player(name, "[LLM] Addon registry not available")
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
    local ROW_H   = 1.1      -- taller rows: room for label + description
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
    table.insert(fs, string.format("label[%.2f,0.35;Addons — %s   (%d/%d active)]",
        PAD, core.formspec_escape(name), effective_n, total_n))
    table.insert(fs, "style[addons_close;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, string.format("button[%.2f,0.12;2.0,0.65;addons_close;✕ Close]",
        W - PAD - 2.0))

    local y = HDR_H + PAD

    -- ── Info row ─────────────────────────────────────────────
    table.insert(fs, string.format("label[%.2f,%.2f;Toggle addons for this session. Greyed = unavailable or missing privilege.]",
        PAD, y + 0.05))
    y = y + INFO_H

    -- ── Addon card grid ───────────────────────────────────────
    if total_n == 0 then
        table.insert(fs, string.format("label[%.2f,%.2f;No addons registered yet.]",
            PAD, y + 0.3))
    else
        for i, s in ipairs(status_list) do
            local col_idx = math.floor((i - 1) / rows_per_col)
            local row_idx = (i - 1) % rows_per_col
            local tx = PAD + col_idx * (col_w + col_gap)
            local ty = y   + row_idx * ROW_STEP

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
            local btn_name  = "addon_toggle_" .. s.id
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

            -- Label block: addon name + short description
            local lx = tx + 0.1 + toggle_w + 0.15
            local lw = col_w - 0.1 - toggle_w - 0.15 - 0.1

            -- Name line
            local name_color = (not s.available or not s.has_priv) and "#666666" or "#e0e0e0"
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                lx, ty + 0.22,
                core.colorize(name_color, core.formspec_escape(s.label))))

            -- Description line (truncated)
            local desc = s.description or ""
            if #desc > 48 then desc = desc:sub(1, 45) .. "…" end
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                lx, ty + 0.62,
                core.colorize("#888888", core.formspec_escape(desc))))

            -- Right-side badges: version + tool count + origin
            local origin_color = s.origin == "extern" and "#4a8844" or "#444488"
            local badges = core.colorize("#666666", "v" .. s.version)
                .. "  " .. core.colorize("#555566", s.tool_count .. " tools")
                .. "  " .. core.colorize(origin_color,
                    "[" .. (s.origin == "extern" and "ext" or "int") .. "]")
            -- warning badges
            if not s.available then
                badges = badges .. "  " .. core.colorize("#aa4422", "⚠ dep")
            end
            if not s.has_priv then
                badges = badges .. "  " .. core.colorize("#aa6622", "⚠ priv")
            end
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                lx, ty + 0.62,
                core.colorize("#888888", core.formspec_escape(desc))))
            -- Badges go on the right edge of the card
            table.insert(fs, string.format("label[%.2f,%.2f;%s]",
                tx + col_w - 0.08, ty + 0.22,
                badges))

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
-- Send: dispatch to agent or plain chat
-- ===========================================================================

local function do_send(name, input, session)
    local llm_api  = get_llm_api()
    local agent    = get_agent()
    local registry = get_registry()

    -- Decide: use agent if the player has llm_agent privilege.
    -- run_chat_command is always available as a built-in tool, so the agent
    -- loop is useful even with zero registered addons — the LLM can still
    -- dispatch any chat command the player is privileged to run.
    local use_agent = can_agent(name) and agent ~= nil

    if use_agent then
        -- Agent mode: stream step feedback into history
        local placeholder = "(agent running…)"
        table.insert(session.history, { role = "user",      content = input })
        table.insert(session.history, { role = "assistant", content = placeholder })
        M.show(name)

        local srv_max  = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
        local iter_cap = math.max(1, math.min(
            session.iter_preference or srv_max, srv_max))

        agent.run(name, input, { max_iterations = iter_cap }, {
            on_thought = function(thought)
                -- Replace placeholder with thought preview
                for i = #session.history, 1, -1 do
                    if session.history[i].content == placeholder
                    or session.history[i].content:match("^%💭") then
                        session.history[i].content = "💭 " .. thought
                        break
                    end
                end
                M.show(name)
            end,
            on_step = function(iter, plan, results)
                local lines = { "Step " .. iter .. ": " .. plan }
                for _, r in ipairs(results) do
                    if r.tool ~= "*" then
                        table.insert(lines,
                            "  " .. (r.ok and "✓" or "✗") .. " "
                            .. r.tool .. ": "
                            .. tostring(r.message):sub(1, 80))
                    end
                end
                -- Replace last assistant entry with running step log
                for i = #session.history, 1, -1 do
                    if session.history[i].role == "assistant" then
                        session.history[i].content = table.concat(lines, "\n")
                        break
                    end
                end
                M.show(name)
            end,
            on_done = function(result)
                local summary = agent.format_results(result)
                for i = #session.history, 1, -1 do
                    if session.history[i].role == "assistant" then
                        session.history[i].content = summary
                        break
                    end
                end
                M.show(name)
            end,
            on_error = function(err)
                for i = #session.history, 1, -1 do
                    if session.history[i].role == "assistant" then
                        session.history[i].content = "✗ Error: " .. tostring(err)
                        break
                    end
                end
                M.show(name)
            end,
        })

    else
        -- Plain chat mode: send history to LLM, append response
        local messages = {}
        local cfg = llm_api.config
        local max_h = cfg.context_max_history or 20

        -- Trim history to max
        local start = math.max(1, #session.history - max_h + 1)
        for i = start, #session.history do
            table.insert(messages, session.history[i])
        end

        table.insert(session.history, { role = "user", content = input })
        table.insert(messages,        { role = "user", content = input })

        -- Inject basic_context as system message if available
        local basic_ctx = _G.basic_context
        if basic_ctx and basic_ctx.get then
            local ctx = basic_ctx.get(name)
            if ctx and ctx ~= "" then
                table.insert(messages, 1, { role = "system", content = ctx })
            end
        end

        table.insert(session.history, { role = "assistant", content = "…" })
        M.show(name)

        llm_api.request(messages, function(result)
            -- Replace placeholder
            for i = #session.history, 1, -1 do
                if session.history[i].role == "assistant"
                and session.history[i].content == "…" then
                    if result.success then
                        session.history[i].content = result.content or "(no response)"
                    else
                        session.history[i].content = "✗ Error: " .. (result.error or "unknown")
                    end
                    break
                end
            end
            M.show(name)
        end, { timeout = llm_api.get_timeout("chat") })
    end
end

-- ===========================================================================
-- M.handle_fields
-- ===========================================================================

function M.handle_fields(name, formname, fields)
    -- ── Addon panel ──────────────────────────────────────────
    if formname:match("^llm_connect:main_addons") then
        local registry = get_registry()
        if not registry then return false end

        -- Toggle buttons: addon_toggle_<id>
        for field_name in pairs(fields) do
            local addon_id = field_name:match("^addon_toggle_(.+)$")
            if addon_id then
                local current = registry.is_addon_enabled(name, addon_id)
                registry.set_player_addon(name, addon_id, not current)
                M.show_addons(name)
                return true
            end
        end

        if fields.addons_reset then
            registry.reset_player_addons(name)
            M.show_addons(name)
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

    -- ── Iteration stepper buttons ────────────────────────────
    if fields.iter_dec then
        local srv_max = tonumber(core.settings:get("llm_agent_max_iterations")) or 8
        local cur = session.iter_preference or srv_max
        session.iter_preference = math.max(1, cur - 1)
        M.show(name); return true

    elseif fields.iter_inc then
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
            M.show_addons(name)
        end
        return true

    elseif fields.agent_cancel then
        local agent = get_agent()
        if agent then agent.cancel(name) end
        M.show(name)
        return true

    elseif fields.clear then
        session.history    = {}
        session.last_input = ""
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
