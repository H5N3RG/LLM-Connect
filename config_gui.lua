-- config_gui.lua
-- LLM API Configuration GUI (llm_root only)
-- v0.8.1: Added timeout field for better control

local core = core
local M = {}

local function has_priv(name, priv)
    local p = core.get_player_privs(name) or {}
    return p[priv] == true
end

local function get_llm_api()
    if not _G.llm_api then
        error("[config_gui] llm_api not available")
    end
    return _G.llm_api
end

function M.show(name)
    if not has_priv(name, "llm_root") then
        core.chat_send_player(name, "Missing privilege: llm_root")
        return
    end

    local llm_api = get_llm_api()
    local cfg = llm_api.config

    local W, H = 14.0, 14.5
    local PAD = 0.3
    local HEADER_H = 0.8
    local FIELD_H = 0.8
    local BTN_H = 0.9

    local fs = {
        "formspec_version[6]",
        "size[" .. W .. "," .. H .. "]",
        "bgcolor[#0f0f0f;both]",
        "style_type[*;bgcolor=#1a1a1a;textcolor=#e0e0e0;font=mono]",
    }

    -- Header
    table.insert(fs, "box[0,0;" .. W .. "," .. HEADER_H .. ";#202020]")
    table.insert(fs, "label[" .. PAD .. "," .. (HEADER_H/2 - 0.2) .. ";LLM Configuration (llm_root only)]")
    table.insert(fs, "label[" .. (W - 4) .. "," .. (HEADER_H/2 - 0.2) .. ";" .. os.date("%H:%M") .. "]")

    local y = HEADER_H + PAD * 2

    -- API Key
    table.insert(fs, "label[" .. PAD .. "," .. y .. ";API Key:]")
    y = y + 0.5
    table.insert(fs, "field[" .. PAD .. "," .. y .. ";" .. (W - PAD*2) .. "," .. FIELD_H .. ";api_key;;" .. core.formspec_escape(cfg.api_key or "") .. "]")
    table.insert(fs, "style[api_key;bgcolor=#1e1e1e]")
    y = y + FIELD_H + PAD

    -- API URL
    table.insert(fs, "label[" .. PAD .. "," .. y .. ";API URL:]")
    y = y + 0.5
    table.insert(fs, "field[" .. PAD .. "," .. y .. ";" .. (W - PAD*2) .. "," .. FIELD_H .. ";api_url;;" .. core.formspec_escape(cfg.api_url or "") .. "]")
    table.insert(fs, "style[api_url;bgcolor=#1e1e1e]")
    y = y + FIELD_H + PAD

    -- Model
    table.insert(fs, "label[" .. PAD .. "," .. y .. ";Model:]")
    y = y + 0.5
    table.insert(fs, "field[" .. PAD .. "," .. y .. ";" .. (W - PAD*2) .. "," .. FIELD_H .. ";model;;" .. core.formspec_escape(cfg.model or "") .. "]")
    table.insert(fs, "style[model;bgcolor=#1e1e1e]")
    y = y + FIELD_H + PAD

    -- Max Tokens & Temperature (side by side)
    table.insert(fs, "label[" .. PAD .. "," .. y .. ";Max Tokens:]")
    table.insert(fs, "label[" .. (W/2 + PAD) .. "," .. y .. ";Temperature:]")
    y = y + 0.5

    local half_w = (W - PAD*3) / 2
    table.insert(fs, "field[" .. PAD .. "," .. y .. ";" .. half_w .. "," .. FIELD_H .. ";max_tokens;;" .. tostring(cfg.max_tokens or 4000) .. "]")
    table.insert(fs, "style[max_tokens;bgcolor=#1e1e1e]")

    table.insert(fs, "field[" .. (W/2 + PAD) .. "," .. y .. ";" .. half_w .. "," .. FIELD_H .. ";temperature;;" .. tostring(cfg.temperature or 0.7) .. "]")
    table.insert(fs, "style[temperature;bgcolor=#1e1e1e]")
    y = y + FIELD_H + PAD

    -- Timeout field (new in v0.8.1)
    table.insert(fs, "label[" .. PAD .. "," .. y .. ";Timeout (seconds):]")
    y = y + 0.5
    table.insert(fs, "field[" .. PAD .. "," .. y .. ";" .. half_w .. "," .. FIELD_H .. ";timeout;;" .. tostring(cfg.timeout or 120) .. "]")
    table.insert(fs, "style[timeout;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[timeout;Global fallback timeout (30-600s). Per-mode overrides below override this.]")
    y = y + FIELD_H + PAD

    -- Per-mode timeout overrides
    table.insert(fs, "label[" .. PAD .. "," .. y .. ";Per-mode timeout overrides (0 = use global):]")
    y = y + 0.5
    local third_w = (W - PAD * 2 - 0.2 * 2) / 3
    local function tx(i) return PAD + i * (third_w + 0.2) end

    table.insert(fs, "label[" .. tx(0) .. "," .. y .. ";Chat:]")
    table.insert(fs, "label[" .. tx(1) .. "," .. y .. ";IDE:]")
    table.insert(fs, "label[" .. tx(2) .. "," .. y .. ";WorldEdit:]")
    y = y + 0.45

    table.insert(fs, "field[" .. string.format("%.2f", tx(0)) .. "," .. y .. ";" .. string.format("%.2f", third_w) .. "," .. FIELD_H .. ";timeout_chat;;" .. tostring(cfg.timeout_chat or 0) .. "]")
    table.insert(fs, "style[timeout_chat;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[timeout_chat;Chat mode timeout (0 = global)]")

    table.insert(fs, "field[" .. string.format("%.2f", tx(1)) .. "," .. y .. ";" .. string.format("%.2f", third_w) .. "," .. FIELD_H .. ";timeout_ide;;" .. tostring(cfg.timeout_ide or 0) .. "]")
    table.insert(fs, "style[timeout_ide;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[timeout_ide;IDE mode timeout (0 = global)]")

    table.insert(fs, "field[" .. string.format("%.2f", tx(2)) .. "," .. y .. ";" .. string.format("%.2f", third_w) .. "," .. FIELD_H .. ";timeout_we;;" .. tostring(cfg.timeout_we or 0) .. "]")
    table.insert(fs, "style[timeout_we;bgcolor=#1e1e1e]")
    table.insert(fs, "tooltip[timeout_we;WorldEdit mode timeout (0 = global)]")
    y = y + FIELD_H + PAD * 2

    -- WEA toggle + separator
    table.insert(fs, "box[" .. PAD .. "," .. y .. ";" .. (W - PAD*2) .. ",0.02;#333333]")
    y = y + 0.18
    local wea_val = core.settings:get_bool("llm_worldedit_additions", true)
    local wea_label = "Enable WorldEditAdditions tools (torus, ellipsoid, erode, convolve...)"
    local wea_is_installed = type(worldeditadditions) == "table"
    if not wea_is_installed then
        wea_label = wea_label .. "  [WEA mod not detected]"
    end
    table.insert(fs, "checkbox[" .. PAD .. "," .. y .. ";wea_enabled;" .. core.formspec_escape(wea_label) .. ";" .. (wea_val and "true" or "false") .. "]")
    y = y + 0.55 + PAD

    -- 4 buttons evenly distributed: Save, Reload, Test, Close
    local btn_count   = 4
    local btn_spacing = 0.2
    local btn_w       = (W - PAD * 2 - btn_spacing * (btn_count - 1)) / btn_count
    local function bx(i) return PAD + i * (btn_w + btn_spacing) end

    table.insert(fs, "button["  .. string.format("%.2f", bx(0)) .. "," .. y .. ";" .. string.format("%.2f", btn_w) .. "," .. BTN_H .. ";save;Save Config]")
    table.insert(fs, "button["  .. string.format("%.2f", bx(1)) .. "," .. y .. ";" .. string.format("%.2f", btn_w) .. "," .. BTN_H .. ";reload;Reload]")
    table.insert(fs, "button["  .. string.format("%.2f", bx(2)) .. "," .. y .. ";" .. string.format("%.2f", btn_w) .. "," .. BTN_H .. ";test;Test Connection]")
    table.insert(fs, "style[close;bgcolor=#3a1a1a;textcolor=#ffaaaa]")
    table.insert(fs, "button["  .. string.format("%.2f", bx(3)) .. "," .. y .. ";" .. string.format("%.2f", btn_w) .. "," .. BTN_H .. ";close;✕ Close]")
    y = y + BTN_H + PAD

    -- Info label
    table.insert(fs, "label[" .. PAD .. "," .. y .. ";Note: Runtime changes. Edit minetest.conf for persistence.]")

    core.show_formspec(name, "llm_connect:config", table.concat(fs))
