-- ===========================================================================
--  LLM Connect Init v0.7.7
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--  Fix: max_tokens type handling, fully configurable, robust JSON
--  Addet: metadata for ingame-commads
--  Enhancement: Dynamic metadata handling, player name in prompts
-- ===========================================================================

local core = core

-- Load HTTP API
local http = core.request_http_api()
if not http then
    core.log("error", "[llm_connect] HTTP API not available! Add 'llm_connect' to secure.http_mods in minetest.conf!")
    return
end

-- === Load settings from menu / settingtypes.txt ===
local api_key    = core.settings:get("llm_api_key") or ""
local api_url    = core.settings:get("llm_api_url") or ""
local model_name = core.settings:get("llm_model") or ""

-- max_tokens type: default integer, override via settings
local setting_val = core.settings:get_bool("llm_max_tokens_integer")
local max_tokens_type = "integer"
if setting_val == false then
    max_tokens_type = "float"
end

-- Storage for conversation history per player
local history = {}
local max_history = { ["default"] = 10 }
local metadata_cache = {} -- Cache for metadata to detect changes

-- Helper functions
local function get_history(name)
    history[name] = history[name] or {}
    return history[name]
end

local function get_max_history(name)
    return max_history[name] or max_history["default"]
end

local function string_split(str, delim)
    local res = {}
    local i = 1
    local str_len = #str
    local delim_len = #delim
    while i <= str_len do
        local pos = string.find(str, delim, i, true)
        if pos then
            table.insert(res, string.sub(str, i, pos - 1))
            i = pos + delim_len
        else
            table.insert(res, string.sub(str, i))
            break
        end
    end
    return res
end

-- Load optional context files
local mod_dir = core.get_modpath("llm_connect")
local llm_materials_context = nil
pcall(function()
    llm_materials_context = dofile(mod_dir .. "/llm_materials_context.lua")
end)

