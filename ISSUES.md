
## 1. AGENT_LOOP KONTEXT PROBLEME
- bei anfragen an den agenten keine beschaffung von kontext wegen berechtigungsproblem möglich trotz aktivem command_agent und llm_root
- lokalisierbar vermutlich unter ./agent/agent_retry.lua & ./agent/agent_capabilities.lua
- wenn nicht dort, global die das berechtigungssystem ausgehend von ./agent/agent_init.lua verfolgen
- wenn nicht identifizierbar, konkrete testfälle vom dev anfordern und ~/codex/*.txt einlesen (tracelog) (tracelogs)

## 2. AGENT_LOOP RÜCKFRAGEN / USER-IN-THE-LOOP
- beobachtet beim WorldEdit-Hausbau: das Modell fragt sichtbar nach Details ("Soll ich Fenster/Tür einplanen?"), setzt aber gleichzeitig `continue=true`
- aktuelle Runtime fährt dann direkt mit der nächsten Iteration fort; es gibt keine Pause, keine GUI-Rückfrage und keine Einspeisung der User-Antwort in die Fortsetzung
- TODO: expliziten Await-User-Kontrakt einführen, z. B. `return { done=false, await_user=true, message="..." }`
- TODO: GUI/Agent-Runtime müssen den Lauf bei `await_user=true` pausieren, die Frage anzeigen und die Antwort als Fortsetzungsnachricht wieder in denselben Agent-Kontext einspeisen
- bis dahin sollten Prompts/Skill-Dokumentation Rückfragen innerhalb laufender Aktionen vermeiden und sichere Defaults verwenden
