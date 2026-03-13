# agent.lua — Architektur & Design

Dieses Dokument beschreibt die Konzeption von `agent.lua` bevor die
Implementierung beginnt. Es definiert was der Agent tut, wie er mit
anderen Modulen kommuniziert, wie flexibel er ist, und wie das
Loop-Modell im Vergleich zu bestehenden KI-Agentensystemen aussieht.

---

## 1. Was ist der Agent?

Der Agent ist eine **autonome Ausführungsmaschine**, die zwischen dem
LLM und der Spielwelt vermittelt. Er übersetzt natürlichsprachliche
Ziele in Folgen von Werkzeugaufrufen — und reagiert auf deren Ergebnisse.

Er ist **nicht** zuständig für:
- die HTTP-Kommunikation mit dem LLM (→ `llm_api.lua`)
- die konkrete Implementierung von Spielaktionen (→ Addons)
- die Darstellung im UI (→ `main_gui.lua`)
- das Laden und Registrieren von Addons (→ `registry.lua`)

Er ist **zuständig** für:
- das Zusammenstellen des Tool-Manifests aus allen aktiven Addons
- das Aufbauen des Systemprompts (Kontext + Tool-Manifest + Ziel)
- das Senden der Anfrage an `llm_api`
- das Parsen der LLM-Antwort (`plan`, `tool_calls`, `done`, `reason`)
- das Dispatchen jedes `tool_call` an das verantwortliche Addon
- das Sammeln der Ergebnisse und Entscheiden ob weitergemacht wird
- das Aufrufen von Snapshot/Undo vor jeder Ausführungskette
- das Streamen von Zwischenergebnissen zurück an die GUI via Callbacks

---

## 2. Kommunikation mit anderen Modulen

```
main_gui.lua
    │
    │  agent.run(player_name, goal, options, callbacks)
    ▼
agent.lua  ◄──────────────────────────────────┐
    │                                          │
    │  llm_api.request(messages, cb, opts)     │
    ▼                                          │
llm_api.lua  (HTTP → LLM Provider)            │
    │                                          │
    │  result: {success, content}              │
    ▼                                          │
agent.lua  (parse JSON → tool_calls[])        │
    │                                          │
    │  registry.dispatch(addon_id, tool, args, player)
    ▼                                          │
registry.lua  ──►  addon.dispatch(...)        │
                       │                      │
                       │  {ok, message, data} │
                       └──────────────────────┘
                   (result fed back into loop)
```

### Schnittstellen im Detail

**`agent.run(player_name, goal, options, callbacks)`**
Der einzige öffentliche Einstiegspunkt. Alles andere ist intern.

```lua
-- options:
{
    max_iterations = 8,          -- Loop-Limit (default aus settings)
    timeout        = 120,        -- pro LLM-Anfrage
    mode           = "loop",     -- "single" | "loop" (default: "loop")
    addon_filter   = nil,        -- nil = alle, oder {"worldedit", "mobs_redo"}
    snapshot       = true,       -- Snapshot vor erster Ausführung
}

-- callbacks:
{
    on_step    = function(step_nr, plan, results) end,  -- nach jeder Iteration
    on_done    = function(result) end,                   -- am Ende
    on_error   = function(err) end,                      -- bei hartem Fehler
}
```

**`registry.get_manifest(addon_filter)`**
Gibt alle aktiven Tool-Definitionen als flache Liste zurück.
Der Agent ruft das einmal pro `run()`-Aufruf auf — nicht pro Iteration.

**`registry.dispatch(tool_name, args, player_name)`**
Findet das zuständige Addon anhand des Tool-Namens und ruft dessen
`dispatch()` auf. Gibt `{ok, message, data}` zurück.
Namenskollisionen werden beim Laden erkannt und geloggt (erstes Addon gewinnt).

**`basic_context.lua`**
Liefert spielerspezifischen Basiskontext: Position, HP, aktive Mods,
Server-Info. Wird vom Agent pro Iteration frisch abgerufen (dynamisch).

---

## 3. Das Loop-Modell — inspiriert von OpenCode / Claw-Agenten

Das bestehende WorldEdit-Loop-System war ein guter erster Schritt.
Die neue Agent-Loop ist davon inspiriert, aber generalisiert und an
moderne KI-Agenten-Patterns angelehnt.

### Vergleich: alt vs. neu