local function read_file_content(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local system_prompt_content = read_file_content(mod_dir .. "/system_prompt.txt") or ""

-- === Privileges ===
core.register_privilege("llm", { description = "Can chat with the LLM model", give_to_singleplayer=true, give_to_admin=true })
core.register_privilege("llm_root", { description = "Can configure the LLM API key, model, and endpoint", give_to_singleplayer=true, give_to_admin=true })

-- === Metadata Functions ===
local meta_data_functions = {}
local function get_username(player_name) return player_name or "Unknown Player" end
local function get_installed_mods()
    local mods = {}
    if core.get_mods then
        for modname,_ in pairs(core.get_mods()) do table.insert(mods, modname) end
        table.sort(mods)
    else
        table.insert(mods,"Mod list not available")
    end
    return mods
end

-- NEUE FUNKTION: Befehle sammeln
local function get_installed_commands()
    local commands = {}
    if core.chatcommands then
        for name, cmd in pairs(core.chatcommands) do
            if not name:match("^__builtin:") then
                local desc = cmd.description or "No description"
                table.insert(commands, "/" .. name .. " " .. (cmd.params or "") .. " - " .. desc)
            end
        end
        table.sort(commands)
    else
        table.insert(commands, "Command list not available.")
    end
    return commands
end

local function get_server_settings()
    local settings = {
        server_name       = core.settings:get("server_name") or "Unnamed Server",
        server_description= core.settings:get("server_description") or "No description",
        motd              = core.settings:get("motd") or "No MOTD set",
        port              = core.settings:get("port") or "Unknown",
        gameid            = (core.get_game_info and core.get_game_info().id) or core.settings:get("gameid") or "Unknown",
        game_name         = (core.get_game_info and core.get_game_info().name) or "Unknown",
        worldpath         = core.get_worldpath() or "Unknown",
        mapgen            = core.get_mapgen_setting("mg_name") or "Unknown",
    }
    return settings
end

function meta_data_functions.gather_context(player_name)
    local context = {}
    context.player = get_username(player_name)
    context.installed_mods = get_installed_mods()
    context.installed_commands = get_installed_commands() -- HINZUGEFÜGT
    context.server_settings = get_server_settings()
    -- Add dynamic player data (e.g., position)
    local player = core.get_player_by_name(player_name)
    if player then
        local pos = player:get_pos()
        context.player_position = string.format("x=%.2f, y=%.2f, z=%.2f", pos.x, pos.y, pos.z)
    else
        context.player_position = "Unknown"
    end
    return context
end

-- Compute a simple hash for metadata to detect changes
local function compute_metadata_hash(context)
    local str = context.player .. context.server_settings.server_name .. context.server_settings.worldpath .. table.concat(context.installed_mods, ",") .. table.concat(context.installed_commands, ",") -- Hash aktualisiert
    return core.sha1(str)
end

-- === Chat Commands ===
core.register_chatcommand("llm_setkey", {
    params = "<key> [url] [model]",
    description = "Sets the API key, URL, and model for the LLM.",
    privs = {llm_root=true},
    func = function(name,param)
        if not core.check_player_privs(name,{llm_root=true}) then return false,"No permission!" end
        local parts = string_split(param," ")
        if #parts==0 then return false,"Please provide API key!" end
        api_key = parts[1]
        if parts[2] then api_url = parts[2] end
        if parts[3] then model_name = parts[3] end
        core.chat_send_player(name,"[LLM] API key, URL and model set.")
        return true
    end,
})

core.register_chatcommand("llm_setmodel", {
    params = "<model>",
    description = "Sets the LLM model.",
    privs = {llm_root=true},
    func = function(name,param)
        if not core.check_player_privs(name,{llm_root=true}) then return false,"No permission!" end
        if param=="" then return false,"Provide a model name!" end
        model_name = param
        core.chat_send_player(name,"[LLM] Model set to '"..model_name.."'.")
        return true
    end,
})

core.register_chatcommand("llm_set_endpoint", {
    params = "<url>",
    description = "Sets the API endpoint URL.",
    privs = {llm_root=true},
    func = function(name,param)
        if not core.check_player_privs(name,{llm_root=true}) then return false,"No permission!" end
        if param=="" then return false,"Provide URL!" end
        api_url = param
        core.chat_send_player(name,"[LLM] API endpoint set to "..api_url)
        return true
    end,
})

core.register_chatcommand("llm_set_context", {
    params = "<count> [player]",
    description = "Sets the max context length.",
    privs = {llm_root=true},
    func = function(name,param)
        if not core.check_player_privs(name,{llm_root=true}) then return false,"No permission!" end
        local parts = string_split(param," ")
        local count = tonumber(parts[1])
        local target_player = parts[2]
        if not count or count<1 then return false,"Provide number > 0!" end
        if target_player and target_player~="" then max_history[target_player]=count
        else max_history["default"]=count end
        core.chat_send_player(name,"[LLM] Context length set.")
        return true
    end,
})

core.register_chatcommand("llm_float", {
    description = "Set max_tokens as float",
    privs = {llm_root=true},
    func = function(name)
        max_tokens_type="float"
        core.chat_send_player(name,"[LLM] max_tokens now sent as float.")
        return true
    end,
})

core.register_chatcommand("llm_integer", {
    description = "Set max_tokens as integer",
    privs = {llm_root=true},
    func = function(name)
        max_tokens_type="integer"
        core.chat_send_player(name,"[LLM] max_tokens now sent as integer.")
        return true
    end,
})

core.register_chatcommand("llm_reset", {
    description = "Resets conversation and context.",
    privs = {llm=true},
    func = function(name)
        history[name] = {}
        metadata_cache[name] = nil -- Reset metadata cache
        core.chat_send_player(name,"[LLM] Conversation and metadata reset.")
    end,
})

-- === Main Chat Command ===
core.register_chatcommand("llm", {
    params = "<prompt>",
    description = "Sends prompt to the LLM",
    privs = {llm=true},
    func = function(name,param)
        if not core.check_player_privs(name,{llm=true}) then return false,"No permission!" end
        if param=="" then return false,"Provide a prompt!" end
        if api_key=="" or api_url=="" or model_name=="" then
            return false,"[LLM] API key, URL, or Model not set! Check mod settings."
        end

        local player_history = get_history(name)
        local max_hist = get_max_history(name)
        -- Add player name to prompt for clarity
        local user_prompt = "Player " .. name .. ": " .. param
        table.insert(player_history,{role="user",content=user_prompt})
        while #player_history>max_hist do table.remove(player_history,1) end

        -- Gather and cache metadata
        local context_data = meta_data_functions.gather_context(name)
        local current_metadata_hash = compute_metadata_hash(context_data)
        local needs_metadata_update = not metadata_cache[name] or metadata_cache[name].hash ~= current_metadata_hash

        local messages = {}
        -- Build dynamic system prompt with metadata
        local dynamic_system_prompt = system_prompt_content
        if needs_metadata_update then
            local mods_list_str = table.concat(context_data.installed_mods,", ")
            if #context_data.installed_mods>10 then mods_list_str="(More than 10 installed mods: "..#context_data.installed_mods..")" end
            local materials_context_str = ""
            if llm_materials_context and llm_materials_context.get_available_materials then
                materials_context_str = "\n\n--- AVAILABLE MATERIALS ---\n" .. llm_materials_context.get_available_materials()
            end
            -- Befehlsliste hinzufügen
            local commands_list_str = table.concat(context_data.installed_commands, "\n")

            local metadata_string = "\n\n--- METADATA ---\n" ..
                "Player: " .. context_data.player .. "\n" ..
                "Player Position: " .. context_data.player_position .. "\n" ..
                "Server Name: " .. context_data.server_settings.server_name .. "\n" ..
                "Server Description: " .. context_data.server_settings.server_description .. "\n" ..
                "MOTD: " .. context_data.server_settings.motd .. "\n" ..
                "Game: " .. context_data.server_settings.game_name .. " (" .. context_data.server_settings.gameid .. ")\n" ..
                "Mapgen: " .. context_data.server_settings.mapgen .. "\n" ..
                "World Path: " .. context_data.server_settings.worldpath .. "\n" ..
                "Port: " .. context_data.server_settings.port .. "\n" ..
                "Installed Mods (" .. #context_data.installed_mods .. "): " .. mods_list_str .. "\n" ..
                "Available Commands:\n" .. commands_list_str .. "\n" .. -- HINZUGEFÜGT
                materials_context_str
            dynamic_system_prompt = system_prompt_content .. metadata_string
            metadata_cache[name] = { hash = current_metadata_hash, metadata = metadata_string }
        else
            dynamic_system_prompt = system_prompt_content .. metadata_cache[name].metadata
        end

        table.insert(messages,{role="system",content=dynamic_system_prompt})
        for _,msg in ipairs(player_history) do table.insert(messages,msg) end

        -- === max_tokens handling with final JSON fix ===
        local max_tokens_value = 2000
        if max_tokens_type == "integer" then
            max_tokens_value = math.floor(max_tokens_value)
        else
            max_tokens_value = tonumber(max_tokens_value)
        end

        local body = core.write_json({ model=model_name, messages=messages, max_tokens=max_tokens_value })

        -- Force integer in JSON string if needed (important for Go backends)
        if max_tokens_type == "integer" then
            body = body:gsub('"max_tokens"%s*:%s*(%d+)%.0', '"max_tokens": %1')
        end

        core.log("action", "[llm_connect DEBUG] max_tokens_type = " .. max_tokens_type)
        core.log("action", "[llm_connect DEBUG] max_tokens_value = " .. tostring(max_tokens_value))

        -- Send HTTP request
        http.fetch({
            url = api_url,
            post_data = body,
            method = "POST",
            extra_headers = {
                "Content-Type: application/json",
                "Authorization: Bearer " .. api_key
            },
            timeout = 90,
        }, function(result)
            if result.succeeded then
                local response = core.parse_json(result.data)
                local text = "(no answer)"
                if response and response.choices and response.choices[1] and response.choices[1].message then
                    text = response.choices[1].message.content
                    table.insert(player_history,{role="assistant",content=text})
                elseif response and response.message and response.message.content then
                    text = response.message.content
                end
                core.chat_send_player(name,"[LLM] "..text)
            else
                core.chat_send_player(name,"[LLM] Request failed: "..(result.error or "Unknown error"))
            end
        end)

        return true,"Request sent..."
    end,
})
