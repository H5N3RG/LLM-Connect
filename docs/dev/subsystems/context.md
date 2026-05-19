# Context Subsystem

## Zweck

Provides focused runtime documentation to the agent without injecting every
manual into every prompt.

## Public Contract

- Public facade: `llm_connect.context`.
- Common calls:
  `load(key)`, `lookup(key)`, `get_section(id)`, `search(query)`,
  `list_sections()`, `keys()`, `has(key)`.
- `load()`, `lookup()`, and `get_section()` return:
  `{ ok, id, title, summary, content, message }`.
- Documentation text is in `content`; callers must not expect parsed fields such
  as `doc.commands` or `doc.api`.
- `search()` returns an object shaped like
  `{ ok=true, count=n, sections={...} }`.

## Nicht-Ziele

- Context is not a tool executor.
- Context should not carry large generated plans or hidden mutable state.
- Context should not silently grant privileges.

## Datenfluss

1. `context_registry.lua` registers static and provider-backed sections.
2. `context_init.lua` exposes normalized public functions.
3. Agent action calls `llm_connect.context.load(...)`.
4. Successful context loads are remembered per player.
5. `agent_context.lua` injects retrieved context into the next prompt.

## Settings

No direct settings currently. Context behavior is affected by agent and trace
settings.

## Fehlerbilder

- Permission failure despite root: check effective player resolution in
  `context_init.lua` and sandbox `_G.player_name` handling.
- Model reads `doc.commands`: prompt/context contract is stale.
- Context lookup succeeds but next iteration lacks docs: check
  `remember_recent_context()` and `agent_context.lua`.

## Tests / Smoke Checks

- Agent prompt: load `skills.command_agent`, then call a documented command
  function in the next iteration.
- Agent prompt: call `llm_connect.context.load('worldedit')`; next prompt should
  contain cached WorldEdit manual.
- `luajit -b context/context_registry.lua /tmp/context_registry.luac`
- `luajit -b context/context_init.lua /tmp/context_init.luac`

## Offene Risiken

- Retrieved context can become stale if player position or skill availability
  changes mid-run.
- Large failed action histories can crowd out useful context.
- Search fallback can still encourage broad, imprecise model behavior.
