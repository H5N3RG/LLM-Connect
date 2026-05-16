# Runtime Subsystem

## Zweck

Executes user/agent Lua actions with policy checks, sandboxing, trace output,
and controlled root overrides.

## Public Contract

- Public executor is reached through `llm_connect.runtime.execute(...)` or the
  compatibility executor exposed by runtime init.
- Agent actions are tagged with purpose/origin and required privilege.
- Safe runtime provides a subset of `core` / `minetest`.
- Host access is blocked: `io`, `require`, `dofile`, `loadfile`, `load`,
  `loadstring`, `debug`, and `package`.
- Runtime registrations are blocked: node/tool/craftitem/entity/craft
  registration is load-time only.
- `core.set_time` is not part of the safe runtime API; use
  `llm_connect.skills.command_agent.set_time({time=...}, player_name)` when
  `command_agent` is active.

## Nicht-Ziele

- Runtime should not know skill-specific semantics.
- Runtime should not broaden root behavior silently.
- Runtime-safe scripts are not trusted worldmods.

## Datenfluss

1. Agent or GUI submits Lua source and execution metadata.
2. Execution policy resolves privileges and root override settings.
3. Parser/precheck rejects forbidden host or registration patterns.
4. `core_executor.lua` creates sandbox environment.
5. Source runs under `xpcall`.
6. Result table, output, and errors flow back to caller and live trace.

## Settings

- `llm_root_agent_unrestricted`
- `llm_root_bypass_safety_filters`
- `llm_root_allow_startup_execution`
- `llm_ide_startup_preferred`
- `llm_ide_backend`

## Fehlerbilder

- `attempt to call field 'set_time'`: model guessed unavailable safe-core API.
- Undeclared globals in storage modules: dependency binding is relying on global
  names instead of `llm_connect.*`.
- Root action behaves differently from normal action: check
  `llm_root_agent_unrestricted` and `_G.player_name` propagation.

## Tests / Smoke Checks

- `luajit -b runtime/core_executor.lua /tmp/core_executor.luac`
- Run a tiny runtime-safe script that reads player position.
- Verify registration attempts are blocked.
- Verify root-unrestricted mode still supplies `player_name`.

## Offene Risiken

- Safe-core API documentation can drift from the actual sandbox.
- Root override settings are powerful and must stay opt-in.
- Startup-preferred code paths need strict separation from runtime-safe actions.
