# TESTS.md - Manual Luanti Test Tasks

Run these tests in the `zebra` world or another world where LLM-Connect is
enabled. Keep `debug.txt` visible with `tail -f debug.txt` from the parent
workspace when possible.

## 1. Startup and Health

Required config/settings:

- LLM-Connect enabled in the world.
- No LLM provider needed.

In-game action:

```text
/llm_health
```

Expected trace/log evidence:

- `debug.txt` shows `[llm_connect] LLM Connect 1.2.0-dev init complete`.
- `debug.txt` shows `[llm_connect] ready - 2 Lua-first skill(s) registered` or
  equivalent current count.
- Chat health output lists core subsystems as `ok`.

What failure means:

- Startup/module load order is broken, or a submodule failed during `dofile`.

Related subsystem/files:

- `init.lua`
- `subsystem_health.lua`
- `api/api_init.lua`
- `context/context_init.lua`
- `skills/skills_init.lua`
- `runtime/runtime_init.lua`
- `agent/agent_init.lua`
- `gui/gui_init.lua`

## 2. Config GUI Tooltip Smoke Test

Required config/settings:

- Player has `llm_root`.

In-game action:

```text
/llm_config
```

Then open the Agent/config areas where trace settings are displayed.

Expected trace/log evidence:

- No new `Invalid tooltip element` lines in `debug.txt`.
- Config formspec opens and remains usable.

What failure means:

- A formspec tooltip or control string is malformed, usually from unescaped text
  or raw newline content.

Related subsystem/files:

- `gui/config_gui.lua`
- `init.lua` formspec dispatch

## 3. Live Trace Panel

Required config/settings:

- Player has `llm_root`.
- Set `llm_live_trace_chat = true`.
- Optional: set `llm_live_trace_show_lua = true`.
- Optional: set `llm_live_trace_verbosity = verbose`.

In-game action:

```text
/llm_trace
```

Expected trace/log evidence:

- A `LLM Connect Live Trace` formspec opens.
- Root chat receives `[LLM TRACE:...]` lines during LLM requests or agent runs.
- The trace buffer can be refreshed and cleared.

What failure means:

- `agent/live_trace.lua` did not load, root privilege detection is wrong, or
  formspec field handling is broken.

Related subsystem/files:

- `agent/live_trace.lua`
- `api/llm_api.lua`
- `agent/agent_runtime.lua`
- `runtime/core_executor.lua`
- `gui/config_gui.lua`

## 4. Skill List Baseline

Required config/settings:

- Player has `llm_root`.
- WorldEdit may be enabled or disabled; record which state you are testing.

In-game action:

```text
/llm_skill_list singleplayer
```

Expected trace/log evidence:

- Chat lists `command_agent` and `worldedit_agent`.
- Each skill shows `ATTACHED` or `DETACHED`, required privilege, and
  availability.
- `worldedit_agent available=true` only when the WorldEdit Lua API is available
  in the world.

What failure means:

- Skill registry failed to load internal skills, status reporting is broken, or
  WorldEdit availability detection does not match the world.

Related subsystem/files:

- `skills/registry.lua`
- `skills/skills_init.lua`
- `skills/command_agent/command_agent.lua`
- `skills/worldedit_agent/worldedit_agent.lua`
- `init.lua`

## 5. Root Skill Attach/Detach

Required config/settings:

- Acting player has `llm_root`.
- Target player is `singleplayer`.

In-game action:

```text
/llm_skill_attach singleplayer worldedit_agent on
/llm_skill_list singleplayer
/llm_skill_attach singleplayer worldedit_agent off
/llm_skill_list singleplayer
```

Expected trace/log evidence:

- First list after attach shows `worldedit_agent` as `ATTACHED`.
- Second list after detach shows `worldedit_agent` as `DETACHED`.
- No `failed` or `unknown skill` response.

What failure means:

- The chat command is calling the wrong registry API name, or registry
  attachment state is not being updated.

Related subsystem/files:

- `init.lua`
- `skills/registry.lua`
- `gui/main_gui.lua`

## 6. Agent Without Attached Skills

Required config/settings:

- Player has `llm` and `llm_agent`.
- Detach all skills for the player:

```text
/llm_skill_attach singleplayer worldedit_agent off
/llm_skill_attach singleplayer command_agent off
```

In-game prompt/action:

```text
/llm build a small stone hut here
```

Expected trace/log evidence:

- Agent should not execute WorldEdit actions.
- Prompt context should say no active skills, or logs should show
  `active_skills=0`.
- Chat should answer that no building skill is active or ask for skill
  attachment.

What failure means:

- Prompt builder or registry is injecting detached skills, or executor exposes
  skill APIs without checking active attachment state.

Related subsystem/files:

- `agent/agent_prompt_builder.lua`
- `agent/agent_runtime.lua`
- `skills/registry.lua`
- `runtime/core_executor.lua`

## 7. WorldEdit Context Lookup Before Build

Required config/settings:

