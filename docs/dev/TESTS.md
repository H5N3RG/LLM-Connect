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

- `agent/agent_debug.lua` did not load, root privilege detection is wrong, or
  formspec field handling is broken.

Related subsystem/files:

- `agent/agent_debug.lua`
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

- `agent/agent_context.lua`
- `agent/agent_runtime.lua`
- `skills/registry.lua`
- `runtime/core_executor.lua`

## 7. Node Printer Context Lookup Before Build

Required config/settings:

- Player has `llm`, `llm_agent`.
- `worldedit_agent` attached to the player.
- WorldEdit is optional for native `print_plan` and high-level builders.
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
  `llm_connect.skills.worldedit_agent.run('print_plan', ..., player_name)` for
  custom multi-part generated structures, or:
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

- `agent/agent_context.lua`
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

- The prompt contract is unclear about context return shapes, or flow logic is
  not stopping repeated context-only turns.

Related subsystem/files:

- `context/context_registry.lua`
- `context/context_init.lua`
- `agent/agent_context.lua`
- `agent/agent_flow.lua`

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

## 13. Runtime Agent Time Change

Required config/settings:

- Player has `llm` and `llm_agent`.
- `command_agent` is attached to the player.
- LLM provider configured.
- Optional for evidence: `llm_live_trace_chat = true`.

In-game prompt/action:

```text
/llm set the time to 18000
```

Expected trace/log evidence:

- The generated action should call:
  `llm_connect.skills.command_agent.run('set_time', { time = 18000 }, player_name)`.
- It must not call `llm_connect.skills.command_agent.set_time(...)` or
  `llm_connect.skills.command_agent.set_time:run(...)`.
- Fallback `run_chatcommand({ command = '/time 18000' }, player_name)` is
  acceptable only if native `core.set_timeofday` is unavailable.
- It must not call `core.set_time(18000)`.
- Result table should contain `ok=true` and `success=true`.

What failure means:

- Runtime-agent context is stale, prompt text still suggests safe-core time
  mutation, or the command facade is not exposed in the sandbox.

Related subsystem/files:

- `skills/command_agent/command_agent.lua`
- `context/basic_context.lua`
- `context/context_registry.lua`
- `agent/agent_context.lua`

## 14. Agent Skill Result Guard Matrix

Required config/settings:

- Player has `llm`, `llm_agent`.
- `worldedit_agent` is attached to the player.
- LLM provider configured.
- Recommended evidence settings:
  `llm_live_trace_chat = true`,
  `llm_live_trace_show_lua = true`,
  `llm_trace_prompt_log = true`.

In-game prompt/action:

```text
/llm baue mir ein beliebiges haus aus validen materialien hierhin an meine position
```

Expected trace/log evidence:

- The generated action may use the canonical high-level builder:
  `llm_connect.skills.worldedit_agent.run("build_house", args, player_name)`.
- A result guard in this canonical form must be accepted:
  `if not (res and res.ok) then return {done=false, continue=true, ...} end`.
- Equivalent guards should also be accepted when observed:
  `if res == nil or res.ok == false then ... end`,
  `if not res.ok then ... end`,
  `if not (res and res.success) then ... end`.
- The runtime must not emit:
  `lua_action reports done=true after a skill call without checking the skill result`
  when the generated code contains one of the accepted guards above.
- If a repair iteration happens, its previous-action history must describe the
  real runtime/skill error, not a false missing-result-check error.
- A successful run ends with `[core_executor] success` and no unnecessary repair
  iteration caused by the result guard.

What failure means:

- `agent/agent_runtime.lua` is inferring Lua semantics from a too-narrow text
  pattern. This is a guard/parser false positive, not necessarily a skill API
  failure.
- Repair prompts may become misleading because the model receives an incorrect
  error diagnosis and edits unrelated arguments.

Related subsystem/files:

- `agent/agent_runtime.lua`
- `agent/agent_flow.lua`
- `agent/parser_utils.lua`
- `skills/worldedit_agent/worldedit_agent.lua`

