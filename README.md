# LLM Connect

**LLM Connect** is a Luanti mod that integrates a large language model (LLM)
into your game session. It provides an AI-powered chat assistant, a full
Smart Lua IDE with sandboxed code execution, and a universal **In-Game Agent**
that can manipulate the game world through a pluggable addon system.

> Version: 1.0.0-dev — License: LGPL-3.0-or-later — Author: H5N3RG

---

## Features

### AI Chat
- Persistent per-player chat history with the LLM
- Two-layer context injection: **Basis** (server info, position, all chat
  commands) and **Erweitert** (nodes/items/entities filtered by type and
  mod picker)
- Per-player context layer selection, stored persistently per world
- 29 language options

### Smart Lua IDE
- Full-screen two-panel editor (code + output) with file manager
- AI Code Generation, Sandboxed Execution, Pre-Executor static analysis
- Auto-Fix Loop — LLM receives error output and self-corrects
- IDE Asset Picker — Nodes / Items+Tools / Sounds browser with search
- Luanti API Reference Injection (slim ~400 tokens / full ~2000 tokens)
- Syntax Check, Semantic Analysis, Code Explain
- Snippet file manager and `llm_startup.lua` persistence

### Universal In-Game Agent *(1.0 — in progress)*
- Natural-language goal input → iterative LLM loop → tool dispatch
- Pluggable addon system: any mod can register tools the agent can call
- Inter-mod-operable: external mods register via `llm_connect.registry.register()`
  or auto-discovery of a `llm_connect_addon.lua` file
- Per-player addon activation with global defaults
- Snapshot/undo support at agent level
- Built-in `run_chat_command` tool as generic fallback tier
- Stuck-detection: aborts when the LLM repeats an identical failing plan

---

## Requirements

| Dependency | Required | Notes |
|---|---|---|
| Luanti | ✓ | Tested on 5.8+ |
| HTTP API access | ✓ | `secure.http_mods = llm_connect` in `minetest.conf` |
| `worldedit` | optional | Required for WorldEdit agent addon |
| `worldeditadditions` | optional | Enables advanced WEA commands |
| OpenAI-compatible LLM API | ✓ | Local or hosted (Ollama, Mistral, OpenAI, …) |

---

## Installation

1. Clone or extract into your Luanti `mods/` directory
2. Add `secure.http_mods = llm_connect` to `minetest.conf`
3. Configure API URL, key, and model in-game via `/llm_config`

---

## Privileges

| Privilege | Description |
|---|---|
| `llm` | AI chat access |
| `llm_dev` | Smart Lua IDE and code execution |
| `llm_agent` | Agent mode and addon tool dispatch |
| `llm_root` | Full access — implies all above. Config, persistent code. |

---

## Chat Commands

| Command | Description |
|---|---|
| `/llm_config` | Open in-game configuration GUI |
| `/llm_config_reload` | Reload API settings without server restart |
| `/llm_startup_reload` | Re-execute `llm_startup.lua` at runtime (llm_root) |

---

## Addon Authoring (Inter-Mod API)

External mods can register tools the agent can call. Two ways:

**Explicit (preferred)** — in your mod's `init.lua`:
```lua
if core.global_exists("llm_connect") then
    llm_connect.registry.register({
        id          = "my_mod",
        label       = "My Mod",
        version     = "1.0.0",
        description = "One-sentence summary for LLM context.",
        available   = function() return type(my_mod) == "table" end,
        tools = {
            {
                name        = "do_thing",
                description = "What this does and when to call it.",
                parameters  = {
                    target = "string — e.g. 'default:stone'",
                },
            },
        },
        dispatch = function(tool_name, args, player_name)
            if tool_name == "do_thing" then
                -- implementation
                return { ok = true, message = "Done." }
            end
            return { ok = false, message = "Unknown tool: " .. tool_name }
        end,
    })
end
```

**Auto-discovery (fallback)** — place `llm_connect_addon.lua` in your mod
root. It will be found and executed automatically after all mods are loaded.

Your mod's `mod.conf`: `optional_depends = llm_connect`

---

## File Structure

```
llm_connect/
├── init.lua                        Mod entry point, load order
├── mod.conf                        Mod metadata
├── settingtypes.txt                All configurable settings
├── llm_api.lua                     HTTP request handling, API config
├── basic_context.lua               Basis + Erweitert context provider
├── registry.lua                    Inter-mod addon gateway
├── agent.lua                       Agent orchestrator (loop, dispatch, undo)
├── agent_system_prompts.lua        Agent LLM prompt builder         [TODO D]
├── main_gui.lua                    Main UI: Chat + Agent panel       [TODO F]
├── config_gui.lua                  In-game settings GUI              [TODO F]
├── smart_lua_ide/                  First-class sub-system (outside addons/, not registry-bound)
│   ├── ide_gui.lua
│   ├── code_executor.lua
│   ├── ide_system_prompts.lua
│   ├── ide_api_stubs.lua
│   ├── ide_asset_picker.lua
│   └── ide_languages.lua
└── addons/                         All registry/agent-bound addons live here
    ├── worldedit_agent/
    │   ├── worldedit_agent.lua                                       [TODO C]
    │   ├── worldedit_system_prompts.lua                              [TODO C]
    │   └── material_picker.lua                                       [TODO C]
    └── mobs_redo/
        └── mobs_redo.lua                                             [TODO E]
```

