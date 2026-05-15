# LLM Connect 1.1 — Deprecation & Migration Map

Dieses Dokument ersetzt die alte 0.9 → 1.0 Deprecation-Map.

Stand des Repos: `dev/1.0.0`, Version `1.0.0-dev` in `mod.conf`.
`1.0.0` wird **nicht finalisiert**, sondern als unfertige Zwischenarchitektur
übersprungen. Ziel ist die Grundsanierung für `1.1.0-dev` / `1.1.0`.

Codename: **Voyager-Infiltration**

---

## Kernentscheidung

Der bisherige Agent-Kern basiert auf JSON-Toolcalls:

```text
LLM → JSON → agent.lua parser → registry.lua → addon/tool dispatch
```

Dieser Pfad bleibt vorerst als Kompatibilitätsschicht erhalten, wird aber für
den neuen Hauptpfad abgelöst durch:

```text
LLM → Lua-Block → parser_utils.lua → core_executor.lua → Shadow-G Runtime
```

Die Smart Lua IDE und der Agent dürfen künftig **keine getrennten Executor-
Welten** mehr besitzen. Beide müssen über denselben zentralen Executor laufen.

---

## Legende

| Symbol | Bedeutung |
|--------|-----------|
| 🔴 RAUS / LEGACY | Bleibt höchstens als Kompatibilität oder wird später entfernt |
| 🟠 MODIFIZIEREN | Bleibt, muss aber architektonisch umgebaut werden |
| 🟡 KOMPAT-LAYER | Nur noch UI-/Namens-Shim, keine Runtime-Kompatibilität für JSON-Addons |
| 🟢 BLEIBT | Stabiler Bestandteil mit kleinen Anpassungen |
| 🆕 NEU | Muss für 1.1 entstehen |

---

## Versionierungsentscheidung

| Bereich | Status | Ziel |
|--------|--------|------|
| `1.0.0-dev` | 🟡 KOMPAT-LAYER | Bleibt als historischer Ist-Stand im Branch erhalten, wird aber nicht finalisiert |
| `mod.conf` Version | 🟠 MODIFIZIEREN | Von `1.0.0-dev` auf `1.1.0-dev` setzen, sobald die 1.1-Grundstruktur steht |
| Header-Kommentare `LLM Connect 1.0` | 🟠 MODIFIZIEREN | Auf `LLM Connect 1.1` aktualisieren, wenn jeweilige Datei migriert wurde |
| Dokumentation `README.md` | 🟠 MODIFIZIEREN | Nach Kernumbau neu schreiben; 1.0-Architektur nicht mehr als Zielzustand beschreiben |

---

## Root-Dateien

