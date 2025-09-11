-- ===========================================================================
--  LLM Connect Init v0.7.2
--  author: H5N3RG
--  license: LGPL-3.0-or-later
-- ===========================================================================

-- Load the HTTP API
local http = core.request_http_api()
if not http then
    core.log("error", "[llm_connect] HTTP API not available. Check secure.http_mods!")
    return
end

-- === Configuration ===
local api_key = ""
local api_url = "" -- Correct URL
local model_name = "" -- Default model

-- Storage for the conversation history per player
local history = {}
-- Stores the maximum history length per player (or as default)
local max_history = { ["default"] = 10 }
local player_context_sent = {} -- Remembers if the context has already been sent

local function get_history(name)
    history[name] = history[name] or {}
    return history[name]
end

-- Function to get the maximum history length for a player
local function get_max_history(name)
    return max_history[name] or max_history["default"]
end

-- Function to read an external file (for system_prompt.txt)
local function read_file_content(filepath)
    local f = io.open(filepath, "r")
    if not f then
        core.log("error", "[llm_connect] Could not open file: " .. filepath)
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

-- Path to the system prompt file
local mod_dir = minetest.get_modpath("llm_connect")

-- Load the material context module
local llm_materials_context = dofile(mod_dir .. "/llm_materials_context.lua")
if not llm_materials_context or type(llm_materials_context) ~= "table" then
    core.log("error", "[llm_connect] 'llm_materials_context.lua' could not be loaded or is faulty. Material context will be disabled.")
    llm_materials_context = nil -- Disable the module if errors occur
end

local system_prompt_filepath = mod_dir .. "/system_prompt.txt"

-- Load the system prompt from the file
local system_prompt_content = read_file_content(system_prompt_filepath)
if not system_prompt_content or system_prompt_content == "" then
    core.log("warning", "[llm_connect] System prompt file not found or empty. No default prompt will be used.")
    system_prompt_content = nil
end

-- NEW: Privilege registration
core.register_privilege("llm", {
    description = "Can chat with the LLM model",
    give_to_singleplayer = true, -- Single players can chat by default
    give_to_admin = true,        -- Admins can chat by default
})

core.register_privilege("llm_root", {
    description = "Can configure the LLM API key, model, and endpoint URL",
    give_to_singleplayer = true, -- Single players can configure everything by default
    give_to_admin = true,        -- Admins receive this privilege by default
})
-- END NEW

-- === Metadata Functions ===
local meta_data_functions = {}

local function get_username(player_name)
    return player_name or "Unknown Player"
end

-- List of installed mods
local function get_installed_mods()
    local mods = {}
    if minetest and minetest.get_mods then
        for modname, _ in pairs(minetest.get_mods()) do
            table.insert(mods, modname)
        end
        table.sort(mods)
    else
        core.log("warning", "[llm_connect] minetest.get_mods() not available.")
        table.insert(mods, "Mod list not available")
    end
    return mods
end

-- Server settings & actual info
local function get_server_settings()
    local settings = {
        server_name       = minetest.settings:get("server_name") or "Unnamed Server",
        server_description= minetest.settings:get("server_description") or "No description",
        motd              = minetest.settings:get("motd") or "No MOTD set",
        port              = minetest.settings:get("port") or "Unknown",
        gameid            = (minetest.get_game_info and minetest.get_game_info().id) or
                            minetest.settings:get("gameid") or "Unknown",
        game_name         = (minetest.get_game_info and minetest.get_game_info().name) or "Unknown",
        worldpath         = minetest.get_worldpath() or "Unknown",
        mapgen            = minetest.get_mapgen_setting("mg_name") or "Unknown",
    }
    return settings
end

-- Main context function
function meta_data_functions.gather_context(player_name)
    local context = {}
    context.player = get_username(player_name)
    context.installed_mods = get_installed_mods()
    context.server_settings = get_server_settings()
    return context
end

-- === Helper function for string splitting ===
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

-- === Chat Commands ===

-- Command to set the API key and URL
core.register_chatcommand("llm_setkey", {
    params = "<key> [url] [model]",
    description = "Sets the API key, URL, and model for the LLM.",
    privs = {llm_root = true}, -- Requires llm_root privilege
    func = function(name, param)
        if not core.check_player_privs(name, {llm_root = true}) then -- Additional check
            return false, "You do not have the permission to set the LLM key."
        end

        local parts = string_split(param, " ")
        if #parts == 0 then
            return false, "Please provide an API key! [/llm_setkey <key> [url] [model]]"
        end

        api_key = parts[1]
        if parts[2] then
            api_url = parts[2]
        end
        if parts[3] then
            model_name = parts[3]
        end

        core.chat_send_player(name, "[LLM] API key and URL set. New URL: " .. api_url .. ", Model: " .. model_name)
        return true
    end,
})

-- Command to change the model
core.register_chatcommand("llm_setmodel", {
    params = "<model>",
    description = "Sets the LLM model to be used.",
    privs = {llm_root = true}, -- Requires llm_root privilege
    func = function(name, param)
        if not core.check_player_privs(name, {llm_root = true}) then -- Additional check
            return false, "You do not have the permission to change the LLM model."
        end

        if param == "" then
            return false, "Please provide a model name! [/llm_setmodel <model>]"
        end
        model_name = param
        core.chat_send_player(name, "[LLM] Model set to '" .. model_name .. "'.")
        return true
    end,
})

