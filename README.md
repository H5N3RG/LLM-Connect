# LLM-Connect

LLM-Connect is a Lua-first AI agent framework for Luanti (formerly Minetest).

## Current Architecture Direction (1.1.0-dev)

The project has transitioned away from the previous JSON-centric command architecture and now follows a Lua-first dual-channel agent model.

### Core Principles

- Normal chat responses remain visible plain text.
- Tool / action execution happens through hidden `lua_action` blocks.
- All runtime execution flows through `core_executor.lua`.
- Skills are loaded through `registry.lua`.
- `agent.lua` acts as an orchestrator instead of a direct command executor.
- `basic_context.lua` now focuses on lightweight runtime context instead of massive command dumps.

## Core Runtime Pipeline

```text
main_gui.lua
    ↓
agent.lua
    ↓
parser_utils.lua
    ↓
core_executor.lua
    ↓
Luanti Engine
```

## Major Components

### agent.lua

Dual-channel orchestrator:

- visible assistant chat
- hidden Lua action execution
- optional iterative task execution

### parser_utils.lua

Responsible for:

- extracting `lua_action` blocks
- stripping hidden actions from visible output
- preparing execution-safe Lua payloads

### core_executor.lua

Central runtime execution layer:

- sandbox execution
- runtime pre-checks
- protected execution
- shared execution backend for agent + IDE

### registry.lua

Lua-first skill registry:

- registers active skills
- injects skill schemas/context
- manages internal Lua-first skills

### basic_context.lua

Provides:

- lightweight player/server state
- runtime-safe Lua guidance
- optional advanced registry information

## Current Internal Skills

- `command_agent`
- `worldedit_agent`

## Status

The framework is currently in an active architectural transition toward:

- Lua-native agent execution
- deterministic runtime orchestration
- future hot-reload support
- persistent runtime skills
- reduced prompt/context bloat

Version:

`1.1.0-dev`


### IDE persistence / hot-reload

The Smart Lua IDE now uses a storage bridge instead of writing directly to legacy snippets/startup files:

- default backend: `world/llm_scripts/<player>/` via `runtime_scripts.lua`;
- root-only optional backend slot: trusted standalone worldmods via `trusted_mods.lua`;
- `Run` is transient execution;
- `Save` is manual persistence through the active backend;
- `Hot Reload` saves and executes only runtime-safe scripts;
- startup-preferred registrations are saved, but require/recommend restart.

The agent path does not persist code.

