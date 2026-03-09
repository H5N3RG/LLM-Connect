-- chat_gui.lua
-- LLM Chat Interface v0.8.7
-- Privilege model:
--   llm          → Chat only
--   llm_dev      → + IDE button
--   llm_worldedit → + WE Single/Loop + Mats + Undo
--   llm_root     → Superrole: implies all of the above + Config button

local core = core
local M = {}

local mod_path = core.get_modpath("llm_connect")

local context_ok, chat_context = pcall(dofile, mod_path .. "/chat_context.lua")
if not context_ok then
    core.log("error", "[chat_gui] Failed to load chat_context.lua: " .. tostring(chat_context))
    chat_context = nil
end

-- material_picker: prefer already-loaded global, fallback to dofile
local material_picker = _G.material_picker
if not material_picker then
    local ok, mp = pcall(dofile, mod_path .. "/material_picker.lua")
    if ok and mp then
        material_picker = mp
    else
        core.log("warning", "[chat_gui] material_picker not available: " .. tostring(mp))
    end
end

local function get_llm_api()
    if not _G.llm_api then error("[chat_gui] llm_api not available") end
    return _G.llm_api
end

-- ============================================================
-- Privilege helpers
-- llm_root is a superrole: implies llm + llm_dev + llm_worldedit
-- ============================================================

local function raw_priv(name, priv)
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

local function has_priv(name, priv)
    if raw_priv(name, "llm_root") then return true end
    return raw_priv(name, priv)
end

local function can_chat(name)       return has_priv(name, "llm") end
local function can_ide(name)        return has_priv(name, "llm_dev") end
local function can_worldedit(name)  return has_priv(name, "llm_worldedit") end
local function can_config(name)     return raw_priv(name, "llm_root") end  -- root only, no implication upward

-- ============================================================
-- Session
-- ============================================================

local sessions = {}

local WE_MODE_LABEL = {chat="Chat", single="WE Single", loop="WE Loop"}
local WE_MODE_COLOR = {chat="#444455", single="#2a4a6a", loop="#4a2a6a"}
local WE_MODE_COLOR_UNAVAIL = "#333333"

local function get_session(name)
    if not sessions[name] then
        sessions[name] = {history={}, last_input="", we_mode="chat"}
    end
    return sessions[name]
end

local function we_available()
    return type(_G.we_agency) == "table" and _G.we_agency.is_available()
end

local function cycle_we_mode(session, name)
    if not we_available() then
        core.chat_send_player(name, "[LLM] WorldEdit not available.")
        return
    end
    local cur = session.we_mode
    if     cur == "chat"   then session.we_mode = "single"
    elseif cur == "single" then session.we_mode = "loop"
    elseif cur == "loop"   then session.we_mode = "chat"
    end
    core.chat_send_player(name, "[LLM] Mode: " .. WE_MODE_LABEL[session.we_mode])
end

-- ============================================================
-- Build Formspec
-- ============================================================