-- Command to change the endpoint
core.register_chatcommand("llm_set_endpoint", {
    params = "<url>",
    description = "Sets the API URL of the LLM endpoint.",
    privs = {llm_root = true}, -- Requires llm_root privilege
    func = function(name, param)
        if not core.check_player_privs(name, {llm_root = true}) then -- Additional check
            return false, "You do not have the permission to change the LLM endpoint."
        end

        if param == "" then
            return false, "Please provide a URL! [/llm_set_endpoint <url>]"
        end
        api_url = param
        core.chat_send_player(name, "[LLM] API endpoint set to '" .. api_url .. "'.")
        return true
    end,
})

-- NEW: Command to set the context length
core.register_chatcommand("llm_set_context", {
    params = "<count> [player]",
    description = "Sets the max context length. For all players if 'player' is omitted.",
    privs = {llm_root = true},
    func = function(name, param)
        if not core.check_player_privs(name, {llm_root = true}) then
            return false, "You do not have the permission to change the context length."
        end

        local parts = string_split(param, " ")
        local count_str = parts[1]
        local target_player = parts[2]

        local count = tonumber(count_str)
        if not count or count < 1 then
            return false, "Please provide a valid number > 0!"
        end

        if target_player and target_player ~= "" then
            max_history[target_player] = count
            core.chat_send_player(name, "[LLM] Maximum history length for '" .. target_player .. "' set to " .. count .. ".")
        else
            max_history["default"] = count
            core.chat_send_player(name, "[LLM] Default history length for all players set to " .. count .. ".")
        end

        return true
    end,
})

-- Command to reset the context
core.register_chatcommand("llm_reset", {
    description = "Resets the LLM conversation and context.",
    privs = {llm = true},
    func = function(name, param)
        history[name] = {}
        player_context_sent[name] = false
        core.chat_send_player(name, "[LLM] Conversation and context have been reset.")
    end,
})

-- Main chat command
core.register_chatcommand("llm", {
    params = "<prompt>",
    description = "Sends a prompt to the LLM",
    privs = {llm = true}, -- Requires llm privilege
    func = function(name, param)
        if not core.check_player_privs(name, {llm = true}) then
            return false, "You do not have the permission to chat with the LLM."
        end

        if param == "" then
            return false, "Please provide a prompt!"
        end

        if api_key == "" then
            return false, "API key not set. Use /llm_setkey <key> [url] [model]"
        end

        local player_history = get_history(name)
        local max_hist = get_max_history(name) -- Retrieves the specific or default context length

        -- Add the new user prompt to the history
        table.insert(player_history, { role = "user", content = param })
        -- Remove the oldest entries if the history gets too long
        while #player_history > max_hist do
            table.remove(player_history, 1)
        end

        local messages = {}
        if system_prompt_content then
            table.insert(messages, { role = "system", content = system_prompt_content })
        end

        -- Send the context only once per player to save tokens
        if not player_context_sent[name] then
            local context_data = meta_data_functions.gather_context(name)
            local mods_list_str = table.concat(context_data.installed_mods, ", ")
            if #context_data.installed_mods > 10 then
                mods_list_str = "(More than 10 installed mods: " .. #context_data.installed_mods .. ")"
            end

            local materials_context_str = ""
            if llm_materials_context and llm_materials_context.get_available_materials then
                materials_context_str = "\n\n--- AVAILABLE MATERIALS ---\n" .. llm_materials_context.get_available_materials()
            end

            local metadata_string = "Server Information:\n" ..
                "  Player: " .. context_data.player .. "\n" ..
                "  Server Name: " .. context_data.server_settings.server_name .. "\n" ..
                "  Server Description: " .. context_data.server_settings.server_description .. "\n" ..
                "  MOTD: " .. context_data.server_settings.motd .. "\n" ..
                "  Game: " .. context_data.server_settings.game_name .. " (" .. context_data.server_settings.gameid .. ")\n" ..
                "  Mapgen: " .. context_data.server_settings.mapgen .. "\n" ..
                "  World Path: " .. context_data.server_settings.worldpath .. "\n" ..
                "  Port: " .. context_data.server_settings.port .. "\n" ..
                "  Installed Mods (" .. #context_data.installed_mods .. "): " .. mods_list_str .. "\n" .. materials_context_str

            table.insert(messages, { role = "user", content = "--- METADATA ---\n" .. metadata_string })
            player_context_sent[name] = true
        end

        for _, msg in ipairs(player_history) do
            table.insert(messages, msg)
        end

        local body = core.write_json({
            model = model_name,
            messages = messages,
            max_tokens = 2000
        })

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
                    table.insert(player_history, { role = "assistant", content = text })
                elseif response and response.message and response.message.content then
                    text = response.message.content
                end
                core.chat_send_player(name, "[LLM] " .. text)
            else
                core.chat_send_player(name, "[LLM] Request failed: " .. (result.error or "Unknown error"))
            end
        end)

        return true, "Request sent to LLM..."
    end,
})
