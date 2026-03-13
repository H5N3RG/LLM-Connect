-- ===========================================================================
--  registry.lua — LLM Connect 1.0 Addon Registry
--  author: H5N3RG
--  license: LGPL-3.0-or-later
--
--  ROLE: Gateway, Loader, Validator, Aggregator — inter-mod-operabel.
--
--  ZWEI REGISTRIERUNGSWEGE (identische API, unterschiedliches Timing):
--
--  1. EXPLIZIT via globalem Namespace (bevorzugt):
--       -- in einem externen Mod's init.lua:
--       if core.global_exists("llm_connect") then
--           llm_connect.registry.register({ id="mobs_redo", ... })
--       end
--
--  2. AUTO-DISCOVERY via llm_connect_addon.lua (Fallback):
--       -- Datei: <fremdes_mod>/llm_connect_addon.lua
--       -- Wird nach mods_loaded automatisch gefunden und ausgeführt.
--       -- Die Datei ruft selbst register() auf:
--       llm_connect.registry.register({ id="farming", ... })
--
--  DEPENDENCY-RICHTUNG:
--    Externes Mod: optional_depends = llm_connect
--    llm_connect hängt NICHT von externen Mods ab.
--    Externes Mod prüft selbst ob llm_connect geladen ist.
--
--  LOAD-ORDER / TIMING:
--    Phase 1 — registry.lua lädt (in init.lua):
--      → _G.llm_connect.registry verfügbar (expose_global())
--      → Interne Addons via load_internal() sofort geladen
--    Phase 2 — Alle Mods geladen (on_mods_loaded in init.lua):
--      → Externe Mods haben bereits explizit register() aufgerufen
--      → discover_external() sucht llm_connect_addon.lua in allen Mod-Pfaden
--      → Doppelregistrierungen werden erkannt und ignoriert
--    Phase 3 — Spieler tritt bei:
--      → get_active_addons() filtert nach available/privilege/enabled
--
--  ADDON API CONTRACT:
--    Pflichtfelder (fehlt eines → Addon wird NICHT registriert, Fehler im Log):
--
--      id          = "my_addon"        -- snake_case, global eindeutig
--      label       = "My Addon"        -- Anzeigename in der GUI
--      version     = "1.0.0"           -- Addon-Version
--      description = "..."             -- Einzeiler für LLM-Kontext
--      available   = function()        -- Gibt bool zurück: Abhängigkeiten geladen?
--                      return type(some_global) == "table"
--                    end
--      tools = {                       -- Mindestens ein Tool erforderlich
--        {
--          name        = "do_thing",   -- Kein Punkt! Registry setzt Prefix.
--          description = "...",        -- In LLM-Systemprompt injiziert
--          parameters  = {            -- key=Name, value=Typ+Beschreibung
--            target = "string — Ziel-Node z.B. 'default:stone'",
--          },
--          returns = "string",         -- optional
--        },
--      },
--      dispatch = function(tool_name, args, player_name)
--        -- tool_name OHNE Prefix ("do_thing", nicht "my_addon.do_thing")
--        -- Rückgabe: { ok=bool, message=string, data=any (optional) }
--      end,
--
--    Optionale Felder (müssen functions sein wenn angegeben, außer privilege):
--      privilege     = "llm_agent"     -- benötigtes Privilege (string)
--      get_context   = function(player_name) return "string" end
--      snapshot_hook = function(player_name) return data end
--      restore_hook  = function(player_name, data) return ok, err end
--      on_enable     = function(player_name) end
--      on_disable    = function(player_name) end
--
--  TOOL-NAMING:
--    Registry fügt "<addon_id>." als Prefix hinzu — automatisch, immer.
--    "my_addon" + "do_thing" → "my_addon.do_thing" im Manifest und tool_calls.
--    dispatch() bekommt nur "do_thing" (Prefix wird vor dem Aufruf entfernt).
--    Kollisionen sind strukturell unmöglich da addon_ids eindeutig sind.
--
--  GLOBALER NAMESPACE:
--    _G.llm_connect = {
--      registry = M,          -- diese Datei
--      agent    = ...,        -- agent.lua (von init.lua gesetzt)
--      version  = "1.0.0-dev"
--    }
--
-- ===========================================================================