function M.show(name)
    if not can_chat(name) then
        core.chat_send_player(name, "[LLM] Missing privilege: llm")
        return
    end

    local session = get_session(name)
    local text_accum = ""

    for _, msg in ipairs(session.history) do
        if msg.role ~= "system" then
            local content = msg.content or ""
            if msg.role == "user" then
                text_accum = text_accum .. "You: " .. content .. "\n\n"
            else
                text_accum = text_accum .. "[LLM]: " .. content .. "\n\n"
            end
        end
    end
    if text_accum == "" then
        text_accum = "Welcome to LLM Chat!\nType your question below."
    end

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

    -- Header box
    table.insert(fs, "box[0,0;" .. W .. "," .. HEADER_H .. ";#202020]")
    table.insert(fs, "label[" .. PAD .. ",0.30;LLM Chat - " .. core.formspec_escape(name) .. "]")

    -- ── Header Zeile 1 rechts: Config (root) + IDE (dev) ────
    local right_x = W - PAD
    if can_config(name) then
        right_x = right_x - 2.0
        table.insert(fs, "style[open_config;bgcolor=#2a2a1a;textcolor=#ffeeaa]")
        table.insert(fs, "button[" .. right_x .. ",0.08;2.0,0.65;open_config;Config]")
        table.insert(fs, "tooltip[open_config;Open LLM configuration (llm_root only)]")
    end
    if can_ide(name) then
        right_x = right_x - 2.3 - 0.15
        table.insert(fs, "style[open_ide;bgcolor=#1a1a2a;textcolor=#aaaaff]")
        table.insert(fs, "button[" .. right_x .. ",0.08;2.3,0.65;open_ide;IDE]")
        table.insert(fs, "tooltip[open_ide;Open Smart Lua IDE (llm_dev)]")
    end

    -- Header Zeile 2: drei direkte WE-Mode Buttons nebeneinander
    local mode = session.we_mode or "chat"
    if can_worldedit(name) then
        local we_ok = we_available()
        local dim = "#2a2a2a"

        local function we_btn(bname, bx, bw, blabel, active, color_on, color_dim, tip)
            local bg  = we_ok and (active and color_on or color_dim) or dim
            local fg  = active and "#ffffff" or (we_ok and "#889999" or "#555555")
            table.insert(fs, "style[" .. bname .. ";bgcolor=" .. bg .. ";textcolor=" .. fg .. "]")
            table.insert(fs, "button[" .. bx .. ",0.95;" .. bw .. ",0.65;" .. bname .. ";" .. blabel .. "]")
            table.insert(fs, "tooltip[" .. bname .. ";" .. (we_ok and tip or "WorldEdit not loaded") .. "]")
        end

        we_btn("we_btn_chat",   PAD,        2.6, "Chat",      mode=="chat",   "#444466", "#1e1e2e", "Normal LLM chat mode")
        we_btn("we_btn_single", PAD + 2.7,  2.8, "WE Single", mode=="single", "#2a4a7a", "#151d2a", "WorldEdit: one plan per message")
        we_btn("we_btn_loop",   PAD + 5.6,  2.6, "WE Loop",   mode=="loop",   "#4a2a7a", "#1e1228", "WorldEdit: iterative build loop (up to 6 steps)")

        if mode == "single" or mode == "loop" then
            local mat_count = material_picker and #material_picker.get_materials(name) or 0
            local mat_label = mat_count > 0 and ("Mats (" .. mat_count .. ")") or "Mats"
            local mat_color = mat_count > 0 and "#1a3a1a" or "#252525"
            table.insert(fs, "style[we_materials_open;bgcolor=" .. mat_color .. ";textcolor=#aaffaa]")
            table.insert(fs, "button[" .. (PAD + 8.3) .. ",0.95;2.6,0.65;we_materials_open;" .. mat_label .. "]")
            table.insert(fs, "tooltip[we_materials_open;Material picker: attach node names to LLM context]")
        end

        table.insert(fs, "style[we_undo;bgcolor=#3a2020;textcolor=#ffaaaa]")
        table.insert(fs, "button[" .. (W - PAD - 2.1) .. ",0.95;2.1,0.65;we_undo;Undo]")
        table.insert(fs, "tooltip[we_undo;Undo last WorldEdit agency operation]")
    end

    -- Chat history
    table.insert(fs, "textarea[" .. PAD .. "," .. (HEADER_H + PAD) .. ";"
        .. (W - PAD*2) .. "," .. CHAT_H
        .. ";history_display;;" .. core.formspec_escape(text_accum) .. "]")
    table.insert(fs, "style[history_display;textcolor=#e0e0e0;bgcolor=#1a1a1a;border=false]")

    -- Input
    local input_y = HEADER_H + PAD + CHAT_H + PAD
    table.insert(fs, "field[" .. PAD .. "," .. input_y .. ";"
        .. (W - PAD*2 - 2.5) .. "," .. INPUT_H
        .. ";input;;" .. core.formspec_escape(session.last_input) .. "]")
    table.insert(fs, "button[" .. (W - PAD - 2.2) .. "," .. input_y
        .. ";2.2," .. INPUT_H .. ";send;Send]")
    table.insert(fs, "field_close_on_enter[input;false]")

    -- Toolbar
    local tb_y = input_y + INPUT_H + PAD
    table.insert(fs, "button[" .. PAD .. "," .. tb_y .. ";2.8,0.75;clear;Clear Chat]")

    core.show_formspec(name, "llm_connect:chat", table.concat(fs))
end

-- ============================================================
-- Formspec Handler
-- ============================================================