| Datei | Status | Entscheidung für 1.1 |
|------|--------|----------------------|
| `init.lua` | 🟠 MODIFIZIEREN | Load-Order erweitern: `parser_utils.lua` und `core_executor.lua` vor `agent.lua` laden; IDE-Executor nicht mehr separat als strategischer Executor behandeln |
| `llm_api.lua` | 🟢 BLEIBT | Transport-Layer bleibt; darf nur API/HTTP/Provider-Dialog verwalten, keine Execution-Logik |
| `agent.lua` | 🟠 MODIFIZIEREN | Von JSON-Orchestrator zu Lua-Orchestrator umbauen; JSON-Toolcalls entfernen |
| `agent_system_prompts.lua` | 🟠 MODIFIZIEREN | Prompt von JSON-Toolcall auf Direct-Lua-Codeblöcke umstellen; Toolmanifest wird Skill-/Runtime-Kontext |
| `registry.lua` | 🟠 MODIFIZIEREN | Von Addon-Registry zu Runtime-/Skill-Registry ausbauen; Hotreload idempotent machen; `registry.skills` ergänzen |
| `basic_context.lua` | 🟢 BLEIBT | Basis-Kontext bleibt; muss für Direct-Lua schlank, deterministisch und executor-freundlich bleiben |
| `execution_policy.lua` | 🟠 MODIFIZIEREN | Wird Policy-Zentrale für `llm_dev`, `llm_agent`, `llm_root`, Root-Gate, Sandbox-Level und Script-Freigabe |
| `main_gui.lua` | 🟠 MODIFIZIEREN | UI bleibt, aber Agent-Sendepfad muss Lua-Agent verwenden; Skill-Panel später terminologisch von Addons lösen |
| `config_gui.lua` | 🟠 MODIFIZIEREN | Neue Einstellungen für Direct-Lua, Shadow-G, Root-Gate und Persistenz ergänzen; Legacy-JSON als deprecated anzeigen |
| `settingtypes.txt` | 🟠 MODIFIZIEREN | Neue 1.1 Settings ergänzen; alte Addon-/Agent-Settings nicht sofort löschen |
| `README.md` | 🟠 MODIFIZIEREN | Nach lauffähigem 1.1-Kern neu schreiben |
| `AGENT_DESIGN.md` | 🟠 MODIFIZIEREN | Muss JSON-Agent-Design als Legacy markieren und Direct-Lua-Agentik beschreiben |
| `ROADMAP110.md` | 🟢 BLEIBT | Aktuelle Leit-Roadmap; Format später glätten |
| `DEPRECATION_MAP.md` | 🟢 BLEIBT | Dieses Dokument |
| `LICENSE` | 🟢 BLEIBT | Keine Änderung |

---

## Neue Root-Dateien

| Datei | Status | Aufgabe |
|------|--------|---------|
| `parser_utils.lua` | 🆕 NEU | Robuste Extraktion von Lua-Codeblöcken aus LLM-Antworten; tolerant gegenüber Markdown, Prosa, kaputten Fences |
| `core_executor.lua` | 🆕 NEU | Gemeinsamer Executor für Agent und IDE: parse/validate/compile/sandbox/execute/recover |
| `runtime_context.lua` | 🆕 OPTIONAL | Späterer Sammelpunkt für executor-nahe Kontextobjekte, falls `basic_context.lua` zu breit wird |
| `skill_store.lua` | 🆕 OPTIONAL | Spätere Persistenzschicht für erfolgreiche Skills unter `world/llm_scripts/<user>/` |

Minimalziel für Schritt 1.1:

```text
parser_utils.lua + core_executor.lua existieren und werden von init.lua geladen.
```

---

## Smart Lua IDE

| Datei | Status | Entscheidung für 1.1 |
|------|--------|----------------------|
| `smart_lua_ide/code_executor.lua` | 🔴 RAUS / LEGACY | Strategisch ersetzen durch Root-`core_executor.lua`; Datei bleibt vorerst als Shim oder Wrapper |
| `smart_lua_ide/ide_gui.lua` | 🟠 MODIFIZIEREN | Muss Ausführung über `llm_connect.core_executor` routen |
| `smart_lua_ide/ide_system_prompts.lua` | 🟠 MODIFIZIEREN | Auto-Fix-Prompt an zentrale Executor-Fehlerstruktur anpassen |
| `smart_lua_ide/ide_api_stubs.lua` | 🟡 KOMPAT-LAYER | Bleibt als Dokumentations-/Hint-Layer, aber nicht als Sandbox-Quelle der Wahrheit |
| `smart_lua_ide/ide_asset_picker.lua` | 🟢 BLEIBT | UI-/Asset-Helfer bleibt |
| `smart_lua_ide/ide_languages.lua` | 🟢 BLEIBT | Sprach-/Template-Helfer bleibt |

Ziel:

```text
IDE erzeugt Code → core_executor.execute(scope="ide")
Agent erzeugt Code → core_executor.execute(scope="agent")
```

---

## Addons / Skills

Die aktuelle Codebasis nutzt intern noch den Begriff `addons`, während die UI bereits
teilweise von `Skills` spricht. Für 1.1 gilt:

| Begriff | Status | Ziel |
|--------|--------|------|
| `addons/` Pfad | 🔴 RAUS / LEGACY | Nicht mehr automatisch laden; bestehende Addons später als Lua-first Skills neu schreiben |
| User-facing Begriff „Addon“ | 🔴 RAUS / LEGACY | Durch „Skill“ ersetzen |
| `registry.addons` | 🟡 KOMPAT-LAYER | Nur noch leere Sichtbarkeits-/UI-Kompatibilität; Runtime-State liegt in `registry.skills` |
| `registry.skills` | 🆕 NEU | Neuer strategischer State-Store für persistente und dynamische Fähigkeiten |
| `register_addon()` / `registry.register()` Semantik | 🟠 MODIFIZIEREN | Zu Skill-Manifest erweitern: Version, Permissions, Persistenz, Hash, Source, Lifecycle |

---

## Interne Skills

| Pfad | Status | Entscheidung für 1.1 |
|-----|--------|----------------------|
| `addons/command_agent/command_agent.lua` | 🔴 RAUS / LEGACY | Wird nicht mehr geladen; JSON/Chatcommand-Agent wird verworfen |
| `addons/worldedit_agent/worldedit_agent.lua` | 🔴 RAUS / LEGACY | Wird später als Lua-first Skill neu geschrieben |
| `addons/worldedit_agent/other_files*gui*etc*` | 🔴 RAUS / LEGACY | Platzhalter/Artefakt; entfernen oder korrekt ersetzen |

Wichtig:

`command_agent` darf in 1.1 nicht mehr der Schalter sein, der entscheidet, ob Agentik
existiert. Agentik wird Kernfunktion. Der alte `command_agent` wird nicht weiter
mitgeschleppt und später nur bei Bedarf als Lua-first Skill neu entworfen.

---

## Execution-Pfade

| Pfad | Status | Ziel |
|-----|--------|------|
| JSON Toolcall Dispatch | 🔴 RAUS | Kein Runtime-Fallback mehr; LLM-Output muss Lua sein |
| Direct Lua Execution | 🆕 NEU | Primärarchitektur für 1.1 |
| IDE Execution | 🟠 MODIFIZIEREN | Auf `core_executor.lua` umstellen |
| Agent Execution | 🟠 MODIFIZIEREN | Auf `parser_utils.lua` + `core_executor.lua` umstellen |
| Error Recovery | 🟠 MODIFIZIEREN | Stacktrace/compile error zurück ans LLM; Retry statt Hard-Abbruch |
| Hot Reload | 🟠 MODIFIZIEREN | Idempotent, ohne Registry-/Skill-State-Verlust |

---

## Sandbox / Shadow-G

| Bereich | Status | Ziel |
|--------|--------|------|
| Aktueller IDE-Sandboxpfad | 🟡 KOMPAT-LAYER | Kurzfristig übernehmen, aber nicht duplizieren |
| Blacklist-Ansatz | 🔴 RAUS / LEGACY | Durch Whitelist-Environment ersetzen |
| `_G` Zugriff | 🔴 RAUS / LEGACY | Kein direkter Default-Zugriff für Agent-Code |
| `os`, `io`, `package`, `debug` | 🔴 RAUS / LEGACY | Standardmäßig blockiert |
| `core.*` Zugriff | 🟠 MODIFIZIEREN | Über kontrollierte API-Fassade erlauben |
| `llm_root` | 🟢 BLEIBT | Darf Sandbox-Level/Freigaben steuern |
| `llm_dev` | 🟢 BLEIBT | IDE-/Entwicklerausführung, Policy-gesteuert |
| `llm_agent` | 🟢 BLEIBT | Agentische Ausführung, Policy-gesteuert |

---

## Persistenz