local core = core
local M    = {}

-- ===========================================================================
-- Interner State
-- ===========================================================================

-- Alle erfolgreich registrierten Addons: { [addon_id] = addon_def }
M.addons = {}

-- O(1) Tool-Dispatch-Lookup: { ["addon_id.tool_name"] = addon_id }
M._tool_index = {}

-- Welche IDs bereits registriert wurden + von wo — für Doppelregistrierungs-Check
-- { [addon_id] = source_hint_string }
M._registered_ids = {}

-- Per-Player Aktivierungsstate
-- { [player_name] = { enabled_addons = { [addon_id] = bool } | nil } }
M.player_state = {}

-- Verhindert mehrfaches discover_external()
M._discovery_done = false

-- ===========================================================================
-- Validierungs-Spezifikationen
-- ===========================================================================

local REQUIRED_FIELDS = {
    {
        key = "id", typ = "string",
        check = function(v)
            if not v:match("^[a-z][a-z0-9_]*$") then
                return false, "muss snake_case sein (Kleinbuchstaben, Ziffern, Unterstriche)"
            end
            return true
        end,
    },
    { key = "label",       typ = "string"   },
    { key = "version",     typ = "string"   },
    { key = "description", typ = "string"   },
    { key = "available",   typ = "function" },
    {
        key = "tools", typ = "table",
        check = function(v)
            if #v < 1 then return false, "muss mindestens ein Tool enthalten" end
            return true
        end,
    },
    { key = "dispatch", typ = "function" },
}

local REQUIRED_TOOL_FIELDS = { "name", "description", "parameters" }

local OPTIONAL_FN_FIELDS = {
    "get_context", "snapshot_hook", "restore_hook", "on_enable", "on_disable"
}

-- ===========================================================================
-- Strikte Validierung
-- Gibt zurück: ok (bool), fehler (string|nil)
-- ===========================================================================

local function validate_addon(def, src)
    src = src or "register()"

    -- Top-Level Pflichtfelder
    for _, spec in ipairs(REQUIRED_FIELDS) do
        local val = def[spec.key]
        if val == nil then
            return false, string.format(
                "[registry] %s — Pflichtfeld '%s' fehlt", src, spec.key)
        end
        if type(val) ~= spec.typ then
            return false, string.format(
                "[registry] %s — '%s' muss %s sein, ist %s",
                src, spec.key, spec.typ, type(val))
        end
        if spec.check then
            local ok, hint = spec.check(val)
            if not ok then
                return false, string.format(
                    "[registry] %s — '%s': %s", src, spec.key, hint)
            end
        end
    end

    -- Jede Tool-Definition prüfen
    for i, tool in ipairs(def.tools) do
        if type(tool) ~= "table" then
            return false, string.format(
                "[registry] %s — tools[%d] muss eine Tabelle sein", src, i)
        end
        for _, tf in ipairs(REQUIRED_TOOL_FIELDS) do
            if tool[tf] == nil then
                return false, string.format(
                    "[registry] %s — tools[%d].%s fehlt", src, i, tf)
            end
        end
        if type(tool.name) ~= "string" then
            return false, string.format(
                "[registry] %s — tools[%d].name muss string sein", src, i)
        end
        if type(tool.description) ~= "string" then
            return false, string.format(
                "[registry] %s — tools[%d].description muss string sein", src, i)
        end
        if type(tool.parameters) ~= "table" then
            return false, string.format(
                "[registry] %s — tools[%d].parameters muss Tabelle sein", src, i)
        end
        -- Kein Punkt im Tool-Namen erlaubt — Registry fügt Prefix hinzu
        if tool.name:find("%.") then
            return false, string.format(
                "[registry] %s — tools[%d].name '%s' darf keinen Punkt enthalten" ..
                " (Registry fügt '<addon_id>.' automatisch hinzu)",
                src, i, tool.name)
        end
        if tool.name:match("%s") then
            return false, string.format(
                "[registry] %s — tools[%d].name '%s' darf keine Leerzeichen enthalten",
                src, i, tool.name)
        end
    end

    -- Optionale Hooks: wenn vorhanden, müssen sie functions sein
    for _, field in ipairs(OPTIONAL_FN_FIELDS) do
        if def[field] ~= nil and type(def[field]) ~= "function" then
            return false, string.format(
                "[registry] %s — optionales Feld '%s' muss function sein", src, field)
        end
    end

    if def.privilege ~= nil and type(def.privilege) ~= "string" then
        return false, string.format(
            "[registry] %s — 'privilege' muss string sein", src)
    end

    return true, nil
