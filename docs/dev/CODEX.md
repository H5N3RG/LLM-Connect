# CODEX.md - Implementation Guide for the Next Codex Session

This file is the handoff guide for future implementation work on LLM-Connect.
It is based on the current repository state and runtime evidence inspected on
2026-05-16. Do not treat older roadmap documents as authoritative without
checking the current code and logs again.

## Current State

LLM-Connect is a Luanti/Minetest mod in an active 1.2.0-dev transition toward a
Lua-first agent runtime.

Observed load path from `lemr . --trace`:

1. `init.lua` registers privileges and loads prompt trace, live trace, API,
   parser, context, skills, runtime, agent, and GUI modules.
2. `context/context_registry.lua` registers bootstrap context sections:
   `agent.context_api`, `server.info`, `luanti.safe_core`,
   `mods.worldedit.status`, and `luanti.registered_nodes.preview`.
3. `skills/registry.lua` loads internal skills explicitly:
   `command_agent` and `worldedit_agent`.
4. `runtime/path_policy.lua` and `runtime/storage/*` initialize script storage.
5. `agent/agent_runtime.lua` runs the dual-channel loop for visible text plus
   hidden `lua_action` blocks.
6. `gui/*` loads the main GUI, IDE, file manager, asset picker, and config GUI.

`lemr . --trace` currently reports successful module load and health output.
`luajit -b` compile-only syntax checks currently pass for all Lua files.

## Runtime Evidence

Live logs are symlinked from the Luanti environment:

- `../debug.txt`
- `../llm_user_prompt_log.txt`
- `../llm_response_prompt_log.txt`

At inspection time:

- `debug.txt` contained current startup evidence and older agent failure
  evidence.
- Both prompt log files existed but had 0 lines, so prompt-file tracing was not
  active or had not written during the latest observed run.

Important current log findings:

- Startup succeeds after an earlier syntax failure at `init.lua:381`.
- `live_trace` loads and `llm_trace` chat command is registered.
- `worldedit_agent` registers, but runtime status can still show it unavailable
  if the WorldEdit Lua API is not present in the running world.
- Config GUI currently emits a formspec error:
  `Invalid tooltip element(3): 'trace_prompt_log;Writes full request bodies ...'`.
  This points to an unescaped or too-long/multiline tooltip in
  `gui/config_gui.lua`.
- Startup logs show undeclared global accesses in runtime storage modules:
  `path_policy` and `storage_backends` from
  `runtime/storage/runtime_scripts.lua` and `runtime/storage/trusted_mods.lua`.
- A previous WorldEdit agent run failed first because `player_name` was nil
  inside the generated action, then failed because the model called nonexistent
  `llm_connect.skills.worldedit_agent.set_nodes`.

## Architecture Map

Main files and responsibilities:

- `init.lua`: top-level module loading, privilege registration, chat commands,
  startup script execution, formspec dispatch.
- `api/llm_api.lua`: provider request path, prompt trace writes, live trace
  request/response emission.
- `agent/parser_utils.lua`: extracts `lua_action` fences and blocks forbidden
  host-access patterns. It explicitly allows
  `llm_connect.context.load(...)` before scanning for raw `load`.
- `agent/agent_prompt_builder.lua`: compact system prompt, active skill
  summary, context API contract.
- `agent/agent_runtime.lua`: iterative dual-channel agent loop, action
  execution, live trace emission, middleware decision handling.
- `agent/agent_middleware.lua`: decides whether to continue after context
  lookups, explicit continuation, or retry-worthy failures.
- `agent/agent_retry.lua`: failure signatures and single repair retry logic.
- `agent/live_trace.lua`: root-only in-game trace stream plus formspec buffer.
- `context/context_registry.lua`: exact context ids, aliases, search fallback,
  sandbox proxy for `llm_connect.context`.
- `context/context_init.lua`: public `llm_connect.context.*` facade and
  argument normalization.
- `skills/registry.lua`: Lua-first skill registry, per-player attach/detach
  state, active skill descriptions.
- `skills/worldedit_agent/worldedit_agent.lua`: registered
  `llm_connect.skills.worldedit_agent.run(tool, args, player_name)` API.
- `runtime/core_executor.lua`: sandbox creation, precheck, classification,
  policy resolution, action execution.
- `runtime/execution_policy.lua`: privilege and root override policy.
- `runtime/path_policy.lua` and `runtime/storage/*`: IDE persistence paths and
  backend helpers.
- `gui/config_gui.lua`: root config formspec, API settings, agent settings,
  live trace controls.
- `gui/main_gui.lua`: main player-facing UI and skill panel.

## Current Contracts

### Agent Output Contract

The LLM should normally answer in visible text. It should emit a hidden action
only inside exactly fenced `lua_action` blocks.

The sandbox provides:

- `player_name`
- safe `core` / `minetest`
- `llm_connect.context`
- active attached skills under `llm_connect.skills`

The prompt must keep saying that `player_name` is available. The runtime already
sets `player_name` in `runtime/core_executor.lua:create_sandbox_env`.

### Context Contract

Prefer exact ids and aliases:

```lua
local doc = llm_connect.context.load("worldedit")
local server = llm_connect.context.load("server")
local nodes = llm_connect.context.get_section("luanti.registered_nodes.preview", { query = "wood" })
```

`search()` is a fallback and returns a table shaped like:

```lua
{ ok = true, count = n, sections = { ... } }
```

Do not treat search results as a plain string or array.

### Skill Attachment Contract

Skills are globally registered but per-player attached. Defaults are off.

Useful commands:

```text
/llm_skill_list [player]
/llm_skill_attach <player> <skill_id> on
/llm_skill_attach <player> <skill_id> off
```