---

## License

LGPL-3.0-or-later — see [LICENSE](LICENSE)

---
---

# TODO — 1.0.0-dev

> This section tracks all remaining work for the 1.0.0 release.
> It will be removed from the final README and replaced with a CHANGELOG entry.
> Progress is tracked per phase (A–H from the original ROADMAP100).

---

## Status Overview

| Phase | Beschreibung | Status |
|-------|-------------|--------|
| A | Universal Agent Core (`agent.lua`) | ✅ Skelett fertig |
| B | Addon Registry (`registry.lua`) | ✅ Fertig, inter-mod-operabel |
| B+ | Basic Context (`basic_context.lua`) | ✅ Fertig |
| B+ | `init.lua` neu (1.0 Load-Order) | ✅ Fertig |
| C | WorldEdit Addon portieren | ⬜ Offen |
| D | Agent System Prompts | ⬜ Offen |
| E | Mobs Redo Addon (neu) | ⬜ Offen |
| F | Main GUI + Config GUI (Agent-Panel) | ⬜ Offen |
| G | Smart Lua IDE relocaten nach addons/ | ⬜ Offen |
| H | Finalisierung & Release | ⬜ Offen |

---

## TODO A — Agent Core (`agent.lua`) ✅

Skelett vollständig implementiert. Offene Punkte für spätere Iteration:

- [ ] `agent_system_prompts.lua` erstellen (Prompt-Builder für Manifest + Kontext)
- [ ] `get_agent_prompts()` in `agent.lua` verdrahten sobald Prompt-Datei existiert
- [ ] Integration-Test: agent.lua + registry.lua + basic_context.lua gemeinsam

---

## TODO B — Addon Registry + Kern-Infrastruktur ✅

- [x] `registry.lua` — inter-mod-operabel, `register()`, `load_internal()`,
      `discover_external()`, `expose_global()`
- [x] `basic_context.lua` — Basis-Layer (immer aktiv) + Erweitert-Layer (opt-in),
      Mod-Picker mit persistentem State
- [x] `init.lua` — neue 1.0 Load-Order, Registry verdrahtet, Smart Lua IDE
      als First-Class Sub-System
- [ ] `addons/README.md` — Addon-Authoring-Guide (für Community)

---

## TODO C — WorldEdit Addon portieren

Port von `llm_worldedit.lua` auf das neue Addon-Interface.

- [ ] `addons/worldedit_agent/worldedit_agent.lua` erstellen
  - Alle bestehenden Dispatcher portieren:
    `set`, `replace`, `copy`, `move`, `stack`, `flip`, `rotate`,
    `sphere`, `cylinder`, `pyramid`, `torus`, `ellipsoid`,
    `floodfill`, `overlay`, `replacemix`, `layers`, `erode`, `convolve`
  - Agent/Loop-Logik entfernen (jetzt in `agent.lua`)
  - `available()` prüft `worldedit`-Global
  - WEA-Tools als optionale Tool-Gruppe
  - pos1/pos2 Kontext-Injection + Nearby-Node-Sampling beibehalten
  - Snapshot/Undo an Agent-Core delegieren
- [ ] `addons/worldedit_agent/worldedit_system_prompts.lua` — portieren/anpassen
- [ ] `addons/worldedit_agent/material_picker.lua` — verschieben, Pfade anpassen
- [ ] Root-Dateien `llm_worldedit.lua`, `worldedit_system_prompts.lua`,
      `material_picker.lua` löschen (nach DEPRECATION_MAP)
- [ ] Regressionstest: alle WE-Funktionen gegen die Addon-Version testen

---

## TODO D — Agent System Prompts

- [ ] `agent_system_prompts.lua` erstellen
  - `build(manifest_text, context_text)` → system prompt string
  - Manifest-Sektion: strukturierte Tool-Beschreibungen
  - Kontext-Sektion: basic_context Output
  - LLM Response Format dokumentieren (JSON mit thought/plan/tool_calls/done)
  - `run_chat_command` als Built-in im Prompt erklären
  - Hinweis: wann spezifische Tools bevorzugen vs. Command-Fallback
- [ ] `get_agent_prompts()` in `agent.lua` mit echter Implementierung verdrahten

---