end

-- ===========================================================================
-- Tool-Index aufbauen
-- "<addon_id>.<tool_name>" → addon_id für O(1) dispatch-Lookup
-- ===========================================================================

local function index_addon_tools(addon_id, tools)
    for _, tool in ipairs(tools) do
        local full_name = addon_id .. "." .. tool.name
        if M._tool_index[full_name] then
            -- Strukturell unmöglich bei eindeutigen IDs — trotzdem loggen
            core.log("error", string.format(
                "[registry] KRITISCH: Tool-Namenskollision auf '%s' — IDs müssen eindeutig sein!",
                full_name))
        else
            M._tool_index[full_name] = addon_id
        end
    end
end

-- ===========================================================================
-- PUBLIC: M.register(addon_def, source_hint)
--
-- Der einzige Registrierungspunkt — intern wie extern identisch.
-- source_hint: optionaler String für Log-Meldungen (Dateipfad oder Mod-Name)
-- Gibt zurück: ok (bool), err (string|nil)
--
-- Kann aufgerufen werden:
--   a) Von einer internen Addon-Datei (dofile'd von load_internal)
--   b) Von einem externen Mod direkt: llm_connect.registry.register(...)
--   c) Von einer externen llm_connect_addon.lua (auto-discovery)
-- ===========================================================================