Current internal skills:

- `command_agent`
- `worldedit_agent`

The skill registry code exposes `attach_skill_to_player()` and
`detach_skill_from_player()`, but `init.lua` currently looks for
`attach_to_player()` and `detach_from_player()`. A future implementation session
must verify this mismatch before assuming `/llm_skill_attach` works.

### WorldEdit Agent Contract

The supported public call form is:

```lua
llm_connect.skills.worldedit_agent.run("build_hut", {}, player_name)
llm_connect.skills.worldedit_agent.run("build_house", {
  width = 7,
  length = 7,
  height = 4,
  wall = "default:wood",
  floor = "default:stone",
  roof = "default:cobble",
}, player_name)
```

Do not call nonexistent direct methods such as:

```lua
llm_connect.skills.worldedit_agent.set_nodes(...)
```

Supported tools are listed in `skills/worldedit_agent/worldedit_agent.lua` under
`TOOLS`. High-level builders should be preferred for natural-language building
tasks: `build_hut`, `build_house`, `build_tower`, and `build_platform`.

## Implementation Priorities

### 1. Fix Skill Attach Command Compatibility

Problem:

- `skills/registry.lua` implements `attach_skill_to_player()` and
  `detach_skill_from_player()`.
- `init.lua` uses `skills.attach_to_player` and `skills.detach_from_player`.

Implementation target:

- Either add compatibility aliases in `skills/registry.lua`, or update
  `init.lua` to call the implemented names.
- Preserve the existing meaning: root explicitly attaches or detaches a skill
  for the target player's agent session.
- After the fix, `/llm_skill_attach singleplayer worldedit_agent on` should
  change `/llm_skill_list singleplayer` from `DETACHED` to `ATTACHED`.

Files:

- `init.lua`
- `skills/registry.lua`

### 2. Fix Config GUI Tooltip Error

Problem:

- Opening config currently logs `Invalid tooltip element(3)` for
  `trace_prompt_log`.

Implementation target:

- Inspect tooltip construction in `gui/config_gui.lua`.
- Ensure tooltip field names and text are formspec escaped.
- Avoid raw newlines or too-long unescaped strings inside `tooltip[]`.
- Keep labels concise; move long explanation into docs or shorter tooltip text.

Files:

- `gui/config_gui.lua`

### 3. Fix Runtime Storage Global Warnings

Problem:

- Startup logs show undeclared global access for `path_policy` and
  `storage_backends` inside storage modules.

Implementation target:

- Inspect `runtime/storage/runtime_scripts.lua` and
  `runtime/storage/trusted_mods.lua`.
- Bind dependencies from `_G.llm_connect.path_policy`,
  `_G.llm_connect.storage_backends`, or explicit globals consistently.
- Keep load order in `init.lua` intact unless a clear dependency issue is found.

Files:

- `runtime/storage/runtime_scripts.lua`
- `runtime/storage/trusted_mods.lua`
- `init.lua`

### 4. Make WorldEdit Skill Use Harder to Mis-Prompt

Problem:

- Logs show the model called `set_nodes`, which is not part of the skill API.
- The correct API is `worldedit_agent.run(tool, args, player_name)`.

Implementation target:

- Tighten `skills.worldedit_agent` context text and prompt text so it presents
  only the supported public API shape.
- Consider adding a small compatibility wrapper only if approved in
  `PLAN_OPTIONS.md`; do not add it silently.
- Keep high-level builders prominent.

Files:

- `skills/worldedit_agent/worldedit_agent.lua`
- `agent/agent_prompt_builder.lua`
- `context/context_registry.lua`

### 5. Verify Context Continuation Behavior

Problem:

- Context proxy intentionally marks successful context loads as
  `{done=false, continue=true}`.
- This is useful for a two-step lookup-then-act loop, but can waste iterations
  if the model repeatedly loads context.

Implementation target:

- Use existing `agent/agent_context_cache.lua` and middleware hooks before
  adding new loop logic.
- Detect repeated identical context loads and stop or compress repeated cache
  entries.
- Preserve the expected first context lookup continuation behavior.

Files:

- `agent/agent_context_cache.lua`
- `agent/agent_middleware.lua`
- `agent/agent_runtime.lua`

### 6. Keep Root Override Explicit

Current policy:

- `llm_root` implies all LLM Connect privileges.
- Root agent execution remains sandboxed unless
  `llm_root_agent_unrestricted=true`.
- Bypass of safety filters and startup-preferred execution are separately
  controlled by settings.

Do not silently change these defaults. See `docs/PLAN_OPTIONS.md` before
changing root execution semantics.

Files:

- `runtime/execution_policy.lua`
- `runtime/core_executor.lua`
- `settingtypes.txt`

## Verification Commands

Run from `LLM-Connect`:

```sh
lemr . --trace
```

```sh
for f in $(rg --files -g '*.lua'); do luajit -b "$f" /tmp/llm_connect_syntax.out || exit 1; done
```

Run from the parent workspace:

```sh
tail -n 240 debug.txt
```

```sh
wc -l llm_user_prompt_log.txt llm_response_prompt_log.txt
```

## Guardrails for Future Codex Work

- Inspect `debug.txt` and prompt logs before changing agent behavior.
- Do not implement runtime features from roadmap docs without checking current
  code first.
- Keep Lua-first orchestration. Do not reintroduce JSON-heavy tool calling.
- Prefer exact context ids and aliases over broad search.
- Keep prompt text synchronized with actual sandbox and skill APIs.
- Do not broaden root execution defaults without explicit user approval.
- Preserve user changes in the dirty worktree.
- Make small patches and verify with `lemr`, `luajit -b`, and manual in-game
  tests from `docs/TESTS.md`.

---