## 15. Runtime Agent Invalid Skill Invocation Matrix

Required config/settings:

- Player has `llm`, `llm_agent`.
- `command_agent` is attached to the player.
- LLM provider configured.
- Recommended evidence settings:
  `llm_live_trace_chat = true`,
  `llm_live_trace_show_lua = true`,
  `llm_trace_prompt_log = true`.

In-game prompt/action:

```text
/llm stelle die zeit auf 21000
```

Expected trace/log evidence:

- Preferred action:
  `llm_connect.skills.command_agent.run("set_time", {time = 21000}, player_name)`.
- Fallback action, only when the native time tool is unavailable:
  `llm_connect.skills.command_agent.run("run_chatcommand", {command = "/time 21000"}, player_name)`.
- These invalid variants must not execute as successful actions:
  `llm_connect.skills.command_agent.execute(...)`,
  `llm_connect.skills.command_agent.set_time(...)`,
  `llm_connect.skills.command_agent.set_time:run(...)`,
  `llm_connect.skills.command_agent.run("set_time", ..., "singleplayer")`.
- If the model emits an invalid direct/nested helper call, the runtime should
  produce a concise correction pointing to:
  `llm_connect.skills.command_agent.run("set_time", {time = 21000}, player_name)`.
- The repair iteration should call the canonical `.run(...)` form instead of
  only loading documentation and stopping.
- Final result should report success only after the skill returned `ok=true`.

What failure means:

- Runtime-agent context still exposes or implies a legacy helper surface.
- Invalid-call detection is too narrow, or repair history does not provide a
  strong enough canonical replacement.

Related subsystem/files:

- `skills/command_agent/command_agent.lua`
- `agent/agent_context.lua`
- `agent/agent_runtime.lua`
- `context/basic_context.lua`
- `context/context_registry.lua`

## 16. Context Iteration and Duplicate Lookup Matrix

Required config/settings:

- Player has `llm`, `llm_agent`.
- Either `command_agent` or `worldedit_agent` is attached.
- LLM provider configured.
- Recommended evidence settings:
  `llm_live_trace_chat = true`,
  `llm_live_trace_show_lua = true`,
  `llm_trace_prompt_log = true`.

In-game prompt/action:

```text
/llm lade die node printer dokumentation und baue danach ein kleines holzhaus hier
```

Expected trace/log evidence:

- A first context-only action may call:
  `llm_connect.context.load("skills.worldedit_agent")` or a valid alias such as
  `llm_connect.context.load("node_printer")`.
- A prefixed skill alias such as `llm_connect.context.load("skills.node_printer")`
  should resolve through the alias table to `skills.worldedit_agent`.
- If context loading is only an intermediate step, the returned table should be
  normalized to `done=false, continue=true`.
- After the context appears in `[RETRIEVED CONTEXT CACHE]`, the next iteration
  should use the cached documentation and call a skill.
- Repeating the same context load should not be treated as task completion when
  the user requested a later build action.
- A duplicate context lookup may be reported as already cached, but it must not
  mask an unresolved imperative task as `done=true`.
- The flow should stop only after the build skill returns success, a real
  blocker occurs, or the configured iteration limit is reached.

What failure means:

- Context-only result normalization or duplicate-context handling is ending the
  loop too early.
- The prompt history is not making cached context visible/actionable enough for
  the next iteration.

Related subsystem/files:

- `agent/agent_runtime.lua`
- `agent/agent_flow.lua`
- `agent/agent_context.lua`
- `context/context_registry.lua`
- `skills/worldedit_agent/worldedit_agent.lua`

## 17. Skill Context Alias Compatibility Matrix

Required config/settings:

- Player has `llm`, `llm_agent`.
- `command_agent` and `worldedit_agent` are attached to the player.
- LLM provider configured.
- Recommended evidence settings:
  `llm_live_trace_chat = true`,
  `llm_live_trace_show_lua = true`,
  `llm_trace_prompt_log = true`.

In-game prompt/action:

