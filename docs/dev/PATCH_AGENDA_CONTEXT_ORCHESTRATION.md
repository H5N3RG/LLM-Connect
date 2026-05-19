# Patch Agenda — Context/WorldEdit Orchestration Stabilization

## Goal

Stop the agent from treating `context.search()` as a probabilistic Google/RAG layer and replace the normal path with exact glossary-style context lookup.

The agent should prefer stable IDs and aliases, use high-level WorldEdit/building primitives for natural-language building tasks, and stop looping when context lookup returns nothing useful.

---

## Phase 1 — Replace semantic-first context retrieval with glossary-first lookup

### Problem

`llm_connect.context.search(query)` returns a structured object:

```lua
{
  ok = true,
  query = "worldedit",
  count = 1,
  sections = {
    { id = "skills.worldedit_agent", title = "...", summary = "...", tags = {...}, score = 1 }
  },
  message = "Context search hits: 1"
}
```

It is not an array, not a string, and not loaded documentation.

Models were doing:

```lua
local sections = llm_connect.context.search("worldedit_agent")
sections[1] -- wrong
#sections    -- wrong
"..." .. sections -- wrong
```

### Patch

Add exact-context APIs:

```lua
llm_connect.context.keys()
llm_connect.context.has(key)
llm_connect.context.lookup(key, args)
llm_connect.context.load(key, args)
llm_connect.context.search_first(query, opts)
```

Add glossary aliases:

```lua
worldedit       -> skills.worldedit_agent
worldedit_agent -> skills.worldedit_agent
building        -> skills.worldedit_agent
commands        -> skills.command_agent
command_agent   -> skills.command_agent
nodes           -> luanti.registered_nodes.preview
materials       -> luanti.registered_nodes.preview
server          -> server.info
player          -> server.info
position        -> server.info
api             -> luanti.safe_core
core            -> luanti.safe_core
```

---

## Phase 2 — Fix prompt contract

### Problem

The prompt mentioned context functions but did not show the actual return shape, which pushed models into broken table handling.

### Patch

Prompt now says:

- Prefer `load()` / `lookup()` over `search()`.
- Use glossary aliases first.
- `search()` is fallback only.
- `search()` returns `{ok,count,sections={...}}`, not an array/string.

---

## Phase 3 — Stop empty context loops

### Problem

Any successful lua_action containing `llm_connect.context` was forced into `continue=true`, even if the lookup failed or returned zero hits.

### Patch

Context actions now continue only when they return useful content or hits:

- loaded content → continue
- search/list hits → continue
- failed lookup → stop
- empty search → stop
- malformed result → stop

---

## Phase 4 — Do not inject search summaries as full docs

### Problem

Search result summaries were cached as if they were full context documentation.

### Patch

The context cache now only stores sections that contain real `content`.

---

## Phase 5 — Add agent-friendly WorldEdit building primitives

### Problem

For building requests, models either guessed low-level WorldEdit calls or bypassed the skill with raw `core.set_node` loops.

### Patch

Added high-level tools to `worldedit_agent`:

```lua
build_hut
build_house
build_tower
build_platform
```

These are now the preferred calls for natural-language building tasks.

Example:

```lua
return llm_connect.skills.worldedit_agent.run('build_house', {
  width = 7,
  length = 7,
  height = 4,
  wall = 'default:wood',
  floor = 'default:stone',
  roof = 'default:cobble'
}, player_name)
```

---

## Files changed

```text
context/context_registry.lua
agent/agent_context.lua
agent/agent_runtime.lua
agent/agent_flow.lua
agent/agent_context.lua
skills/worldedit_agent/worldedit_agent.lua
```

---

## Test checklist

1. Ask: `was für tools hast du?`
   - Expected: plain explanation, no lua_action.

2. Ask: `lade die worldedit doku`
   - Expected: `llm_connect.context.load('worldedit')`, then one continuation.

3. Ask: `kannst du eine simple hütte bauen?`
   - Expected: `worldedit_agent.run('build_hut', {}, player_name)`.

4. Ask: `bau was komplexeres, sei kreativ`
   - Expected: high-level builder first (`build_house`, `build_tower`, or platform + tower), not raw context search loop.

5. Force unknown context query.
   - Expected: no 32-iteration spiral; stop after empty lookup/search.