- Player has `llm`, `llm_agent`.
- `worldedit_agent` attached to the player.
- WorldEdit installed and available.
- LLM provider configured.
- Optional for evidence: `llm_live_trace_chat = true`.

In-game prompt/action:

```text
/llm build a small 5x5 stone hut with a wooden roof here
```

Expected trace/log evidence:

- First iteration may load context:
  `llm_connect.context.load('worldedit')` or
  `llm_connect.context.load('skills.worldedit_agent')`.
- Build action should call:
  `llm_connect.skills.worldedit_agent.run('build_hut', ..., player_name)` or
  `run('build_house', ..., player_name)`.
- It must not call `worldedit_agent.set_nodes`.
- It must not hardcode `"singleplayer"` if `player_name` is available.
- Successful execution logs `[core_executor] success`.

What failure means:

- Prompt contract still allows hallucinated skill APIs, context was not loaded,
  `player_name` is not available in sandbox, or the WorldEdit skill API is not
  exposed correctly.

Related subsystem/files:

- `agent/agent_prompt_builder.lua`
- `agent/agent_runtime.lua`
- `context/context_registry.lua`
- `skills/worldedit_agent/worldedit_agent.lua`
- `runtime/core_executor.lua`

## 8. Context API Shape

Required config/settings:

- Player has `llm`, `llm_agent`.
- LLM provider configured.
- Any skill state is acceptable.

In-game prompt/action:

```text
/llm list the available context keys, then stop
```

Expected trace/log evidence:

- Generated action should call `llm_connect.context.keys()` or
  `llm_connect.context.list_sections()`.
- Returned value should be treated as a table with `sections` and `aliases`.
- Agent should not loop repeatedly on the same context call.

What failure means:

- The prompt contract is unclear about context return shapes, or middleware is
  not stopping repeated context-only turns.

Related subsystem/files:

- `context/context_registry.lua`
- `context/context_init.lua`
- `agent/agent_prompt_builder.lua`
- `agent/agent_context_cache.lua`
- `agent/agent_middleware.lua`

## 9. Prompt File Trace

Required config/settings:

- Provider configured.
- Set `llm_trace_prompt_log = true`.
- Be aware this writes full request/response payloads to world-local files.

In-game prompt/action:

```text
/llm reply with exactly OK
```

Expected trace/log evidence:

- `llm_user_prompt_log.txt` gains request content.
- `llm_response_prompt_log.txt` gains raw response content.
- `debug.txt` should not include authorization headers.

What failure means:

- Prompt trace hook did not install, setting reload did not apply, or provider
  request path bypassed `api/llm_api.lua`.

Related subsystem/files:

- `api/llm_api.lua`
- `api/provider_*.lua`
- `init.lua`
- `settingtypes.txt`

## 10. Root Override Boundaries

Required config/settings:

- Player has `llm_root`.
- Start with:
  `llm_root_agent_unrestricted = false`,
  `llm_root_bypass_safety_filters = false`,
  `llm_root_allow_startup_execution = false`.

In-game prompt/action:

```text
/llm run Lua that tries to call load('return 1')
```

Expected trace/log evidence:

- With bypass disabled, raw `load(...)` is blocked by precheck.
- `llm_connect.context.load('server')` remains allowed.
- If root bypass settings are later enabled intentionally, behavior should
  change only according to those settings.

What failure means:

- Parser forbidden-pattern sanitization is too broad or too permissive, or root
  policy defaults changed unintentionally.

Related subsystem/files:

- `agent/parser_utils.lua`
- `runtime/core_executor.lua`
- `runtime/execution_policy.lua`
- `settingtypes.txt`

## 11. IDE Runtime-Safe Execution

Required config/settings:

- Player has `llm_dev` or `llm_root`.
- IDE enabled through normal LLM-Connect GUI.

In-game prompt/action:

Open the IDE and run a small runtime-safe script:

```lua
print("LLM Connect IDE smoke test")
return { ok = true }
```

Expected trace/log evidence:

- Output appears in the IDE run output.
- `debug.txt` shows `[core_executor] success`.
- No startup-preferred warning for this simple script.

What failure means:

- IDE execution path is not reaching `runtime/core_executor.lua`, or sandbox
  execution output capture is broken.

Related subsystem/files:

- `gui/ide_gui.lua`
- `gui/code_executor.lua`
- `runtime/core_executor.lua`
- `runtime/runtime_init.lua`

## 12. Startup Script Reload

Required config/settings:

- Player has `llm_root`.
- A world file `llm_startup.lua` may or may not exist.

In-game action:

```text
/llm_startup_reload
```

Expected trace/log evidence:

- If no file exists, chat says no startup file was found.
- If a file exists, root-only policy applies and execution is logged.

What failure means:

- Startup file path policy is wrong, root check is wrong, or startup execution
  setting behavior regressed.

Related subsystem/files:

- `init.lua`
- `runtime/path_policy.lua`
- `runtime/core_executor.lua`
- `runtime/execution_policy.lua`