```text
/llm lade die runtime-agent dokumentation und setze danach die zeit auf 18000
```

Expected trace/log evidence:

- The context load may use the exact section `skills.command_agent`, a plain
  alias such as `runtime_agent`, or a prefixed alias such as
  `skills.runtime_agent`.
- Plain and prefixed aliases should resolve to the same section:
  `skills.command_agent`.
- After documentation is loaded, the skill should be invoked through the stable
  API:
  `llm_connect.skills.command_agent.run("set_time", {time = 18000}, player_name)`.
- The prompt should not require core code to know command-agent internals.
  Section registration, aliases, and manuals remain owned by the skill.
- Final result should report success only after the skill returned `ok=true`.

What failure means:

- Registry, context aliases, and skill display names drifted apart.
- The model is inventing `skills.<alias>` keys that the context registry cannot
  resolve.
- Runtime-agent and command-agent naming is still ambiguous in the active skill
  context.

Related subsystem/files:

- `context/context_registry.lua`
- `skills/registry.lua`
- `skills/command_agent/command_agent.lua`
- `skills/worldedit_agent/worldedit_agent.lua`

## 18. Native Node Printer Geometry Primitives

Required config/settings:

- Player has `llm`, `llm_agent`, `worldedit_agent`.
- LLM provider configured.
- Recommended evidence settings:
  `llm_live_trace_chat = true`,
  `llm_live_trace_show_lua = true`,
  `llm_trace_prompt_log = true`.

In-game prompt/action:

```text
/llm lade die node printer dokumentation und baue danach ein kleines holzhaus hier
```

Expected trace/log evidence:

- The retrieved node-printer context describes the native primitives
  `nodes`, `lines`, `planes`, and `volumes`.
- The build plan uses `preview_plan` first and `print_plan` only after a
  successful preview.
- The tool arguments use native primitives such as `planes`, `volumes`, and
  `nodes`; no generated plan should rely on `rows`, `boxes`, or `build_*`.
- A named building request must not be satisfied by one solid volume. A castle
  plan should include separate walls, an entrance, and towers or battlements.
- For a local build request, the plan omits `origin` or sets
  `origin = "player"`.
- The plan must not use `origin = {x = 0, y = 0, z = 0}` with
  `absolute = false`.
- The preview result includes `data.origin`, `data.min`, and `data.max`, and
  those bounds are near the current player position.
- The final `print_plan` call returns success and a physical structure appears
  at or near the current player position.
- `debug.txt` contains a `worldedit_agent` line similar to
  `print_plan verified ... origin=... min=... max=...`.
- If no physical node is written, `print_plan` must return `ok=false` with a
  write-verification failure instead of claiming success.
- If the model attempts one large solid `volumes` cuboid and calls it a castle,
  `preview_plan` or `print_plan` should return `ok=false` and the next agent
  iteration should rewrite the plan with multiple primitive parts.

Additional verticality prompt/action:

```text
/llm baue mit dem node printer eine senkrechte glaslinie direkt hier an meiner position
```

Expected trace/log evidence:

- The plan uses a `lines` primitive with an explicit vertical direction vector,
  for example `dir = {x = 0, y = 1, z = 0}` or `dir = "up"`.
- The preview bounds show a vertical extent on the `y` axis.
- The final placement appears at or near the current player position.

Direct API regression check:

```lua
local res = llm_connect.skills.worldedit_agent.run("preview_plan", {
  origin = {x = 0, y = 0, z = 0},
  absolute = false,
  planes = {{
    from = {x = 0, y = 0, z = 0},
    dir1 = {x = 1, y = 0, z = 0},
    dir2 = {x = 0, y = 0, z = 1},
    size1 = 1,
    size2 = 1,
    node = "default:stone"
  }}
}, player_name)
return {done = true, message = tostring(res.ok) .. " " .. tostring(res.message)}
```

Expected result:

- `res.ok` is `false`.
- The message states that `origin={x=0,y=0,z=0}` with `absolute=false` would
  build at world origin and that player-local builds should omit `origin` or
  use `origin="player"`.