| Aspekt | Alt (`llm_worldedit.lua`) | Neu (`agent.lua`) |
|--------|--------------------------|-------------------|
| Tool-Scope | Nur WorldEdit-Dispatcher | Beliebige Addons via Registry |
| Kontext | WE-spezifisch (pos1/pos2, env-scan) | Generisch + Addon-Context-Hooks |
| Iterations-Limit | `we_max_iterations` | `llm_agent_max_iterations` |
| Token-Budget | O(1): nur letzte Steps | O(1): identisch, kompakte History |
| Abort-Bedingungen | done=true, Fehler, max | + stuck-detection, budget-guard |
| Snapshot | per-WE-Chain | generisch im Agent vor jeder Chain |
| Feedback an UI | `on_step` Callback | `on_step` + `on_thought` Callback |
| `done`-Signal | LLM setzt `done: true` | identisch |
| Fehlerbehandlung | Chain-Abort bei hartem Fehler | identisch + Retry-Hook pro Addon |

### Loop-Ablauf (Pseudo-Code)

```
run(player_name, goal, options, callbacks):

  manifest   = registry.get_manifest(options.addon_filter)
  context    = basic_context.get(player_name)
              + addon_contexts(manifest, player_name)   ← NEU: Addons dürfen Kontext beisteuern
  snapshot   = agent.take_snapshot(player_name)        ← generisch, nicht WE-spezifisch

  iteration  = 0
  history    = []                                      ← kompakte Step-History, O(1) tokens

  loop:
    iteration += 1
    if iteration > max_iterations → done(reason="max reached")

    system_msg = build_system_prompt(manifest, context)
    user_msg   = build_user_msg(goal, history)          ← Step 1: nur goal. Danach: goal + history

    llm_api.request([system_msg, user_msg]) → response

    parse response:
      plan       = response.plan
      tool_calls = response.tool_calls    ← [{ tool, args }, ...]
      done       = response.done
      reason     = response.reason
      thought    = response.thought       ← NEU: optionaler Reasoning-Text (für UI)

    callbacks.on_step(iteration, plan, [])  ← sofort, damit UI "denkt..." zeigt

    results = []
    for each tool_call:
      result = registry.dispatch(tool_call.tool, tool_call.args, player_name)
      results.append(result)
      if hard_error(result): break + abort

    callbacks.on_step(iteration, plan, results)  ← update mit echten Ergebnissen

    history.append({ iteration, plan, results })

    stuck = detect_stuck(history)   ← NEU: 2x identischer Plan ohne Fortschritt → abort

    if done or hard_error or stuck:
      callbacks.on_done(final_result)
      return

    context = basic_context.get(player_name)  ← Kontext nach jeder Iteration neu holen
             + addon_contexts(manifest, player_name)

  end loop
```

### Neu gegenüber dem bestehenden System: `thought` und `on_thought`

Moderne Agentensysteme (OpenCode, Claude Code, Claw) trennen zwischen
*Reasoning* (was der Agent denkt) und *Action* (was er tut).
Wir unterstützen das optional:

```json
{
  "thought": "Der Spieler möchte ein Haus. Ich fange mit dem Boden an.",
  "plan":    "Schritt 1/4: 10x10 Steinboden setzen",
  "tool_calls": [...],
  "done": false
}
```

`thought` wird **nicht** in die History aufgenommen (kein Token-Overhead),
aber per `on_thought(text)` Callback an die GUI weitergegeben — dort kann
man es als kursiven "Denkt..." Text anzeigen oder ignorieren.

### Stuck-Detection

Wenn zwei aufeinanderfolgende Iterationen denselben `plan`-Text und
dieselbe Fehlerstruktur haben, ist der Agent feststeckend.
→ Loop-Abbruch mit `reason = "stuck: LLM repeated identical failing plan"`.

---

## 4. Flexibilität — was der Agent kann und nicht kann

### Was er **kann**:

- **Beliebige Tool-Kombinationen pro Schritt** — ein Step kann gleichzeitig
  WorldEdit-Calls und mobs_redo-Calls enthalten, wenn beide Addons aktiv sind
- **Addon-spezifischen Kontext** — jedes Addon kann optional eine
  `get_context(player_name)` Funktion exportieren; der Agent injiziert
  alle in den Systemprompt
- **Single-shot Modus** — `mode="single"` macht genau eine LLM-Anfrage,
  kein Loop. Sinnvoll für einfache Ziele oder wenn der Nutzer die Kontrolle
  behalten will
- **Addon-Filter** — `addon_filter={"worldedit"}` schränkt das Tool-Manifest
  auf ein Addon ein; nützlich wenn der Nutzer gezielt nur WE nutzen will
- **Run-Chat-Command als Built-in** — generischer Fallback-Dispatcher direkt
  im Agent (kein Addon nötig) für einfache Chatbefehle
