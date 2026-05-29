# LLM-Connect

LLM-Connect is a Lua-first AI agent framework for Luanti (formerly Minetest) that enables natural language interaction with the game world through a dual-channel architecture.

## 🔧 Current Version: 1.2.0-dev

## 🏗️ Architecture

LLM-Connect follows a **Lua-first dual-channel agent model**:

1. **Visible Channel**: Normal chat responses shown to players
2. **Hidden Channel**: Lua action execution through marked `lua_action` blocks

### Core Principles

- Normal chat remains visible plain text
- Tool/action execution happens through hidden `lua_action` blocks
- All runtime execution flows through `core_executor.lua`
- Skills are loaded through `registry.lua`
- `agent.lua` acts as an orchestrator instead of direct command executor
- `basic_context.lua` provides lightweight runtime context

### Runtime Pipeline

```text
main_gui.lua
    ↓
agent.lua (orchestrator)
    ↓
parser_utils.lua (extracts lua_action blocks)
    ↓
core_executor.lua (secure Lua execution)
    ↓
Luanti Engine
```

## 📦 Major Components

### agent.lua
Dual-channel orchestrator managing:
- Visible assistant chat
- Hidden Lua action execution
- Optional iterative task execution

### parser_utils.lua
Handles:
- Extracting `lua_action` blocks from LLM responses
- Stripping hidden actions from visible output
- Preparing execution-safe Lua payloads

### core_executor.lua
Central runtime execution layer providing:
- Sandbox execution
- Runtime pre-checks
- Protected execution
- Shared backend for agent + IDE

### registry.lua
Lua-first skill registry that:
- Registers active skills
- Injects skill schemas/context
- Manages internal Lua-first skills

### basic_context.lua
Provides:
- Lightweight player/server state
- Runtime-safe Lua guidance
- Optional advanced registry information

## 🛠️ Current Internal Skills

- `command_agent` - Executes chat commands
- `worldedit_agent` - WorldEdit building operations with high-level primitives

## 🔄 IDE Persistence / Hot-Reload

The Smart Lua IDE uses the flat runtime storage service:
- Single backend: `world/llm_scripts/<player>/scripts/`
- `Run`: Transient execution
- `Save`: Manual persistence through active backend
- `Hot Reload`: Saves and executes runtime-safe scripts

## 📚 Documentation

Detailed developer documentation is available in the [`docs/dev/`](docs/dev/) directory:
- [PATCH_AGENDA_CONTEXT_ORCHESTRATION.md](docs/dev/PATCH_AGENDA_CONTEXT_ORCHESTRATION.md) - Context/WorldEdit orchestration stabilization
- [PLAN_OPTIONS.md](docs/dev/PLAN_OPTIONS.md) - Architectural decisions needing user approval
- [TESTS.md](docs/dev/TESTS.md) - Testing guidelines
- [CODEX.md](docs/dev/CODEX.md) - Reference documentation

## ⚙️ Chat Commands

- `/llm` - Open LLM Connect chat interface
- `/llm_config` - Open configuration GUI
- `/llm_health` - Show subsystem health status
- `/llm_skill_list` - List skills for a player (root)
- `/llm_skill_attach` - Attach/detach skills for a player (root)
- `/llm_trace` - Open live trace panel (root)
- `/llm_config_reload` - Reload configuration without restart
- `/llm_startup_reload` - Re-execute llm_startup.lua at runtime

## 🔐 Privileges

- `llm` - Access to LLM Connect AI chat
- `llm_dev` - Access to Smart Lua IDE and sandboxed code execution
- `llm_agent` - Access to LLM Connect agent mode and skill tools
- `llm_root` - Full LLM Connect access (implies llm, llm_dev, llm_agent)

## 📝 License

LGPL-3.0-or-later

## 👨‍💻 Author

H5N3RG
