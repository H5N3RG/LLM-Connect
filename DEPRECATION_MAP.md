# LLM Connect 1.0 — Deprecation & Migration Map

Dieses Dokument beschreibt den Abriss-Plan vor der Kernsanierung.
Alle unten gelisteten Dateien sind als **DEPRECATED** markiert.
Keine Datei wird gelöscht — sie werden entweder umgeschrieben,
verschoben oder in neue Dateien überführt.

Die Versionierung bleibt bei `0.9.0-dev` bis zur gemeinsam
vereinbarten Finalisierung.

---

## Legende

| Symbol | Bedeutung |
|--------|-----------|
| 🔴 DEPRECATED → verschoben | Datei wird in `/addons/` überführt und dort neu geschrieben |
| 🟡 DEPRECATED → umstrukturiert | Datei bleibt im Root, wird aber wesentlich überarbeitet |
| 🟢 STABIL | Datei bleibt unverändert oder erhält nur minimale Anpassungen |
| 🆕 NEU | Neue Datei, existiert noch nicht |

---

## Bestehende Dateien — Status

### Root-Ebene (aktuell)

| Datei | Status | Ziel |
|-------|--------|------|
| `init.lua` | 🟡 DEPRECATED → umstrukturiert | Bleibt Root, aber Load-Order komplett neu: lädt `registry.lua`, `agent.lua`, `main_gui.lua`; entfernt alle direkten WE/IDE dofile-Aufrufe |
| `llm_api.lua` | 🟢 STABIL | Bleibt unverändert im Root |
| `config_gui.lua` | 🟡 DEPRECATED → umstrukturiert | Bleibt Root, erhält Agent-Sektion; WE-spezifische Settings wandern in Addon-Kontext |
| `chat_gui.lua` | 🔴 DEPRECATED → ersetzt | Wird zu `main_gui.lua` (neues unified UI); Chat-Logik bleibt erhalten, WE-Buttons weichen Agent-Buttons |
| `chat_context.lua` | 🔴 DEPRECATED → verschoben | Wird zu `basic_context.lua` im Root (player pos, server info, mod list — ohne WE/IDE-Spezifika) |
| `llm_worldedit.lua` | 🔴 DEPRECATED → verschoben | → `addons/worldedit_agent/worldedit_agent.lua` (auf Addon-Standard portiert) |
| `worldedit_system_prompts.lua` | 🔴 DEPRECATED → verschoben | → `addons/worldedit_agent/worldedit_system_prompts.lua` |
| `material_picker.lua` | 🔴 DEPRECATED → verschoben | → `addons/worldedit_agent/material_picker.lua` |
| `ide_gui.lua` | 🔴 DEPRECATED → verschoben | → `addons/smart_lua_ide/ide_gui.lua` ⚑ Sonderstellung (kein Registry-Addon) |
| `ide_system_prompts.lua` | 🔴 DEPRECATED → verschoben | → `addons/smart_lua_ide/ide_system_prompts.lua` |
| `ide_api_stubs.lua` | 🔴 DEPRECATED → verschoben | → `addons/smart_lua_ide/ide_api_stubs.lua` |
| `ide_asset_picker.lua` | 🔴 DEPRECATED → verschoben | → `addons/smart_lua_ide/ide_asset_picker.lua` |
| `ide_languages.lua` | 🔴 DEPRECATED → verschoben | → `addons/smart_lua_ide/ide_languages.lua` |
| `code_executor.lua` | 🔴 DEPRECATED → verschoben | → `addons/smart_lua_ide/code_executor.lua` |
| `settingtypes.txt` | 🟡 DEPRECATED → umstrukturiert | Agent- und Addon-Settings kommen hinzu; WE-Settings bleiben (vom WE-Addon referenziert) |
| `mod.conf` | 🟢 STABIL | Version bleibt `0.9.0-dev` |
| `README.md` | 🟡 DEPRECATED → umstrukturiert | Wird nach Finalisierung aller Phasen neu geschrieben |
| `ROADMAP100.md` | 🟢 STABIL | Dieses Dokument |
| `LICENSE` | 🟢 STABIL | Unverändert |

---

## Neue Dateien — Zielstruktur

| Datei | Typ | Beschreibung |
|-------|-----|--------------|
| `agent.lua` | 🆕 NEU | Universeller Agent-Core: Dispatch, Loop, Feedback, Snapshot |
| `registry.lua` | 🆕 NEU | Addon-Loader und `register_addon()`-API |
| `main_gui.lua` | 🆕 NEU | Unified UI (ersetzt `chat_gui.lua`): Chat + Agent-Panel + Addon-Status |
| `basic_context.lua` | 🆕 NEU | Basis-Kontext-Builder (aus `chat_context.lua` extrahiert) |

---

## Addon-Verzeichnisse — Zielstruktur

### `addons/worldedit_agent/`

| Datei | Herkunft |
|-------|----------|
| `worldedit_agent.lua` | portiert aus `llm_worldedit.lua` |
| `worldedit_system_prompts.lua` | verschoben aus Root |
| `material_picker.lua` | verschoben aus Root |

### `addons/smart_lua_ide/` ⚑ Sonderstellung

**Kein Registry-Addon.** Wird direkt von `init.lua` geladen — nicht von `registry.lua`.
Hat eigenen Formspec-Lifecycle, eigene LLM-Interaktion (generate → execute → auto-fix)
und eigenes Privilege (`llm_dev`). Verzeichnisstruktur dient nur der Übersichtlichkeit.

| Datei | Herkunft |
|-------|----------|
| `ide_gui.lua` | verschoben aus Root |
| `code_executor.lua` | verschoben aus Root |
| `ide_system_prompts.lua` | verschoben aus Root |
| `ide_api_stubs.lua` | verschoben aus Root |
| `ide_asset_picker.lua` | verschoben aus Root |
| `ide_languages.lua` | verschoben aus Root |

### `addons/mobs_redo/` *(Phase E — noch nicht begonnen)*

| Datei | Herkunft |
|-------|----------|
| `mobs_redo.lua` | 🆕 NEU |

---

## Reihenfolge der Arbeitsschritte

1. **`agent.lua` erstellen** — zuerst, da alle anderen darauf aufbauen
2. **`registry.lua` erstellen** — Addon-Loader, noch ohne Addons
3. **`basic_context.lua` erstellen** — aus `chat_context.lua` extrahieren
4. **`main_gui.lua` erstellen** — unified UI-Skelett (Chat bleibt funktional)
5. **`addons/smart_lua_ide/` befüllen** — IDE-Dateien verschieben, Pfade anpassen,
   `init.lua` direkt darauf zeigen (kein registry-Eintrag)
6. **`addons/worldedit_agent/` befüllen** — `llm_worldedit.lua` auf Addon-Standard portieren
7. **`init.lua` umschreiben** — neue Load-Order, alle alten dofile-Aufrufe entfernen
8. **Deprecated Root-Dateien archivieren** — in `_deprecated/` schieben oder löschen
   nach erfolgreicher Integration