| Bereich | Status | Ziel |
|--------|--------|------|
| `world/llm_scripts/<user>/` | 🆕 NEU | Speicherort für persistente User-Skills/Scripte |
| Erfolgreiche Agent-Funktionen | 🆕 NEU | Können als Skill gespeichert werden |
| Skill-Metadaten | 🆕 NEU | `id`, `label`, `version`, `description`, `permissions`, `source`, `hash`, `created_at`, `updated_at` |
| Automatisches Laden persistenter Skills | 🆕 NEU | Erst nach Root-/Policy-Prüfung aktivieren |
| Rollback/Disable | 🆕 NEU | Persistente Skills müssen deaktivierbar bleiben |

---

## Was fliegt raus?

- `1.0.0` als Release-Ziel.
- JSON-Toolcalls als strategischer Hauptpfad.
- Getrennte Executor-Welten für Agent und IDE.
- User-facing „Addon“-Begriff.
- Blacklist-Sandbox als Sicherheitsmodell.
- `command_agent` als Agentik-Hauptschalter.
- Platzhalterdatei `addons/worldedit_agent/other_files*gui*etc*`.

---

## Was bleibt?

- `llm_api.lua` als Transport-Layer.
- `basic_context.lua` als Basis-Kontext.
- `registry.lua` als zentraler Gateway, aber mit Skill-Erweiterung.
- `main_gui.lua` als Hauptoberfläche.
- `config_gui.lua` als Root-Konfiguration.
- Privilegienmodell: `llm`, `llm_dev`, `llm_agent`, `llm_root`.
- Bestehende Skills als Legacy-/Kompatibilitätsfähigkeiten.

---

## Was wird modifiziert?

- `agent.lua`: JSON-Orchestrator → Direct-Lua-Orchestrator ohne Legacy-Fallback.
- `registry.lua`: Addon-Registry → Skill-/Runtime-Registry mit Persistenz.
- `execution_policy.lua`: Policy-Checker → zentrale Sandbox-/Root-Gate-Instanz.
- `smart_lua_ide/code_executor.lua`: echter Executor → Wrapper/Shim zu `core_executor.lua`.
- `main_gui.lua`: Agent-Modus unabhängig von `command_agent`; Skills-UI konsolidieren.
- `settingtypes.txt`: 1.1-Policy-, Sandbox- und Persistenzsettings ergänzen.

---

## Was entsteht neu?

- `parser_utils.lua`
- `core_executor.lua`
- `registry.skills`
- Direct-Lua-Agentpfad
- Shadow-G Runtime
- Error-Recovery-Loop mit Stacktrace-Reinjection
- persistente Skill-Library unter `world/llm_scripts/<user>/`
- Root-gated Script-Freigabe

---

## Empfohlene Arbeitsreihenfolge

1. `DEPRECATION_MAP.md` aktualisieren. ✅
2. `parser_utils.lua` anlegen.
3. `core_executor.lua` als gemeinsamen Minimal-Executor anlegen.
4. `init.lua` Load-Order erweitern.
5. `smart_lua_ide/code_executor.lua` zum Wrapper/Shim umbauen.
6. `agent.lua` Lua-Block-Extraktion und Executor-Aufruf einbauen.
7. JSON-Toolcall-Agentik entfernen; bestehende Addons später neu als Lua-first Skills schreiben.
8. `registry.lua` idempotent/hotreload-sicher härten.
9. `registry.skills` und Skill-Metadaten ergänzen.
10. Persistenz unter `world/llm_scripts/<user>/` vorbereiten.
11. UI/Settings auf Direct-Lua und Skills-Terminologie nachziehen.
12. `mod.conf` auf `1.1.0-dev` setzen.

---

## Migrationsmarker

Ein File gilt als auf 1.1 migriert, wenn:

- sein Header nicht mehr `LLM Connect 1.0` als aktiven Zielzustand behauptet,
- es keine eigene Executor-Schattenlogik neben `core_executor.lua` einführt,
- es entweder Direct-Lua unterstützt oder explizit als Legacy-Kompatibilität markiert ist,
- sein Sicherheitsverhalten über `execution_policy.lua` / `core_executor.lua` läuft,
- es keine neuen User-facing „Addon“-Begriffe einführt.

