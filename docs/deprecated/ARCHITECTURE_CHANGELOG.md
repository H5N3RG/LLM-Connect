# ARCHITECTURE_CHANGELOG


## 2026-05-10 — IDE Hot-Reload Storage Backend Pass

Implemented the first concrete IDE hot-reload/persistence layer:

- Added `runtime_scripts.lua` as the default `world/llm_scripts/<player>/` backend.
- Added `smart_lua_ide/ide_storage.lua` as a thin persistence backend bridge.
- Historical note: `trusted_mods.lua` existed as a conservative root-only Trusted Worldmod backend slot; it has since been removed for Luanti 5.16+ compatibility.
- Added root-only IDE backend switch: `LLM Runtime` ⇄ `Trusted Worldmod`.
- Added a small `Files...` subformspec instead of introducing a second IDE UI.
- Added IDE `Hot Reload` action:
  - runtime-safe scripts: save + execute;
  - startup-preferred registrations: save, but do not live-reload;
  - trusted worldmods: save-only, restart recommended; live-reload disabled in v1.
- Moved persistence responsibility out of `core_executor.lua`.
- Removed automatic append-to-`llm_startup.lua` side effects from execution.
- `core_executor.lua` now classifies code and returns semantic result flags such as `script_class`, `hot_reloadable`, and `requires_restart`.

Design boundary preserved:

- Agent skills do not persist code.
- IDE persistence is manual.
- Default generated registrations remain under `llm_connect:*`.
- Standalone mod editing is prepared as a separate root-only backend, not merged into the normal hot-reload path.

## Overview

This document summarizes the major architectural transition from the unfinished `1.0.0-dev` branch toward the new `1.1.0-dev` Lua-first runtime architecture.

---

## Major Architectural Shift

### Previous Model

```text
LLM
→ JSON Tool Calls
→ Registry Parsing
→ Chatcommand Execution
→ Engine
```

### New Model

```text
LLM
→ Lua-first dual-channel responses
→ parser_utils.lua
→ core_executor.lua
→ Engine Runtime
```

---

## Major Changes

### 1. JSON-Centric Architecture Deprecated

The former JSON-based tool execution pipeline has been deprecated.

Removed concepts:

- mandatory JSON tool calls
- JSON response parsing as primary runtime format
- chatcommand-first orchestration
- forced Lua-only response behavior

The system is now Lua-first.

---

### 2. Introduction of core_executor.lua

A new central execution layer was introduced.

Responsibilities:

- sandbox execution
- runtime validation
- protected execution
- pre-check environments
- shared execution backend
- execution result normalization

All execution paths now flow through this layer.

---

### 3. parser_utils.lua Introduced

New parsing layer responsible for:

- extracting `lua_action` blocks
- stripping hidden actions from visible assistant output
- dual-channel response parsing
- future repair/normalization support

This replaced older fragmented parsing logic.

---

### 4. agent.lua Rewritten

The agent was redesigned from:

- iterative Lua-only execution loop

into:

- dual-channel orchestrator

The agent now supports:

- visible assistant chat
- hidden runtime actions
- optional iterative execution
- skill-aware prompting

The new response model:

```text
Visible Chat
+
Hidden lua_action blocks
```

---

### 5. main_gui.lua Routing Changes

The GUI no longer forces all privileged users into agent loops.

New behavior:

- plain chat remains plain chat
- skills enable runtime actions
- dual-channel rendering support

---

### 6. registry.lua Refactor

The registry was converted into a Lua-first skill registry.

Changes:

- internal Lua-first skill loading
- explicit skill registration
- metadata normalization
- default-disabled skills
- removal of legacy addon assumptions

Current internal skills:

- `command_agent`
- `worldedit_agent`

---

### 7. basic_context.lua Modernized

The old context system heavily emphasized:

- command dumps
- chatcommand awareness

The new version focuses on:

- lightweight runtime state
- Lua runtime guidance
- reduced prompt bloat
- optional advanced registry context

Command-heavy context was intentionally reduced.

---

### 8. Skills Default State Changed

Skills are now:

- loaded
- visible

but not automatically active.

Explicit activation is required.

---

### 9. IDE Execution Path

`smart_lua_ide/code_executor.lua` was deprecated and replaced with `core_executor.lua`.

The IDE now shares the same runtime backend as the agent system.

---

### 10. Dual-Channel Runtime Introduced

The system now distinguishes between visible assistant text and hidden runtime actions.

Visible assistant text is shown to the player.

Hidden runtime actions are executed internally through fenced `lua_action` blocks:

````markdown
```lua_action
-- Lua code here
```
````

This architecture significantly reduced accidental parsing failures.

---

## Current Known Limitations

### Hot Reload

Runtime registration of nodes/items/entities after load time is still limited by Luanti engine behavior.

Future work:

- `llm_root` hot reload
- runtime persistence pipeline
- staged runtime module injection

### Spatial Intelligence

The current agent can build simple structures, but the following still need improvement:

- architectural planning
- advanced geometry
- semantic room layouts

### Context Intelligence

Future work:

- richer Lua runtime schemas
- node capability descriptions
- dynamic engine introspection
- planner/executor separation

---

## Result

The framework now behaves significantly more like a modern agent runtime and less like a chatcommand wrapper.

Observed improvements:

- fewer parsing failures
- more stable WorldEdit execution
- cleaner runtime separation
- reduced prompt pollution
- improved spatial behavior

Version target:

`1.1.0-dev`