What failure means:

- The model-facing node-printer contract is still ambiguous or too close to the
  legacy rows/boxes representation.
- Player-relative placement is not enforced consistently between prompt
  context and engine validation.
- The agent is treating successful interpretation or preview as task completion
  without executing the interpreted plan.

Related subsystem/files:

- `skills/worldedit_agent/worldedit_agent.lua`
- `agent/agent_context.lua`
- `agent/agent_flow.lua`

## 19. Truncated Lua Action Continuation

Required config/settings:

- Player has `llm`, `llm_agent`, and at least one active Lua-first skill.
- Recommended evidence settings:
  `llm_live_trace_chat = true`,
  `llm_live_trace_show_lua = true`,
  `llm_trace_prompt_log = true`.

Failure scenario to watch for:

- Provider returns `finish_reason="length"` while the response contains an
  opening ```lua_action fence without a closing fence.
- Parser reports `actions=0`.

Expected trace/log evidence:

- The run must not finish with `reason="no_continuation_requested"`.
- `agent_flow` should schedule `truncated_action_retry`.
- The next iteration should receive an action-history failure saying the
  `lua_action` block was truncated and should retry with one concise complete
  action block.
- No incomplete Lua body should be executed.

What failure means:

- Parser/flow treated an incomplete hidden action as normal visible chat.
- The agent stopped after planning text even though an imperative task was
  still unresolved.

Related subsystem/files:

- `agent/parser_utils.lua`
- `agent/agent_runtime.lua`
- `agent/agent_flow.lua`

## 20. Node Printer Voxel-CSG Surface Patches

Required config/settings:

- Player has `llm`, `llm_agent`.
- `node_printer_preview` is attached to the player.
- LLM provider configured.
- Recommended evidence settings:
  `llm_live_trace_chat = true`,
  `llm_live_trace_show_lua = true`,
  `llm_trace_prompt_log = true`.

In-game prompt/action:

```text
/llm lade die node printer dokumentation und baue danach eine kleine steinhuette mit hohler schale, holzdach, zwei glas-inlays, einem eingang und einem farbigen streifen auf der rechten wand
```

Expected trace/log evidence:

- The context load uses `skills.node_printer_preview`, `node_printer`, or another
  registered alias that resolves to `skills.node_printer_preview`.
- The build uses `llm_connect.skills.node_printer_preview.run("<tool>", args, player_name)`.
- For this ordinary material request, the model may use common registered nodes
  directly, such as `default:stone`, `default:wood`, `default:glass`, and
  `default:brick`; it should not require `asset_search` before building.
- The plan uses ordered voxel-CSG operations with `ops = {...}` and at least:
  `solid`, `shell`, `cut`, and `paint`.
- The plan uses `shape="patch"` for surface-relative features instead of
  object-specific helpers. Expected examples:
  - a `cut` patch on the front face for the entrance,
  - `paint` patches on a face for glass inlays,
  - a `paint` patch on another face for a decorative strip or panel.
- The patch schema is surface-relative and mathematical:
  `on={shape="box", at={x=...,y=...,z=...}, size={x=...,y=...,z=...}, face="front|back|left|right|top|bottom"}`,
  `at={u=...,v=...}`, `size={u=...,v=...}`, and optional `depth=N`.
- No generated plan should call object-specific helpers such as `set_door`,
  `set_window`, `door`, `window`, `roof`, `build_house`, or `build_hut`.
- `preview_build` succeeds before `print_build`, or the same action block checks
  `preview_build` successfully before executing `print_build`.
- `debug.txt` contains a `node_printer_preview` verification line similar to
  `print_build verified ... origin=... min=... max=...`.
- The final structure appears near the player position, with visible non-air
  writes and at least one cut-through opening.

Direct API regression check:

```lua
local shell = {x=-4, y=1, z=-3}
local shell_size = {x=9, y=5, z=7}
local build = {
  anchor = "player",
  ops = {
    {op="solid", shape="box", at={x=-4,y=0,z=-3}, size={x=9,y=1,z=7}, node="default:stone"},
    {op="shell", shape="box", at=shell, size=shell_size, node="default:stone"},
    {op="solid", shape="box", at={x=-5,y=6,z=-4}, size={x=11,y=1,z=9}, node="default:wood"},
    {op="cut", shape="patch", on={shape="box", at=shell, size=shell_size, face="front"}, at={u=4,v=0}, size={u=1,v=3}, depth=1},
    {op="paint", shape="patch", on={shape="box", at=shell, size=shell_size, face="front"}, at={u=2,v=2}, size={u=1,v=1}, depth=1, node="default:glass"},
    {op="paint", shape="patch", on={shape="box", at=shell, size=shell_size, face="right"}, at={u=2,v=2}, size={u=3,v=1}, depth=1, node="default:wood"},
  },
  max_nodes = 20000,
}
local res = llm_connect.skills.node_printer_preview.run("preview_build", build, player_name)
return {done = true, message = tostring(res.ok) .. " " .. tostring(res.message)}
```

Expected result:

- `res.ok` is `true`.
- `res.data.operations` is `6`.
- `res.data.materials` includes `default:stone`, `default:wood`,
  `default:glass`, and `air`.
- An equivalent `print_build` verifies all writes or returns `ok=false` with a
  concrete verification failure.

What failure means:

- The manual did not make surface patches clear enough for the model.
- Patch coordinate validation is accepting out-of-face writes or rejecting valid
  face-local rectangles.
- The model is falling back to object-specific helpers instead of universal CSG
  operations.

Related subsystem/files:

- `skills/node_printer_preview/node_printer_preview.lua`

## 21. Node Printer Optional Semantic Asset Search

Required config/settings:

- Player has `llm`, `llm_agent`.
- `node_printer_preview` is attached to the player.
- LLM provider configured.
- Recommended evidence settings:
  `llm_live_trace_chat = true`,
  `llm_live_trace_show_lua = true`,
  `llm_trace_prompt_log = true`.

In-game prompt/action:

```text
/llm lade die node printer dokumentation und suche ein registriertes material fuer eine kupferne oder metallische zierleiste
```

Expected trace/log evidence:

- The model calls `llm_connect.skills.node_printer_preview.run("asset_search", ...)`
  only because the requested material is unusual or uncertain.
- The search query is semantic. It may be a single string such as
  `copper metal`, or a multi-string query such as
  `queries={"copper", "metal"}`.
- The response reports a returned registered node name instead of inventing a
  node such as `default:copper_block` unless it appears in the results.

Direct API regression check:

```lua
local search = llm_connect.skills.node_printer_preview.run("asset_search", {
  queries = {"copper", "metal"},
  limit = 8,
}, player_name)
if not (search and search.ok) then
  return {done = true, message = search and search.message or "asset_search failed"}
end
local first = search.first or (search.data and search.data.results and search.data.results[1])
return {
  done = true,
  message = "asset_search ok=" .. tostring(search.ok)
      .. " count=" .. tostring(search.data and search.data.count)
      .. " node=" .. tostring(search.node)
      .. " first=" .. tostring(first and first.name),
}
```

Expected result:

- `search.ok` is `true`.
- `search.data.count` is greater than `0` in a normal Minetest Game-compatible
  world with default nodes.
- Every returned result name exists in `core.registered_nodes`.
- `search.node`, `search.first`, `search.results`, `search.matches`, and
  `search.data.results` all expose the same first/result list semantics for
  model-friendly extraction.
- If the result is used in a follow-up build, the returned node name passes
  `preview_build` material validation.

What failure means:

- The optional material search is broken for unusual material requests.
- `asset_search` is returning unavailable nodes or overly broad/noisy matches.
- The model is still guessing unusual materials instead of grounding them in the
  active node registry.

Related subsystem/files:

- `skills/node_printer_preview/node_printer_preview.lua`