## TODO E — Mobs Redo Addon (neu)

Erste neue Community-Addon als Referenz-Implementierung.

- [ ] `addons/mobs_redo/mobs_redo.lua` erstellen
  - `available()`: prüft `mobs`-Global + Mindest-API-Surface
  - Tools:
    - `spawn_mob` — Mob bei Position oder beim Spieler spawnen
    - `remove_mob` — nächsten Mob eines Typs entfernen
    - `list_nearby_mobs` — Mobs im Radius mit Position + HP auflisten
    - `set_mob_property` — Runtime-Property ändern (hp, tamed, owner)
    - `kill_all_of_type` — alle Mobs eines Typs entfernen (Safety-Cap)
  - Konfigurierbares Radius-Limit
  - Privilege: `llm_agent` (kein zusätzliches Privilege nötig)

---

## TODO F — Main GUI + Config GUI (Agent-Panel)

- [ ] `main_gui.lua` erstellen (ersetzt `chat_gui.lua`)
  - Chat-Tab: bestehende Chat-Funktionalität übernehmen
  - Agent-Tab: Ziel-Eingabe + Addon-Auswahl + Step-Feedback-Panel
  - Addon-Status-Panel: alle registrierten Addons, aktiv/inaktiv, Tool-Count
  - Per-Addon Enable/Disable Toggles (pro Spieler)
- [ ] `config_gui.lua` erweitern
  - Agent-Sektion: Max-Iterations, Snapshot on/off, Command-Whitelist
  - Kontext-Layer-Picker: Basis / Erweitert Toggle
  - Erweitert-Picker: Typ-Toggles (Nodes/Items/Entities) + Mod-Picker Sub-GUI
  - Per-Addon Toggles (global defaults)
- [ ] `chat_gui.lua` in `main_gui.lua` aufgehen lassen (nach DEPRECATION_MAP)

---

## TODO G — Smart Lua IDE Relocation

Reine Strukturänderung — keine funktionalen Änderungen.

- [ ] Dateien von Root nach `smart_lua_ide/` verschieben:
  `ide_gui.lua`, `code_executor.lua`, `ide_system_prompts.lua`,
  `ide_api_stubs.lua`, `ide_asset_picker.lua`, `ide_languages.lua`
- [ ] Interne `dofile`-Pfade in allen IDE-Dateien auf neue Lage anpassen
- [ ] `init.lua` lädt bereits aus `smart_lua_ide/` — keine Änderung nötig
- [ ] Root-Dateien löschen (nach DEPRECATION_MAP)

---

## TODO H — Finalisierung & Release

- [ ] Integration-Test aller Phasen A–G
- [ ] `addons/worldedit_agent/` Regressionstest
- [ ] `addons/mobs_redo/` Test auf Server mit `mobs_redo` aktiv
- [ ] `addons/README.md` — Addon-Authoring-Guide für Community
- [ ] `CHANGELOG.md` — Eintrag für 1.0.0
- [ ] `settingtypes.txt` bereinigen:
  - Alte `llm_context_*` Settings entfernen / durch neue ersetzen
  - Agent-Settings hinzufügen
  - Version-Kommentar aktualisieren
- [ ] `mod.conf` Version: `0.9.0-dev` → `1.0.0` *(in Absprache mit Autor)*
- [ ] README: TODO-Sektion entfernen, finale Beschreibung
- [ ] Repository: Tag `v1.0.0`

---

## Architektur-Entscheidungen (Referenz)

Dokumentiert für spätere Nachvollziehbarkeit.

**Inter-Mod-Operabilität:** Externe Mods registrieren sich selbst —
`llm_connect` hängt nie von fremden Mods ab. Dependency-Richtung zeigt
immer *zu* llm_connect (`optional_depends = llm_connect`).

**Smart Lua IDE:** First-Class Sub-System, kein Registry-Addon. Eigener
Formspec-Lifecycle, eigene LLM-Interaktion, eigenes Privilege (`llm_dev`).
Liegt in `addons/smart_lua_ide/` nur für strukturelle Konsistenz.

**`thought`-Feld im LLM Response:** Wird an UI gestreamt (`on_thought`-Callback),
aber nicht in die History gespeichert → null Token-Overhead über Iterationen.

**basic_context Layer:** Mikro/Meso-Unterscheidung aufgegeben — Basis-Layer
ist immer aktiv (inkl. aller Chat-Commands), Erweitert ist opt-in mit
Typ-Toggle + Mod-Picker. Picker-State persistiert per World.

**Addon-Validation:** Strict — fehlende Pflichtfelder → Addon wird komplett
abgelehnt, nie degraded geladen.

**Tool-Naming:** Pflicht-Prefix `addon_id.tool_name` — Kollisionen strukturell
unmöglich. Registry strippt Prefix vor Addon-Dispatch-Aufruf.
