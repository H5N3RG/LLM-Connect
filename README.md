# LLM Connect

**LLM Connect** is a Luanti mod that integrates a large language model (LLM)
into your game session. It provides an AI-powered chat assistant, a full
Smart Lua IDE with sandboxed code execution, and an AI-assisted WorldEdit
agency mode — all configurable via an in-game UI.

> Version: 0.9.0 — License: LGPL-3.0-or-later — Author: H5N3RG

---

## Features

### AI Chat
- Persistent per-player chat history with the LLM
- Configurable context injection: server info, player position, active mods,
  available chat commands, node/item/tool registry sample
- 29 language options — the LLM responds in the configured language
- All API providers compatible with the OpenAI chat completions format

### Smart Lua IDE
- Full-screen two-panel editor (code + output) with file manager
- **AI Code Generation** — describe what you want, get working Lua code
- **Sandboxed Execution** — code runs in a restricted environment; only
  `llm_connect:` prefixed registrations are permitted
- **Pre-Executor** — static analysis before execution: syntax check,
  naming convention enforcement, required field validation
- **Auto-Fix Loop** — after a failed run, the LLM automatically receives
  the error and attempts a correction; configurable iteration limit
- **IDE Asset Picker** — three-tab browser (Nodes / Items+Tools / Sounds)
  with search and pagination; selected assets are injected as structured
  metadata into the LLM context
- **API Reference Injection** — optional slim (~400 tokens) or full
  (~2000 tokens) Luanti API reference available per session
- **Syntax Check**, **Semantic Analysis**, **Code Explain** — individual
  LLM-powered analysis tools
- Snippet file manager: save, load, and manage `.lua` files per world
- Startup code persistence: successful executions can be saved to
  `llm_startup.lua` and re-executed on every server start
- Per-mode timeout overrides, configurable token limits

### WorldEdit Agency
- Requires `worldedit` (and optionally `worldeditadditions`)
- **Single-shot mode** — describe a structure, the LLM generates and
  executes a WorldEdit command sequence
- **Loop mode** — iterative multi-step building with up to N LLM calls
- Automatic snapshot before execution (undo support)
- Nearby node sampling for material-aware suggestions
- Material Picker UI — select up to 8 materials with weights and preview
- WorldEditAdditions integration: torus, ellipsoid, erode, convolve,
  overlay, layers, replacemix

---

## Requirements

| Dependency | Required | Notes |
|---|---|---|
| Luanti (Minetest) | ✓ | Tested on 5.8+ |
| HTTP API access | ✓ | `secure.http_mods = llm_connect` in `minetest.conf` |
| `worldedit` | optional | Required for WorldEdit agency mode |
| `worldeditadditions` | optional | Enables advanced WEA commands in agency mode |
| An OpenAI-compatible LLM API | ✓ | Local or hosted (Mistral, OpenAI, Ollama, etc.) |

---

## Installation

1. Clone or download this repository into your Luanti `mods/` folder:
   ```
   cd ~/.minetest/mods/
   git clone https://github.com/H5N3RG/LLM-Connect llm_connect
   ```

2. Enable the mod for your world in Luanti's mod selection screen,
   or add `llm_connect = true` to your world's `world.mt`.

3. Grant HTTP access in `minetest.conf`:
   ```
   secure.http_mods = llm_connect
   ```
   If using other mods that also need HTTP, append comma-separated:
   ```
   secure.http_mods = llm_connect,other_mod
   ```

4. Configure the API connection (see Configuration below).

5. Grant yourself the required privileges in-game:
   ```
   /grant <yourname> llm,llm_dev,llm_worldedit
   ```
   Or use `llm_root` for all privileges at once:
   ```
   /grant <yourname> llm_root
   ```

---

## Configuration

All settings can be changed via the **in-game settings menu** (`/llm_config`)
or directly in `minetest.conf`.

### Quick Start — Minimum Required Settings

```ini
llm_api_key   = your-api-key-here
llm_api_url   = https://api.mistral.ai/v1/chat/completions
llm_model     = open-mistral-nemo
```

For a local Ollama instance:
```ini
llm_api_key   = ollama
llm_api_url   = http://localhost:11434/v1/chat/completions
llm_model     = llama3
```

---

## Full Settings Reference

### API Connection

| Setting | Default | Description |
|---|---|---|
| `llm_api_key` | _(empty)_ | API key for the LLM provider |
| `llm_api_url` | _(empty)_ | OpenAI-compatible completions endpoint |
| `llm_model` | _(empty)_ | Model name (e.g. `gpt-4o`, `open-mistral-nemo`) |
| `llm_max_tokens` | `4000` | Max tokens in response (500–16384) |
| `llm_max_tokens_integer` | `true` | Send max_tokens as integer (required by most APIs) |
| `llm_temperature` | `0.7` | Creativity — 0.0 = deterministic, 2.0 = very creative |
| `llm_top_p` | `0.9` | Nucleus sampling threshold (0.0–1.0) |
| `llm_presence_penalty` | `0.0` | Penalise repetition of already-mentioned topics |
| `llm_frequency_penalty` | `0.0` | Penalise frequent token reuse |
| `llm_debug` | `false` | Enable verbose API debug logging |

### Timeouts

