# LLM Connect

**A Luanti (formerly Minetest) mod that integrates Large Language Models (LLMs) directly into the game with an AI-powered Lua IDE and building assistant.**

![License](https://img.shields.io/badge/license-LGPL--3.0--or--later-blue)

---

## 🌟 Overview

LLM Connect brings modern AI assistance into Luanti worlds.
Players and developers can interact with a Large Language Model directly in-game to:

- ask questions
- generate Lua code
- analyze or refactor scripts
- assist with WorldEdit building tasks
- experiment with sandboxed Lua execution

The mod combines an **AI chat interface**, a **Smart Lua IDE**, and **LLM-assisted building tools** into a single integrated workflow.

---

## ✨ Core Features

### 🤖 AI Chat Interface

Interact with a Large Language Model directly inside Luanti.

Features include:

- In-game chat GUI
- conversation context handling
- player and world information awareness
- configurable prompts and system instructions
- support for OpenAI-compatible APIs

The chat system automatically includes contextual information such as:

- player position
- installed mods
- selected materials
- server environment

---

### 💻 Smart Lua IDE

LLM Connect includes a fully integrated **AI-assisted Lua development environment**.

Capabilities include:

- AI code generation from natural language prompts
- semantic code explanation
- automated refactoring
- code analysis
- interactive editing interface with file manager
- save/load Lua snippets per world
- integration with the game environment

Developers can experiment with Lua snippets directly inside the game.

---

### 🧪 Sandboxed Code Execution

Lua code can be executed inside a controlled environment.

Security features include:

- privilege-based execution access
- sandboxed runtime
- optional whitelist restrictions
- prevention of filesystem access

Execution results are returned to the IDE interface for inspection.

---

### 🏗️ WorldEdit AI Assistant

LLM Connect can assist with building tasks using WorldEdit.

Examples:

- structure generation prompts
- building suggestions
- node/material selection
- architectural transformations

The system can combine:

- player position
- selected materials
- worldedit context

to produce context-aware instructions.

---

### 🧱 Material Selection Tools

The mod includes a **material picker** interface that helps the AI understand:

- available nodes
- building palettes
- player selections

This improves the quality of building-related prompts.

---

## 🔐 Permission System

Access to AI features is controlled through Luanti privileges.

| Privilege | Description |
|-----------|-------------|
| `llm` | Basic AI chat access |
| `llm_dev` | Smart Lua IDE + sandboxed code execution |
| `llm_worldedit` | WorldEdit agency (Single + Loop mode, material picker) |
| `llm_root` | Full administrative access — implies all privileges above + config + unrestricted execution |

Server operators should grant privileges carefully.

> **Note:** `llm_root` is a superrole. Granting it implies `llm`, `llm_dev`, and `llm_worldedit`.

---

## 📋 Requirements

- Luanti server **5.4.0 or newer recommended**
- HTTP API enabled
- Access to a compatible LLM endpoint

Supported providers include:

- OpenAI
- Ollama
- LM Studio
- LocalAI
- Open WebUI
- Mistral
- Together AI
- any OpenAI-compatible API

---

## 🚀 Installation

### ContentDB (recommended)

Install via ContentDB:

```
Content → Mods → LLM Connect
```

---

### Manual Installation

1. Download the repository or release archive
2. Extract into your `mods` folder
3. Ensure the folder name is:

```
llm_connect
```

4. Enable HTTP API in `minetest.conf`

```
secure.http_mods = llm_connect
```

Restart the server.

---

## ⚙️ Configuration

Configuration can be done via:

- `/llm` → Config button (requires `llm_root`)
- `minetest.conf`

Example:

```
llm_api_key = your-api-key
llm_api_url = https://api.openai.com/v1/chat/completions
llm_model = gpt-4

llm_temperature = 0.7
llm_max_tokens = 4000
llm_timeout = 120
```

Context options:

```
llm_context_send_player_pos = true
llm_context_send_mod_list = true
llm_context_send_server_info = true
llm_context_send_commands = true
llm_context_send_materials = false
```

---

## 🎮 Commands

| Command | Description | Required Privilege |
|---------|-------------|-------------------|
| `/llm` | Open the AI chat interface | `llm` |
| `/llm_msg <message>` | Send a direct message to the LLM (no GUI) | `llm` |
| `/llm_undo` | Undo the last WorldEdit agency operation | `llm` |
| `/llm_reload_startup` | Reload `llm_startup.lua` at runtime (⚠️ no new registrations) | `llm_root` |

> The **Smart Lua IDE** and **Config GUI** are opened via buttons inside the `/llm` chat interface, not via separate commands.

---

## 🔐 Security Notes

LLM Connect includes multiple safety mechanisms:

- privilege-based access control
- sandboxed execution environment
- optional Lua whitelist
- no filesystem access in sandbox mode

Server administrators should still review generated code carefully.

---

## 🧭 Roadmap

See:

```
ROADMAP_090.md
```

for planned improvements and upcoming features.

---

## 🤝 Contributing

Contributions are welcome.

Typical workflow:

1. fork repository
2. create feature branch
3. implement changes
4. submit pull request

Areas of interest:

- new AI integrations
- UI improvements
- security auditing
- building tools
- documentation

---

## 📜 License

LGPL-3.0-or-later

See `LICENSE`.

---

## 🔗 Links

ContentDB
https://content.luanti.org/packages/H5N3RG/llm_connect/

Luanti
https://www.luanti.org/

---

**LLM Connect – Bringing AI-assisted development into Luanti.**