- **Erweiterbare Abort-Bedingungen** — `options.abort_on` kann zusätzliche
  Abbruchbedingungen injizieren (z.B. "stop wenn Spieler stirbt")

### Was er bewusst **nicht** kann:

- **Parallele Ausführung** — Tool-Calls eines Steps werden sequenziell
  ausgeführt. Kein async-Parallelismus (Luanti HTTP ist ohnehin single-threaded)
- **Persistente Memory** — der Agent erinnert sich nicht an vorherige
  `run()`-Aufrufe. State lebt nur innerhalb eines Laufs
- **Selbstmodifikation** — der Agent kann keine neuen Tools registrieren
  oder Addon-Code schreiben. Das ist Aufgabe der IDE
- **Multi-Player Koordination** — jeder Spieler hat seinen eigenen
  unabhängigen Agent-Kontext

---

## 5. Snapshot & Undo — generisch

Der Agent besitzt einen spielergebundenen Snapshot-Store.
Addons delegieren Snapshot-Anfragen an den Agent — sie kümmern sich
nicht selbst darum.

```lua
-- Vor jeder Ausführungskette:
agent.snapshot(player_name)   →  speichert addon-spezifische Undo-Daten
                                  (jedes Addon mit undo-Support registriert
                                   einen snapshot_hook und restore_hook)

-- Spieler ruft Undo auf:
agent.undo(player_name)       →  ruft alle restore_hooks auf
```

WorldEdit liefert seinen eigenen Snapshot-Mechanismus (WE-serialize).
mobs_redo könnte z.B. eine Liste der gespawnten Entity-IDs speichern.
Addons ohne Undo-Support registrieren einfach keinen Hook.

---

## 6. Kommunikation: `registry.lua` als Mittler

`agent.lua` spricht **nie direkt mit Addons**. Immer über `registry.lua`.

```
agent.lua
    registry.get_manifest()    → [{id, label, tools[]}, ...]
    registry.dispatch(tool, args, player)  → {ok, message, data}
    registry.get_contexts(player)          → string (alle Addon-Kontexte)
    registry.snapshot(player)             → ruft alle snapshot_hooks
    registry.undo(player)                 → ruft alle restore_hooks
```

Das bedeutet: `agent.lua` muss **nie** geändert werden wenn ein neues
Addon hinzukommt. Nur `registry.lua` weiß welche Addons existieren.

---

## 7. LLM Response Format (Ziel-Schema)

Das LLM wird per Systemprompt auf dieses JSON-Schema trainiert:

```json
{
  "thought":    "(optional) kurzer Reasoning-Text, nicht in History",
  "plan":       "Einzeiler was dieser Schritt tut — geht in History",
  "tool_calls": [
    { "tool": "tool_name", "args": { "key": "value" } }
  ],
  "done":   false,
  "reason": "(optional) nur wenn done=true: warum fertig oder abgebrochen"
}
```

Alle anderen Felder werden ignoriert (forward-compatible).
JSON-Parsing ist tolerant gegenüber Markdown-Fences (wie bisher).

---

## 8. Dateistruktur nach Fertigstellung

```
llm_connect/
├── agent.lua               ← dieser Entwurf
├── agent_system_prompts.lua ← Prompt-Builder (generisch + tool-manifest-serializer)
├── registry.lua            ← Addon-Loader, dispatch, context-aggregation
├── basic_context.lua       ← Spieler-Basiskontext (pos, hp, mods, server)
├── main_gui.lua            ← UI: zeigt on_step / on_thought / on_done
├── llm_api.lua             ← unverändert
├── config_gui.lua          ← erweitert um Agent-Settings
├── init.lua                ← lädt alles in der richtigen Reihenfolge
└── addons/
    ├── worldedit_agent/
    │   └── worldedit_agent.lua   ← exportiert: available, tools, dispatch,
    │                                            get_context, snapshot_hook, restore_hook
    ├── smart_lua_ide/            ← Sonderstellung, nicht via registry
    │   └── ...
    └── mobs_redo/
        └── mobs_redo.lua         ← exportiert: available, tools, dispatch
```

---

## 9. Nächster Schritt

Mit diesem Design steht die Grundlage. Der nächste konkrete Schritt ist
`agent.lua` als Skelett: alle Funktionssignaturen, der Loop-Rahmen,
Stub-Implementierungen für Snapshot/Undo und Dispatch — aber noch ohne
echte Addon-Aufrufe. Die Logik läuft, Tools werden geloggt statt ausgeführt.