end

function M.handle_fields(name, formname, fields)
    if not formname:match("^llm_connect:config") then
        return false
    end

    if not has_priv(name, "llm_root") then
        return true
    end

    local llm_api = get_llm_api()

    -- WEA checkbox: instant toggle (no Save needed)
    if fields.wea_enabled ~= nil then
        local val = fields.wea_enabled == "true"
        core.settings:set_bool("llm_worldedit_additions", val)
        core.chat_send_player(name, "[LLM] WorldEditAdditions tools: " .. (val and "enabled" or "disabled"))
        M.show(name)
        return true
    end

    if fields.save then
        -- Validation
        local max_tokens = tonumber(fields.max_tokens)
        local temperature = tonumber(fields.temperature)
        local timeout = tonumber(fields.timeout)

        if not max_tokens or max_tokens < 1 or max_tokens > 100000 then
            core.chat_send_player(name, "[LLM] Error: max_tokens must be between 1 and 100000")
            return true
        end

        if not temperature or temperature < 0 or temperature > 2 then
            core.chat_send_player(name, "[LLM] Error: temperature must be between 0 and 2")
            return true
        end

        if not timeout or timeout < 30 or timeout > 600 then
            core.chat_send_player(name, "[LLM] Error: timeout must be between 30 and 600 seconds")
            return true
        end

        local timeout_chat = tonumber(fields.timeout_chat) or 0
        local timeout_ide  = tonumber(fields.timeout_ide)  or 0
        local timeout_we   = tonumber(fields.timeout_we)   or 0

        for _, t in ipairs({timeout_chat, timeout_ide, timeout_we}) do
            if t ~= 0 and (t < 30 or t > 600) then
                core.chat_send_player(name, "[LLM] Error: per-mode timeouts must be 0 or between 30-600")
                return true
            end
        end

        llm_api.set_config({
            api_key = fields.api_key or "",
            api_url = fields.api_url or "",
            model = fields.model or "",
            max_tokens = max_tokens,
            temperature = temperature,
            timeout = timeout,
            timeout_chat = timeout_chat,
            timeout_ide  = timeout_ide,
            timeout_we   = timeout_we,
        })

        core.chat_send_player(name, "[LLM] Configuration updated (runtime only)")
        core.log("action", "[llm_connect] Config updated by " .. name)
        M.show(name)
        return true

    elseif fields.reload then
        llm_api.reload_config()
        core.chat_send_player(name, "[LLM] Configuration reloaded from settings")
        core.log("action", "[llm_connect] Config reloaded by " .. name)
        M.show(name)
        return true

    elseif fields.test then
        -- Test LLM connection with a simple request
        core.chat_send_player(name, "[LLM] Testing connection...")
        
        local messages = {
            {role = "user", content = "Reply with just the word 'OK' if you can read this."}
        }
        
        llm_api.request(messages, function(result)
            if result.success then
                core.chat_send_player(name, "[LLM] ✓ Connection test successful!")
                core.chat_send_player(name, "[LLM] Response: " .. (result.content or "No content"))
            else
                core.chat_send_player(name, "[LLM] ✗ Connection test failed!")
                core.chat_send_player(name, "[LLM] Error: " .. (result.error or "Unknown error"))
            end
        end, {timeout = 30})
        
        return true

    elseif fields.close or fields.quit then
        -- Return to chat_gui
        if _G.chat_gui then
            _G.chat_gui.show(name)
        else
            core.close_formspec(name, "llm_connect:config")
        end
        return true
    end

    return true
end

return M