function M.register(addon_def, source_hint)
    local src = source_hint or "register()"

    if type(addon_def) ~= "table" then
        local err = "[registry] register() erwartet table, bekam: " .. type(addon_def)
        core.log("error", err)
        return false, err
    end

    local valid, err = validate_addon(addon_def, src)
    if not valid then
        core.log("error", err)
        return false, err
    end

    local addon_id = addon_def.id

    -- Doppelregistrierung: explizit + discovery → ignorieren, nicht crashen
    if M._registered_ids[addon_id] then
        core.log("warning", string.format(
            "[registry] Addon '%s' bereits registriert (von: %s)" ..
            " — Doppelregistrierung ignoriert",
            addon_id, M._registered_ids[addon_id]))
        return false, "already_registered"
    end

    addon_def._source         = src
    M.addons[addon_id]        = addon_def
    M._registered_ids[addon_id] = src
    index_addon_tools(addon_id, addon_def.tools)

    local avail_ok, avail = pcall(addon_def.available)
    avail = avail_ok and avail or false

    core.log("action", string.format(
        "[registry] ✓ '%s' (%s) | Quelle: %s | %d Tool(s) | verfügbar: %s",
        addon_id, addon_def.label, src, #addon_def.tools, tostring(avail)))

    return true, nil
end

-- ===========================================================================
-- PHASE 1: Interne Addons laden (aufgerufen von init.lua beim Start)
-- Lädt /addons/<dir>/<dir>.lua — jede Datei ruft M.register() auf.
-- smart_lua_ide wird übersprungen (First-Class Sub-System).
-- ===========================================================================

function M.load_internal()
    local mod_path   = core.get_modpath("llm_connect")
    local addons_dir = mod_path .. "/addons"

    local dirs = core.get_dir_list(addons_dir, true)
    if not dirs then
        core.log("warning", "[registry] /addons/ nicht gefunden — keine internen Addons")
        return
    end

    table.sort(dirs)  -- deterministisch

    local loaded, skipped, failed = 0, 0, 0

    for _, dir_name in ipairs(dirs) do
        if dir_name == "smart_lua_ide" then
            core.log("action", "[registry] Überspringe smart_lua_ide/ (direkt von init.lua geladen)")
            skipped = skipped + 1
        else
            -- Konvention: addons/<name>/<name>.lua
            local addon_file = addons_dir .. "/" .. dir_name .. "/" .. dir_name .. ".lua"
            local ok, err    = pcall(dofile, addon_file)
            if not ok then
                core.log("error", string.format(
                    "[registry] Fehler beim Laden von '%s': %s", addon_file, tostring(err)))
                failed = failed + 1
            elseif M._registered_ids[dir_name] then
                loaded = loaded + 1
            else
                -- Datei lud ohne Fehler, aber hat register() nicht aufgerufen
                core.log("warning", string.format(
                    "[registry] '%s' geladen aber hat register() nicht aufgerufen" ..
                    " — addon_id muss '%s' heißen",
                    addon_file, dir_name))
                failed = failed + 1
            end
        end
    end

    core.log("action", string.format(
        "[registry] load_internal: %d geladen, %d übersprungen, %d fehlgeschlagen",
        loaded, skipped, failed))
end

-- ===========================================================================
-- PHASE 2: Externe Addons auto-discovery (aufgerufen in on_mods_loaded)
-- Alle Mods sind geladen — explizite register()-Aufrufe bereits erfolgt.
-- Sucht nach <mod>/llm_connect_addon.lua in allen geladenen Mods.
-- Bereits registrierte IDs (explizit) werden via Doppelcheck ignoriert.
-- ===========================================================================

function M.discover_external()
    if M._discovery_done then
        core.log("warning", "[registry] discover_external() bereits ausgeführt — ignoriert")
        return
    end
    M._discovery_done = true

    local ADDON_FILE = "llm_connect_addon.lua"
    local found, loaded, failed = 0, 0, 0

    local mod_names = core.get_modnames()
    table.sort(mod_names)  -- deterministisch

    for _, mod_name in ipairs(mod_names) do
        if mod_name ~= "llm_connect" then  -- sich selbst überspringen
            local mod_path   = core.get_modpath(mod_name)
            local addon_file = mod_path .. "/" .. ADDON_FILE

            local f = io.open(addon_file, "r")
            if f then
                f:close()
                found = found + 1
                local ok, err = pcall(dofile, addon_file)
                if not ok then
                    core.log("error", string.format(
                        "[registry] Fehler in '%s/%s': %s",
                        mod_name, ADDON_FILE, tostring(err)))
                    failed = failed + 1
                else
                    loaded = loaded + 1
                    core.log("action", string.format(
                        "[registry] Externe Addon-Datei ausgeführt: %s/%s",
                        mod_name, ADDON_FILE))
                end
            end
        end
    end

    -- Gesamtanzahl registrierter Addons
    local total = 0
    for _ in pairs(M.addons) do total = total + 1 end

    core.log("action", string.format(
        "[registry] discover_external: %d Dateien gefunden, %d geladen, %d fehlgeschlagen",
        found, loaded, failed))
    core.log("action", string.format(
        "[registry] Registrierung abgeschlossen — %d Addon(s) gesamt registriert", total))
end

-- ===========================================================================
-- Settings helpers
-- ===========================================================================

-- Globale Defaults aus Settings: kommagetrennte Addon-IDs.
-- Leerer String oder nicht gesetzt = alle Addons standardmäßig aktiv.
local function global_enabled_set()
    local raw = core.settings:get("llm_agent_addons_enabled") or ""
    if raw:match("^%s*$") then return nil end  -- nil = "alle aktiv"
    local result = {}
    for part in raw:gmatch("[^,]+") do
        local id = part:match("^%s*(.-)%s*$")
        if id ~= "" then result[id] = true end
    end
    return result
end

-- ===========================================================================
-- Per-Player Aktivierungsstate
-- ===========================================================================

local function get_player_state(player_name)
    if not M.player_state[player_name] then
        M.player_state[player_name] = { enabled_addons = nil }
    end
    return M.player_state[player_name]
end

core.register_on_leaveplayer(function(player)
    M.player_state[player:get_player_name()] = nil
end)

-- Prüft ob ein Addon für einen Spieler aktiv ist.
-- Priorität: per-player Override > globale Settings > Default (alle aktiv)
function M.is_addon_enabled(player_name, addon_id)
    local ps = get_player_state(player_name)
    if ps.enabled_addons ~= nil then
        local v = ps.enabled_addons[addon_id]
        if v ~= nil then return v == true end
    end
    local global = global_enabled_set()
    if global ~= nil then return global[addon_id] == true end
    return true  -- Default: alle aktiv
end

-- Setzt Aktivierungsstatus für einen Spieler — aufgerufen von main_gui.
function M.set_player_addon(player_name, addon_id, enabled)
    if not M.addons[addon_id] then
        core.log("warning", "[registry] set_player_addon: unbekannte addon_id '" .. addon_id .. "'")
        return false
    end

    local ps = get_player_state(player_name)

    -- Lazy-Init aus globalen Defaults damit andere Addons ihren Status behalten
    if ps.enabled_addons == nil then
        ps.enabled_addons = {}
        local global = global_enabled_set()
        for id in pairs(M.addons) do
            ps.enabled_addons[id] = (global == nil) or (global[id] == true)
        end
    end

    local was = ps.enabled_addons[addon_id]
    ps.enabled_addons[addon_id] = enabled

    -- Lifecycle-Hooks nur bei Zustandsänderung
    if was ~= enabled then
        local addon = M.addons[addon_id]
        if enabled and addon.on_enable then
            pcall(addon.on_enable, player_name)
        elseif not enabled and addon.on_disable then
            pcall(addon.on_disable, player_name)
        end
        core.log("action", string.format(
            "[registry] '%s' hat '%s' %s",
            player_name, addon_id, enabled and "aktiviert" or "deaktiviert"))
    end

    return true
end

-- Setzt per-player Overrides zurück → globale Defaults gelten wieder.
function M.reset_player_addons(player_name)
    get_player_state(player_name).enabled_addons = nil
end

-- ===========================================================================
-- Aktive Addons ermitteln
-- Filtert nach: registered + available() + enabled + privilege
-- addon_filter: optionale ID-Liste vom Agent zur weiteren Einschränkung
-- ===========================================================================

function M.get_active_addons(player_name, addon_filter)
    local filter_set = nil
    if addon_filter then
        filter_set = {}
        for _, id in ipairs(addon_filter) do filter_set[id] = true end
    end

    local player_privs = core.get_player_privs(player_name) or {}
    local is_root      = player_privs["llm_root"] == true
    local active       = {}

    for addon_id, addon in pairs(M.addons) do
        if filter_set and not filter_set[addon_id] then goto continue end
        if not M.is_addon_enabled(player_name, addon_id)  then goto continue end

        local avail_ok, avail = pcall(addon.available)
        if not avail_ok or not avail                       then goto continue end

        if addon.privilege then
            if not is_root and not player_privs[addon.privilege] then goto continue end
        end

        table.insert(active, addon)
        ::continue::
    end

    table.sort(active, function(a, b) return a.id < b.id end)
    return active
end

-- ===========================================================================
-- Manifest — strukturiert und als Text für den LLM-Systemprompt
-- ===========================================================================

function M.get_manifest(player_name, addon_filter)
    local active   = M.get_active_addons(player_name, addon_filter)
    local manifest = {}
    for _, addon in ipairs(active) do
        for _, tool in ipairs(addon.tools) do
            table.insert(manifest, {
                full_name   = addon.id .. "." .. tool.name,
                addon_id    = addon.id,
                addon_label = addon.label,
                name        = tool.name,
                description = tool.description,
                parameters  = tool.parameters,
                returns     = tool.returns,
            })
        end
    end
    return manifest
end

function M.manifest_to_text(manifest)
    if not manifest or #manifest == 0 then
        return "(keine Tools verfügbar — Addons deaktiviert oder nicht geladen)"
    end

    local by_addon    = {}
    local addon_order = {}
    for _, entry in ipairs(manifest) do
        if not by_addon[entry.addon_id] then
            by_addon[entry.addon_id] = { label = entry.addon_label, tools = {} }
            table.insert(addon_order, entry.addon_id)
        end
        table.insert(by_addon[entry.addon_id].tools, entry)
    end

    local lines = {}
    for _, addon_id in ipairs(addon_order) do
        local group = by_addon[addon_id]
        table.insert(lines, "### " .. group.label .. "  [" .. addon_id .. "]")
        for _, tool in ipairs(group.tools) do
            table.insert(lines, "  tool: " .. tool.full_name)
            table.insert(lines, "  desc: " .. tool.description)
            local param_lines = {}
            for pname, pdesc in pairs(tool.parameters) do
                table.insert(param_lines, "    - " .. pname .. ": " .. pdesc)
            end
            if #param_lines > 0 then
                table.sort(param_lines)
                table.insert(lines, "  params:")
                for _, pl in ipairs(param_lines) do table.insert(lines, pl) end
            end
            if tool.returns then
                table.insert(lines, "  returns: " .. tool.returns)
            end
            table.insert(lines, "")
        end
    end

    return table.concat(lines, "\n")
end

-- ===========================================================================
-- Dispatch — O(1) Routing zum zuständigen Addon, niemals werfend
-- ===========================================================================

function M.dispatch(tool_name, args, player_name)
    local addon_id = M._tool_index[tool_name]
    if not addon_id then
        return {
            ok      = false,
            message = string.format(
                "Unbekanntes Tool '%s' — Format: '<addon_id>.<tool_name>'",
                tostring(tool_name)),
        }
    end

    local addon = M.addons[addon_id]
    if not addon then
        return { ok=false, message="Addon '" .. addon_id .. "' nicht mehr in Registry" }
    end

    local avail_ok, avail = pcall(addon.available)
    if not avail_ok or not avail then
        return { ok=false, message="Addon '" .. addon_id .. "' zur Laufzeit nicht verfügbar" }
    end

    if not M.is_addon_enabled(player_name, addon_id) then
        return { ok=false, message="Addon '" .. addon_id .. "' für diesen Spieler deaktiviert" }
    end

    -- Prefix entfernen: "worldedit_agent.set_region" → "set_region"
    local bare_name = tool_name:match("^[^%.]+%.(.+)$")
    if not bare_name then
        return { ok=false, message="Malformed tool name: '" .. tostring(tool_name) .. "'" }
    end

    local ok, result = pcall(addon.dispatch, bare_name, args or {}, player_name)
    if not ok then
        core.log("error", string.format(
            "[registry] dispatch Fehler — Addon '%s', Tool '%s': %s",
            addon_id, tool_name, tostring(result)))
        return { ok=false, message="Addon dispatch Fehler: " .. tostring(result) }
    end

    if type(result) ~= "table" then
        return { ok=false, message="Addon '" .. addon_id .. "' gab kein table zurück" }
    end

    return {
        ok      = result.ok == true,
        message = result.message or "(keine Nachricht)",
        data    = result.data,
    }
end

-- ===========================================================================
-- Kontext-Aggregation — alle aktiven Addons die get_context implementieren
-- ===========================================================================

function M.get_contexts(player_name, addon_filter)
    local active = M.get_active_addons(player_name, addon_filter)
    local parts  = {}
    for _, addon in ipairs(active) do
        if addon.get_context then
            local ok, ctx = pcall(addon.get_context, player_name)
            if ok and type(ctx) == "string" and ctx ~= "" then
                table.insert(parts, "--- " .. addon.label:upper() .. " ---")
                table.insert(parts, ctx)
            elseif not ok then
                core.log("warning", string.format(
                    "[registry] get_context Fehler in '%s': %s", addon.id, tostring(ctx)))
            end
        end
    end
    return table.concat(parts, "\n")
end

-- ===========================================================================
-- Snapshot & Restore
-- ===========================================================================

function M.snapshot(player_name, addon_filter)
    local active    = M.get_active_addons(player_name, addon_filter)
    local snap_data = {}
    for _, addon in ipairs(active) do
        if addon.snapshot_hook then
            local ok, data = pcall(addon.snapshot_hook, player_name)
            if ok then
                snap_data[addon.id] = data
            else
                core.log("warning", string.format(
                    "[registry] snapshot_hook Fehler in '%s': %s", addon.id, tostring(data)))
            end
        end
    end
    return snap_data
end

function M.restore(player_name, snap_data)
    if not snap_data or next(snap_data) == nil then
        return false, { "Keine Snapshot-Daten vorhanden" }
    end
    local errors = {}
    local any_ok = false
    for addon_id, data in pairs(snap_data) do
        local addon = M.addons[addon_id]
        if not addon then
            table.insert(errors, "Addon '" .. addon_id .. "' nicht mehr geladen")
        elseif not addon.restore_hook then
            table.insert(errors, "Addon '" .. addon_id .. "' hat keinen restore_hook")
        else
            local ok, err = pcall(addon.restore_hook, player_name, data)
            if ok then
                any_ok = true
            else
                table.insert(errors, addon_id .. ": " .. tostring(err))
                core.log("error", string.format(
                    "[registry] restore_hook Fehler in '%s': %s", addon_id, tostring(err)))
            end
        end
    end
    return any_ok, errors
end

-- ===========================================================================
-- Status / Introspection — für main_gui Addon-Auswahlpanel
-- Gibt alle geladenen Addons mit vollem Status zurück.
-- ===========================================================================

function M.get_status(player_name)
    local player_privs = core.get_player_privs(player_name) or {}
    local is_root      = player_privs["llm_root"] == true
    local status_list  = {}

    local sorted_ids = {}
    for id in pairs(M.addons) do table.insert(sorted_ids, id) end
    table.sort(sorted_ids)

    for _, addon_id in ipairs(sorted_ids) do
        local addon = M.addons[addon_id]

        local avail_ok, avail = pcall(addon.available)
        avail = avail_ok and avail or false

        local has_priv = true
        if addon.privilege then
            has_priv = is_root or (player_privs[addon.privilege] == true)
        end

        local enabled = M.is_addon_enabled(player_name, addon_id)

        -- Quelle für GUI (intern vs. extern)
        local src    = addon._source or "?"
        local origin = src:find(core.get_modpath("llm_connect"), 1, true) and "intern" or "extern"

        table.insert(status_list, {
            id          = addon_id,
            label       = addon.label,
            version     = addon.version,
            description = addon.description,
            source      = src,
            origin      = origin,      -- "intern" | "extern" — für GUI-Badge
            tool_count  = #addon.tools,
            available   = avail,       -- Mod-Abhängigkeit geladen?
            has_priv    = has_priv,    -- Spieler hat Privilege?
            enabled     = enabled,     -- Spieler hat aktiviert?
            effective   = avail and has_priv and enabled,  -- wirklich aktiv?
        })
    end

    return status_list
end

-- ===========================================================================
-- Globalen Namespace exponieren
-- Wird von init.lua aufgerufen nachdem registry.lua geladen ist.
-- Externe Mods können danach llm_connect.registry.register() aufrufen.
-- ===========================================================================

function M.expose_global()
    if not _G.llm_connect then
        _G.llm_connect = { version = "1.0.0-dev" }
    end
    _G.llm_connect.registry = M
    core.log("action",
        "[registry] _G.llm_connect.registry exponiert — externe Mods können register() aufrufen")
end

-- ===========================================================================

core.log("action", "[registry] Modul geladen — warte auf expose_global() + load_internal()")

return M
