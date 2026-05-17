# Skills Subsystem

## Zweck

Registers Lua-first capabilities that the agent can use when explicitly
attached to a player. The engine discovers skills structurally; each skill owns
its own id, label, aliases, context manual, and public API.

## Public Contract

- Registry lives under `llm_connect.registry` and skill APIs under
  `llm_connect.skills.<skill_id>`.
- Sandboxed agent code receives a restricted skill proxy, not the registry or
  the full skills facade.
- Skills are globally registered but per-player effective availability depends
  on privileges and attachment state.
- Skill return tables should use:
  `{ ok=boolean, success=boolean, message=string, data=table }`.
- Skill manuals are exposed as context sections registered by the skills.
- Skill directories are loaded through `skills/<folder>/init.lua` gateways.
- `llm_connect.skill_registry` is the preferred registry/admin facade name.
  Full namespace separation is still transitional for compatibility.

## Nicht-Ziele

- Skills should not bypass runtime policy.
- Skills should not depend on old JSON toolcall dispatch.
- Engine code should not hardcode concrete skill ids, aliases, manuals, or API
  shapes.
- Skills should not expose many ambiguous aliases as the preferred API.

## Datenfluss

1. `skills_init.lua` initializes the registry.
2. `skills/registry.lua` scans `skills/*/init.lua` gateway files
   generically.
3. Each gateway loads its skill implementation.
4. Each skill registers metadata, availability, context aliases, context
   section, and public API.
5. Agent prompt builder lists active attached skills from registry metadata.
6. Runtime builds a sandbox proxy containing only active, privilege-validated
   skill APIs.
7. Action code calls `llm_connect.skills.<skill_id>...`.

## Current Internal Skills

- `command_agent`: Runtime Agent, controlled Lua execution and direct helpers
  with chatcommand fallback.
- `worldedit_agent`: Node Printer, native batch node placement with high-level
  builders and WorldEdit bridge compatibility.

## Skill Contracts

### command_agent

Preferred calls:

```lua
llm_connect.skills.command_agent.execute_lua({
  code = "return { done=true, message='ok' }",
}, player_name)
llm_connect.skills.command_agent.precheck_lua({ code = "return 1" }, player_name)
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
`execute_lua(...)` routes through `llm_connect.runtime.execute` and must keep
runtime policy, precheck, and sandbox behavior authoritative.

### worldedit_agent

Preferred calls:

```lua
llm_connect.skills.worldedit_agent.run("print_plan", {
  boxes = {
    { x = -3, y = 0, z = -3, width = 7, height = 1, length = 7, node = "default:stone" },
  },
  rows = {
    { x = -2, y = 1, z = -3, axis = "x", length = 5, node = "default:wood" },
  },
  nodes = {
    { x = 0, y = 2, z = -3, node = "default:glass" },
  },
}, player_name)

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

`print_plan` coordinates are relative to the player's integer position unless
`absolute=true` or `origin={x=...,y=...,z=...}` is supplied. Use `preview_plan`
for dry-run validation and `max_nodes` to cap write volume.

Avoid direct guesses such as `set_nodes(...)`. Compatibility fallbacks may
exist but should not be presented as normal API.

## Settings

- `llm_agent_enabled` gates whether agent execution may run.
- Skill attachment is currently runtime memory, not persistent config.

## Fehlerbilder

- Active skill listed but action cannot call it: check attachment state,
  privilege, and sandbox exposure.
- Skill appears attached but is not available in sandbox: check `required_priv`;
  manual attachment does not bypass privileges.
- Model calls nonexistent methods: context manual is too vague or stale.
- WorldEdit primitive fails after partial build: action did not check each
  return value or used unsupported args.

## Tests / Smoke Checks

- `/llm_skill_list singleplayer`
- Attach/detach each internal skill and verify active skill count in trace.
- Agent prompt: set time to `18000`; expect `command_agent.set_time`, not
  `core.set_time`.
- Agent prompt: execute a tiny runtime-safe Lua action; expect
  `command_agent.execute_lua`.
- Agent prompt: build a custom multi-part structure; prefer `print_plan` or a
  high-level builder.

## Offene Risiken

- `command_agent` still exposes chatcommand fallback compatibility aliases.
- `worldedit_agent` still exposes WorldEdit bridge primitives; complex
  generated plans should prefer validated `preview_plan`/`print_plan`.
- Runtime-only skill attachment state can surprise after restart.
