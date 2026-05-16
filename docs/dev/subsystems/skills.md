# Skills Subsystem

## Zweck

Registers Lua-first capabilities that the agent can use when explicitly
attached to a player.

## Public Contract

- Registry lives under `llm_connect.registry` and skill APIs under
  `llm_connect.skills.<skill_id>`.
- Skills are globally registered but per-player effective availability depends
  on privileges and attachment state.
- Skill return tables should use:
  `{ ok=boolean, success=boolean, message=string, data=table }`.
- Skill manuals are exposed as context sections such as
  `skills.command_agent` and `skills.worldedit_agent`.

## Nicht-Ziele

- Skills should not bypass runtime policy.
- Skills should not depend on old JSON toolcall dispatch.
- Skills should not expose many ambiguous aliases as the preferred API.

## Datenfluss

1. `skills_init.lua` initializes the registry.
2. `skills/registry.lua` loads internal Lua-first skill files explicitly.
3. Each skill registers metadata, availability, context section, and public API.
4. Agent prompt builder lists active attached skills.
5. Action code calls `llm_connect.skills.<skill_id>...`.

## Current Internal Skills

- `command_agent`: controlled command facade and chatcommand fallback.
- `worldedit_agent`: WorldEdit bridge with high-level builders and primitives.

## Skill Contracts

### command_agent

Preferred calls:

```lua
llm_connect.skills.command_agent.set_time({ time = 18000 }, player_name)
llm_connect.skills.command_agent.run("set_time", { time = 18000 }, player_name)
llm_connect.skills.command_agent.list_chatcommands({ only_allowed = true }, player_name)
llm_connect.skills.command_agent.run_chatcommand({ command = "/time 18000" }, player_name)
```

Avoid:

```lua
core.set_time(18000)
llm_connect.skills.command_agent.execute(...)
```

`execute(...)` exists only as a compatibility alias for model mistakes.

### worldedit_agent

Preferred calls:

```lua
llm_connect.skills.worldedit_agent.run("build_house", {
  width = 7,
  length = 7,
  height = 4,
  wall = "default:stone",
  floor = "default:cobble",
  roof = "default:wood",
}, player_name)

llm_connect.skills.worldedit_agent.run("cube", {
  width = 5,
  height = 3,
  length = 5,
  node = "default:stone",
  hollow = false,
}, player_name)
```

Avoid direct guesses such as `set_nodes(...)`. Compatibility fallbacks may exist
but should not be presented as normal API.

## Settings

- `llm_agent_enabled` gates whether agent execution may run.
- Skill attachment is currently runtime memory, not persistent config.

## Fehlerbilder

- Active skill listed but action cannot call it: check attachment state,
  privilege, and sandbox exposure.
- Model calls nonexistent methods: context manual is too vague or stale.
- WorldEdit primitive fails after partial build: action did not check each
  return value or used unsupported args.

## Tests / Smoke Checks

- `/llm_skill_list singleplayer`
- Attach/detach each internal skill and verify active skill count in trace.
- Agent prompt: set time to `18000`; expect `command_agent.set_time` or
  `run_chatcommand`, not `core.set_time`.
- Agent prompt: build a small house; prefer `build_house` or `build_hut`.

## Offene Risiken

- `command_agent` is still partly a compatibility bridge from older JSON-era
  design and needs a 1.3 contract pass.
- `worldedit_agent` exposes many primitives; complex model-generated plans can
  still fail midway.
- Runtime-only skill attachment state can surprise after restart.
