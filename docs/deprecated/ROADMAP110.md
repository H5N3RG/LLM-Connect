--- PROJECT_ROOT/ROADMAP110.md (PROPOSED)
+++ PROJECT_ROOT/ROADMAP110.md (REFACTORED)
@@ -0,0 +1,75 @@
+# Roadmap LLM-Connect v1.1.0 "Voyager-Infiltration"
+
+## 1. Kern-Paradigma: Von JSON zu Direct-Lua
+Das bisherige System der JSON-basierten Tool-Calls wird vollständig ersetzt.
+* ALT: LLM sendet JSON -> Parser übersetzt in vordefinierte Lua-Aktionen.
+* NEU: LLM sendet direkten Lua-Code -> Injektion via Code-Executor in die Engine.
+* ZIEL: "Voyager"-Prinzip (Agent schreibt Code, um Probleme in der Engine zu lösen).
+
+## 2. Struktur-Refactoring (The "Shared Backend")
+Verschmelzung von IDE-Logik und Agenten-Logik zu einem einheitlichen Backend.
+
+* /root/core_executor.lua: Zentrale Instanz für Code-Ausführung und Sandbox (Shadow-G).
+* /root/registry.lua: Persistenter State-Store, Idempotenz-Schutz beim Hot-Reload.
+* /root/parser_utils.lua: Robuster Regex-Parser zur Extraktion von Lua-Blöcken aus LLM-Antworten.
+* /agent/agent.lua: LLM-Interface (extrahiert Lua-Content und reicht ihn an core_executor weiter).
+* /smart_lua_ide/: Nur noch Frontend/GUI-Logik; nutzt für Ausführung den core_executor.
+
+## 3. Implementierungs-Phasen
+
+### Phase 1: Backend-Härtung (Grok-Fokus)
+* Implementierung des Regex-basierten Lua-Parsers in parser_utils.lua.
+* Umbau der registry.lua: Schutz vor Datenverlust bei Hot-Reloading (Idempotenz).
+* Etablierung des Error-Recovery-Loops: Lua-Stacktraces werden bei Fehlern direkt an das LLM zurückgereicht.
+
+### Phase 2: Die Skill-Library (Voyager-Kern)
+* Aufbau von 'llm_connect.registry.skills' in der registry.lua.
+* Ermöglichung der Selbstreferenz: Das LLM definiert Funktionen, speichert sie und ruft sie in späteren Turns wieder auf.
+* Persistenz: Speicherung erfolgreicher "Skills" in world/llm_scripts/<user>/.
+
+### Phase 3: Sandbox & Shadow-G
+* Definition einer sicheren, aber mächtigen Umgebung.
+* Voller Zugriff auf core.* (Luanti-API).
+* Striktes Blockieren von Host-Zugriffen (os.*, io.*, package.*).
+* Root-Gated Execution: Optionale Freigabepflicht durch den Admin vor der ersten Code-Ausführung neuer Scripte.
+
+## 4. Langzeit-Ziel: Entity-Control-Addon
+Nach Release von 1.1.0 wird ein externes Addon für 'mobs_redo' entwickelt.
+* Flow: llm_connect -> entity_control_addon -> mobs_redo_api.
+* Integration über das neue register_addon() Interface in der registry.lua.
+* LLM agiert als "Gehirn", das High-Level-Befehle via Lua-Injektion an NPCs sendet.
+
+## 5. Technische Handshakes (llm_api.lua)
+* Trennung von Transport (JSON-Wrapper für OpenAI/Ollama) und Inhalt (Lua-Core).
+* llm_api.lua kümmert sich um den API-Dialog.
+* agent.lua kümmert sich um die inhaltliche Code-Extraktion.
+
+---
+Status: Planungsphase abgeschlossen. Bereit für Implementierung der core_executor-Logik.
+Verantwortlich: Jan (Root/Architekt), Grok (Backend-Dev), Gemini (State-Review/Patterns).