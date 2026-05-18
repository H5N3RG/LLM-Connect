
## 1. AGENT_LOOP KONTEXT PROBLEME
- bei anfragen an den agenten keine beschaffung von kontext wegen berechtigungsproblem möglich trotz aktivem command_agent und llm_root
- lokalisierbar vermutlich unter ./agent/agent_retry.lua & ./agent/agent_capabilities.lua
- wenn nicht dort, global die das berechtigungssystem ausgehend von ./agent/agent_init.lua verfolgen
- wenn nicht identifizierbar, konkrete testfälle vom dev anfordern und ~/codex/*.txt einlesen (tracelog) (tracelogs)

### Update 2026-05-18: Agent-Loop / Toolstep-Workflow
- [x] Tracelogs unter `~/codex/*.txt` ausgewertet.
- [x] Konkreter Bruch gefunden: Kontext-Lookups ohne Inhalt konnten ein explizites `{done=false, continue=true}` überschreiben und die Schleife mit `reason=no_continuation_requested` beenden.
- [x] `context_registry.lookup()` speichert fehlgeschlagene Lookups jetzt als recent context, damit die nächste Iteration den Fehler sieht.
- [x] `agent_runtime.mark_context_continuation()` respektiert explizites `continue=true` auch bei leeren/fehlgeschlagenen Context-Actions.
- [x] Sichtbarer Text aus Antworten mit `lua_action` wird nicht mehr als finale Antwort aggregiert; er ist Step-/Status-Text.
- [x] `main_gui.lua` hat ein erstes Step-Ledger in der Assistant-Karte.
- [x] `llm_connect.agent.request_permission({...})` ist im Sandbox-Proxy verfügbar; `Permit`/`Deny` Buttons erscheinen bei pending permission und resumieren die Agent-Schleife.
- [ ] Noch offen: echte automatische Permission-Gates an riskanten Weltwrites/Root-ähnlichen Aktionen anbinden. Aktuell ist der Kanal vorhanden, aber Skills/Executor müssen ihn bewusst nutzen.
- [ ] Noch offen: `await_user=true` sauber von `request_permission` trennen. Rückfragen an den User sind semantisch nicht dasselbe wie Sicherheitsfreigaben.
- [ ] Noch offen: Provider-429 robust behandeln. Bei `429 Rate limit exceeded` sollte der Agent nicht nur abbrechen, sondern UI-seitig "rate limited / retry later" anzeigen und ggf. einen resumierbaren Zustand behalten.

### Neuer Befund: isolierte `lua_action`-Blöcke
- LLMs erzeugen teilweise mehrere `lua_action`-Blöcke in einer Antwort und erwarten, dass lokale Variablen aus Block 1 in Block 2 existieren (`center_pos`, `operations`, etc.).
- Tatsächlich wird jeder Block separat kompiliert/ausgeführt; lokale Variablen gehen verloren.
- TODO Prompt: explizit formulieren, dass jeder `lua_action`-Block isoliert ist. Gemeinsamer Zustand muss in einem Block bleiben oder über Returned Data/History erneut aufgebaut werden.
- TODO Parser/Runtime: optional warnen, wenn mehrere Action-Blöcke in einer Antwort vorkommen und der spätere Block offensichtliche freie Variablen nutzt.
- Architekturentscheidung festhalten: siehe `docs/dev/ROADMAP.md`, Abschnitt "1.5.0 Agent Action Language". Ziel ist ein Hybrid: Lua bleibt Runtime, das Modell soll bevorzugt deklarative Action-Specs statt freie Lua-Algorithmen erzeugen.
- 2.0-Leitplanke: siehe `docs/dev/ROADMAP.md`, Abschnitt "2.0.0 Luanti-First Maturity". Bis zu stabilem Multi-Skill-Workflow und ausgereifter Smart-Lua-IDE bleibt LLM-Connect Luanti-fokussiert; keine generische Voxel-Engine-Architektur und keine Minecraft-Port-Abstraktionen vor 2.0.

## 2. AGENT_LOOP RÜCKFRAGEN / USER-IN-THE-LOOP
- beobachtet beim WorldEdit-Hausbau: das Modell fragt sichtbar nach Details ("Soll ich Fenster/Tür einplanen?"), setzt aber gleichzeitig `continue=true`
- aktuelle Runtime fährt dann direkt mit der nächsten Iteration fort; es gibt keine Pause, keine GUI-Rückfrage und keine Einspeisung der User-Antwort in die Fortsetzung
- TODO: expliziten Await-User-Kontrakt einführen, z. B. `return { done=false, await_user=true, message="..." }`
- TODO: GUI/Agent-Runtime müssen den Lauf bei `await_user=true` pausieren, die Frage anzeigen und die Antwort als Fortsetzungsnachricht wieder in denselben Agent-Kontext einspeisen
- bis dahin sollten Prompts/Skill-Dokumentation Rückfragen innerhalb laufender Aktionen vermeiden und sichere Defaults verwenden

## 3. VERALTETE SKILLS

1. command_agent:
- capabilities zur nativen kommunikation mit der runtime und dem core_executor nicht annähhrend ausgereift genug
- skill ist selber noch ein modifiziertes artefakt aus der json-zeit des projektes (deprecated)
- idee: das erstetzen der bisherigen in-game-command wrapper funktionalität durch echte, systemnahe primitive, durch die der agent validen luacode in der runtime ausführen kann, ohen auf die chatcommand-bschränkungen angewiesen zu sein
- suche noch nach präzisen implementierungsvorschlägen

2. worldedit_agent :

- dient als wrapper/bridge zum bestehenden wordedit mod
- idee: komplett neuschreiben als dediziertes nodemanipulationsinstrument für den agenten.
- architekturimpuls: der wie im command agent soll das modell in einem infezenzschritt '3d-drucker' artig komplexe konstrukte erzeugen können, nähere architektur noch zu erläutern (zb. lua tables mit auflistung nebeneinanderliegender zu erzeugender einzelnodes, nodereihen oder nodequader als primitive

---

# Bei unklarheiten zu Issue nummer 3. direkt rückfragen oder um präzisierung bitten, ggf eigene Ideen einbringen

---

## Neuer Abschnitt: Mapgen Helper (Low-Level Painter)

**Ziel:** Dem LLM möglichst direkte, low-level Kontrolle über die Weltgenerierung geben – wie ein "Mapgen Painter".

### Kern-Features
- [ ] Singlenode-Welt + eigener Mapgen Environment (Luanti 5.9+)
- [x] Prototyp-Skill `skills/mapgen_painter/` als Lua-first Skill-Gateway
- [x] Low-Level DSL / Parser für LLM-Befehle (`fill`, `set_node`, `replace_area`, `carve_cave`, `add_noise_layer`, ...)
- [x] Basis-Parser + Validation + Node-Resolver
- [x] Persistente Request-Queue über Mod-Storage
- [x] VoxelManip-basiertes Ausführen der Paint-Operationen im Mapgen-Callback
- [ ] Base-Noise Setup (Höhe, Caves, Grund-Terrain)
- [ ] Kohärenz über Chunk-Grenzen hinweg (Feature-Merging)
- [ ] Automatische Chunking-/Tiling-Strategie für große Landschaftswünsche

### Technische Details
- Parser soll sowohl strukturierten Lua-Table-Code als auch natürlichsprachige + Code-Mixe verstehen
- Starke Validation + Safety-Limits (max Größe, Rate-Limiting)
- Executor arbeitet pro Chunk mit `get_mapgen_object("voxelmanip")`
- Später: Live-Terraforming (nach initialer Generierung)

### Update 2026-05-18: Prototyp-Status / Logs
- Skill lädt erfolgreich und registriert Kontextsektion `skills.mapgen_painter`.
- API aktuell: `run("preview"|"queue"|"list"|"clear", args, player_name)`, plus direkte `preview`, `queue`, `list_requests`, `clear_requests`.
- Unterstützte Operationen: `set_node`, `fill`, `replace_area`, `carve_cave`, `add_noise_layer`.
- Safety-Limit im Prototyp: `max_operation_volume = 4096`, `max_request_volume = 32768`, `max_operations_per_request = 64`.
- Logbefund: Modell erfindet nicht existierende API `mapgen_painter.init_region`.
- Logbefund: Modell plant viel zu große Operationen (`fill volume 316231 exceeds max_operation_volume=4096`).
- Logbefund: Modell beschreibt "zylinderförmiges Plateau", nutzt aber eine rechteckige `fill`-Box; Geometrie-Primitive fehlen.
- TODO Kontextmanual härten: direkt am Anfang konkrete API + Limits + "keine init_region API" nennen.
- TODO `preview` sollte bei übergroßen Operationen konkrete Reparaturhinweise zurückgeben: "teile in N Operationen mit max Kantenlänge ..." statt nur Fehler.
- TODO höhere Primitive erwägen: `cylinder`, `disc`, `sphere/ellipsoid`, `river_path`, `heightmap_patch`, `noise_mountain`, die intern in sichere Low-Level-Ops/Chunks expandieren.
- TODO bei großflächigen Queue-Requests automatisch `permission_required` triggern.

### Risiken / Offene Fragen
- Performance bei zu vielen low-level Operationen
- Chunk-übergreifende Features sauber mergen
- Wie granular darf das LLM wirklich werden, ohne Lag zu erzeugen?
- Undo / Backup Mechanismus für experimentelle Mapgen-Sessions
- Wie stark soll der Skill Low-Level bleiben, wenn das LLM für komplexe Landschaften eigentlich höhere, validierte Primitive braucht?
- Wie viel Autonomie ist akzeptabel, bevor zwingend Permit/Deny nötig ist?
