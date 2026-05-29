# ISSUES.md

# LLM-Connect 1.2.0 Main Merge Finalization Roadmap

**Branch:** `dev/1.2.0`
**Goal:** stabilize and merge into `main`
**Method:** atomic implementation blocks + isolated validation + review + commit

---

# CURRENT EXECUTION MODEL

Every architecture change is handled as:

```text
implement block
→ test block in isolation
→ stop
→ developer review
→ commit if accepted
→ continue with next block
```

No giant multi-system migration commits.

---

# BLOCK OVERVIEW

| Block | Name                                  | Status  |
| ----- | ------------------------------------- | ------- |
| 1     | Skill-module-refactor                 | ACTIVE  |
| 2     | Externalize mapgen_painter            | PENDING |
| 3     | Context prompt externalization        | PENDING |
| 4     | IDE cleanup / ide_gui reduction       | PENDING |
| 5     | Documentation archive + merge cleanup | PENDING |
| 6     | Final merge validation                | PENDING |

---

# BLOCK 1 — Skill-module-refactor

## Goal

Stabilize the external skill ABI and provenance handling.

## Key objectives

* deterministic external skill registration;
* provenance metadata (`origin`, `provider_mod`);
* validation/reporting layer;
* preserve sandbox ABI;
* preserve canonical:

```lua
llm_connect.skills.<skill_id>.run(...)
```

## Deliverables

* hardened `register_skill()`
* structured `discover_external()`
* external fixture probe mod
* external provenance reporting

## Validation target

External fixture loads as normal Luanti mod and appears in registry/report without auto-enable behavior.

---

# BLOCK 2 — Externalize mapgen_painter

## Goal

Remove `mapgen_painter` from internal core skills and prove that a real external skill mod can load through the new ABI.

## Planned operations

* remove internal `skills/mapgen_painter/` loading from core distribution;
* create standalone Luanti mod:

```text
llm_connect_mapgen_painter/
```

* preserve:

  * registry registration
  * context registration
  * canonical runtime ABI

## Validation target

* external mod loads correctly;
* appears as external skill;
* context section available;
* queue/preview/list still work;
* no core regressions.

## Explicitly NOT part of this block

* redesigning mapgen algorithms;
* adding geometry primitives;
* advanced permission architecture.

---

# BLOCK 3 — Context prompt externalization

## Goal

Move raw prompt semantics out of Lua source into external `.txt` prompt assets.

## Current problem

Prompt logic is still embedded inside:

```text
context/basic_context.lua
context/context_registry.lua
gui/ide_system_prompts.lua
```

making:

* maintenance harder;
* prompt iteration noisy;
* architecture boundaries unclear.

## Planned target structure

```text
context/
├── prompt_router.lua
└── prompts/
    ├── chat_system.txt
    ├── agent_runtime_contract.txt
    ├── context_api.txt
    └── safe_core_api.txt
```

Potential later extension:

```text
gui/prompts/
```

for IDE prompt assets.

## Requirements

* deterministic file loading;
* caching;
* graceful fallback on missing prompt files;
* no `dofile()` for plain text assets.

## Validation target

* agent/chat behavior unchanged;
* prompts editable without Lua edits;
* no runtime crashes on missing prompt files.

---

# BLOCK 4 — IDE cleanup / ide_gui reduction

## Goal

Reduce monolithic legacy logic inside:

```text
gui/ide_gui.lua
```

## Known issues

* legacy snippet/index handling duplicated;
* mixed responsibilities;
* leftover 0.9/1.0 architecture assumptions.

## Planned focus

* remove dead legacy helpers;
* consolidate storage handling;
* reduce duplicated file-management logic;
* preserve current runtime behavior.

## Important constraint

This is NOT a complete IDE rewrite.

The goal is stabilization and maintainability before merge.

---

# BLOCK 5 — Documentation archive + merge cleanup

## Goal

Reduce historical noise before merge into `main`.

## Planned operations

* identify outdated planning docs;
* move obsolete development artifacts into archive area or external backup;
* keep only relevant developer/runtime docs;
* refresh README for 1.2.0 architecture.

## Likely candidates for archive/review

```text
docs/dev/PATCH_AGENDA_CONTEXT_ORCHESTRATION.md
docs/dev/PLAN_OPTIONS.md
```

## Must preserve

* runtime architecture explanation;
* skill ABI documentation;
* testing docs;
* context system docs.

---

# BLOCK 6 — Final merge validation

## Goal

Perform final stabilization before merge into `main`.

## Planned checks

* startup validation;
* runtime regression tests;
* agent-loop smoke tests;
* IDE smoke tests;
* external skill loading validation;
* context retrieval validation;
* privilege enforcement validation.

## Final review focus

* branch cleanliness;
* dead files;
* stale aliases/comments;
* startup warnings;
* deterministic subsystem loading.

---

# NON-BLOCKING BACKLOG (POST-MERGE)

The following are intentionally NOT merge blockers for 1.2.0.

## command_agent redesign

Long-term goal:

* move away from legacy chatcommand-wrapper behavior;
* evolve toward true runtime-native primitives.

---

## worldedit_agent redesign

Long-term goal:

* replace macro wrappers with low-level structured node primitives;
* eventually support declarative build specifications.

---

## Agent-loop await_user architecture

Future planned semantic split:

```lua
await_user = true
```

vs.

```lua
request_permission(...)
```

Currently not finalized.

---

## Permission-gated dangerous actions

Future work:

* explicit Permit/Deny flows for high-risk world operations.

---

## Advanced mapgen primitives

Future possible primitives:

```text
cylinder
sphere
river_path
heightmap_patch
noise_mountain
```

Not part of 1.2.0 merge stabilization.