| Setting | Default | Description |
|---|---|---|
| `llm_timeout` | `120` | Global timeout in seconds (30–600) |
| `llm_timeout_chat` | `0` | Chat mode override — 0 = use global |
| `llm_timeout_ide` | `0` | IDE mode override — 0 = use global |
| `llm_timeout_we` | `0` | WorldEdit mode override — 0 = use global |

### Chat Context

| Setting | Default | Description |
|---|---|---|
| `llm_context_send_server_info` | `true` | Include server info in context |
| `llm_context_send_mod_list` | `false` | Include list of active mods |
| `llm_context_send_commands` | `true` | Include available chat commands |
| `llm_context_send_player_pos` | `true` | Include player position and HP |
| `llm_context_send_materials` | `false` | Include node/item/tool registry sample |
| `llm_context_max_history` | `20` | Max chat history messages per request (2–100) |

### Language

| Setting | Default | Description |
|---|---|---|
| `llm_language` | `en` | LLM response language — `en` means no instruction injected |
| `llm_language_instruction_repeat` | `1` | How many times to repeat the language instruction (0–5) |

Supported languages: `en de es fr it pt ru zh ja ko ar hi tr nl pl sv da no fi cs hu ro el th vi id ms he bn uk`

### IDE — Behaviour

| Setting | Default | Description |
|---|---|---|
| `llm_ide_hot_reload` | `true` | Hot-reload world after successful code execution |
| `llm_ide_auto_save` | `true` | Auto-save code buffer on changes |
| `llm_ide_whitelist_enabled` | `true` | Enforce sandbox security whitelist |
| `llm_ide_include_run_output` | `true` | Send last run output to LLM for self-correction |
| `llm_ide_max_code_context` | `300` | Max lines of code sent as context — 0 = unlimited |
| `llm_ide_auto_fix_iterations` | `3` | Auto-Fix loop max iterations — 0 = disabled |

### IDE — Context Injection

| Setting | Default | Description |
|---|---|---|
| `llm_ide_naming_guide` | `true` | Inject naming convention guide (`llm_connect:` prefix) |
| `llm_ide_context_mod_list` | `true` | Send active mod list in IDE Generate context |
| `llm_ide_context_player_pos` | `true` | Send player position in IDE Generate context |

### IDE — Asset Picker

| Setting | Default | Description |
|---|---|---|
| `llm_ide_asset_nodes` | `true` | Enable Nodes tab in Asset Picker |
| `llm_ide_asset_items` | `true` | Enable Items/Tools tab in Asset Picker |
| `llm_ide_asset_sounds` | `true` | Enable Sounds tab in Asset Picker |
| `llm_ide_asset_max_selected` | `32` | Max simultaneously selected assets (1–128) |

### IDE — API Reference Injection

| Setting | Default | Description |
|---|---|---|
| `llm_ide_api_default_level` | `none` | Default API ref level: `none` / `slim` / `full` |

`slim` injects ~400 tokens of the most-used Luanti API functions.
`full` injects ~2000 tokens of comprehensive API coverage.
Both can be toggled per session in the IDE toolbar without changing this setting.

### WorldEdit

| Setting | Default | Description |
|---|---|---|
| `llm_worldedit_additions` | `true` | Enable WorldEditAdditions command set |
| `llm_we_max_iterations` | `6` | Max LLM iterations in Loop mode (1–20) |
| `llm_we_snapshot_before_exec` | `true` | Take undo snapshot before each execution |

---

## Privileges

| Privilege | Description |
|---|---|
| `llm` | Access to AI chat |
| `llm_dev` | Access to Smart Lua IDE and code execution |
| `llm_worldedit` | Access to WorldEdit agency mode |
| `llm_root` | Super-privilege — implies all of the above |

---

## Chat Commands

| Command | Description |
|---|---|
| `/llm_config` | Open the in-game configuration GUI |
| `/llm_config reload` | Reload all settings from `minetest.conf` without restart |

---

## Security Notes

- The IDE sandbox blocks access to `io`, `require`, `dofile`, `loadfile`,
  `load`, `debug`, and `package`. All other Lua globals (including loaded
  mod APIs) are available read-only.
- All node/item/tool registrations must use the `llm_connect:` prefix.
  The pre-executor enforces this before any code reaches the game engine.
- Startup code (`llm_startup.lua`) is only written when a run succeeds.
- `llm_dev` should only be granted to trusted players on multiplayer servers.

---

## File Structure

```
llm_connect/
├── init.lua                   – Mod entry point, load order, privilege registration
├── mod.conf                   – Mod metadata
├── settingtypes.txt           – All configurable settings
├── llm_api.lua                – HTTP request handling, config management
├── chat_gui.lua               – AI chat formspec and handler
├── chat_context.lua           – Chat context builder
├── ide_gui.lua                – Smart Lua IDE formspec, toolbar, file manager
├── ide_system_prompts.lua     – IDE LLM system prompt builder
├── ide_api_stubs.lua          – Luanti API reference (slim + full)
├── ide_asset_picker.lua       – Node/Item/Sound asset browser
├── ide_languages.lua          – Language instruction strings
├── code_executor.lua          – Sandbox execution, pre-executor, auto-fix loop
├── config_gui.lua             – In-game settings GUI
├── llm_worldedit.lua          – WorldEdit agency (Phase 2 + WEA Phase 5)
├── worldedit_system_prompts.lua – WorldEdit LLM system prompt builder
└── material_picker.lua        – Material picker UI for WorldEdit context
```

---

## License

LGPL-3.0-or-later — see [LICENSE](LICENSE)