function M.handle_fields(name, formname, fields)
    -- Material Picker weiterleiten
    if formname:match("^llm_connect:material_picker") then
        if material_picker then
            local result = material_picker.handle_fields(name, formname, fields)
            if fields.close_picker or fields.close_and_back or fields.quit then
                M.show(name)
            end
            return result
        end
        return false
    end

    if not formname:match("^llm_connect:chat") then return false end

    local session = get_session(name)
    local updated = false

    -- ── WE-Buttons (privilege-geprüft) ──────────────────────

    if fields.we_btn_chat then
        if can_worldedit(name) then session.we_mode = "chat"; updated = true end
    elseif fields.we_btn_single then
        if can_worldedit(name) and we_available() then session.we_mode = "single"; updated = true end
    elseif fields.we_btn_loop then
        if can_worldedit(name) and we_available() then session.we_mode = "loop"; updated = true end

    elseif fields.we_materials_open then
        if can_worldedit(name) and material_picker then
            material_picker.show(name)
        end
        return true

    elseif fields.we_undo then
        if can_worldedit(name) and _G.we_agency then
            local res = _G.we_agency.undo(name)
            table.insert(session.history, {role="assistant",
                content=(res.ok and "Undo: " or "Error: ") .. res.message})
            updated = true
        end

    -- ── IDE / Config (privilege-geprüft) ────────────────────

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

    -- ── Send ────────────────────────────────────────────────

    elseif fields.send or fields.key_enter_field == "input" then
        local input = (fields.input or ""):trim()

        if input ~= "" then
            table.insert(session.history, {role="user", content=input})
            session.last_input = ""

            -- WE Loop (nur llm_worldedit)
            if session.we_mode == "loop" and can_worldedit(name) and we_available() then
                table.insert(session.history, {role="assistant", content="(starting WE loop...)"})
                updated = true
                local mat_ctx = material_picker and material_picker.build_material_context(name)
                local loop_input = mat_ctx and (input .. "\n\n" .. mat_ctx) or input
                _G.we_agency.run_loop(name, loop_input, {
                    max_iterations = (_G.llm_api and _G.llm_api.config.we_max_iterations or 6),
                    timeout = (_G.llm_api and _G.llm_api.get_timeout("we") or 90),
                    on_step = function(i, plan, results)
                        local lines = {"[WE Loop] Step " .. i .. ": " .. plan}
                        for _, r in ipairs(results) do
                            table.insert(lines, "  " .. (r.ok and "v" or "x") .. " " .. r.tool .. ": " .. r.message)
                        end
                        core.chat_send_player(name, table.concat(lines, "\n"))
                    end,
                }, function(res)
                    local reply = _G.we_agency.format_loop_results(res)
                    for i = #session.history, 1, -1 do
                        if session.history[i].content == "(starting WE loop...)" then
                            session.history[i].content = reply; break
                        end
                    end
                    M.show(name)
                end)

            -- WE Single (nur llm_worldedit)
            elseif session.we_mode == "single" and can_worldedit(name) and we_available() then
                table.insert(session.history, {role="assistant", content="(planning WE operations...)"})
                updated = true
                local mat_ctx = material_picker and material_picker.build_material_context(name)
                local single_input = mat_ctx and (input .. "\n\n" .. mat_ctx) or input
                _G.we_agency.request(name, single_input, function(res)
                    local reply = not res.ok
                        and ("Error: " .. (res.error or "unknown"))
                        or  _G.we_agency.format_results(res.plan, res.results)
                    for i = #session.history, 1, -1 do
                        if session.history[i].content == "(planning WE operations...)" then
                            session.history[i].content = reply; break
                        end
                    end
                    M.show(name)
                end)

            -- Normal Chat (immer erlaubt wenn llm)
            else
                -- WE-Mode zurücksetzen wenn kein Privileg
                if session.we_mode ~= "chat" and not can_worldedit(name) then
                    session.we_mode = "chat"
                end
                local messages = {}
                local context_added = false
                if chat_context then
                    messages = chat_context.append_context(messages, name)
                    if #messages > 0 and messages[1].role == "system" then context_added = true end
                end
                if not context_added then
                    table.insert(messages, 1, {role="system",
                        content="You are a helpful assistant in the Luanti/Minetest game."})
                end
                for _, msg in ipairs(session.history) do table.insert(messages, msg) end
                table.insert(session.history, {role="assistant", content="(thinking...)"})
                updated = true
                local llm_api = get_llm_api()
                llm_api.request(messages, function(result)
                    local content = result.success and result.content
                        or "Error: " .. (result.error or "Unknown error")
                    for i = #session.history, 1, -1 do
                        if session.history[i].content == "(thinking...)" then
                            session.history[i].content = content; break
                        end
                    end
                    M.show(name)
                end, {timeout = (_G.llm_api and _G.llm_api.get_timeout("chat") or 180)})
            end
        end

    -- ── Clear ───────────────────────────────────────────────

    elseif fields.clear then
        session.history = {}
        session.last_input = ""
        updated = true

    elseif fields.quit then
        return true
    end

    if updated then M.show(name) end
    return true
end

core.register_on_leaveplayer(function(player)
    sessions[player:get_player_name()] = nil
end)

return M
