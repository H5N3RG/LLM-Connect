# LLM-Connect Roadmap

This roadmap is a maintenance aid, not a feature wish list. Keep it aligned
with runtime logs, `settingtypes.txt`, and the subsystem docs.

## 1.2.0 Stabilization

Goal:

Ship the Lua-first agent runtime as a usable development baseline with reliable
context lookup, skill attachment, traceability, and conservative safety gates.

Must have:

- Agent loop can load focused context, continue once, and use cached context in
  the next prompt.
- `player_name` is available in sandboxed and root-unrestricted agent actions.
- `command_agent` exposes stable Lua-first helpers through
  `run("<tool>", args, player_name)`, especially
  `run("set_time", {time=...}, player_name)`.
- `worldedit_agent` exposes a documented `run(tool, args, player_name)` API and
  rejects unknown nodes before WorldEdit calls.
- Config GUI Agent tab buttons, save/reload/test/close, and retry settings work.
- `llm_agent_enabled` actually gates agent execution.
- Retry limits are configurable through `settingtypes.txt` and config GUI.

Should have:

- Prompt/docs explicitly say `core.set_time` is not available in safe runtime.
- Agent docs discourage direct helper guesses like `set_nodes` and `execute`.
- Trace logs are sufficient to diagnose failed agent iterations without
  reproducing the run immediately.

Deferred:

- Interactive user questions between iterations.
- Persistent per-player skill attachment state.
- Full command-agent redesign beyond stable wrappers.
- Full automated integration test harness for Luanti runtime behavior.

Release blockers:

- Any syntax failure from `luajit -b` on project Lua files.
- Startup failure before `[llm_connect] LLM Connect 1.2.0 init complete`.
- Agent runs executing while `llm_agent_enabled=false`.
- Missing `player_name` in normal attached-skill agent actions.
- Config GUI Agent tab buttons not dispatching.

Manual test script:

- Run startup/health from `docs/dev/TESTS.md`.
- Attach `command_agent` and set time to `18000` through an agent prompt.
- Attach `worldedit_agent` and build a small house with a high-level builder.
- Open config API and Agent tabs, save each, reload, test API, close.
- Inspect the bottom of `debug.txt`, `llm_user_prompt_log.txt`, and
  `llm_response_prompt_log.txt`.

## 1.3.0 Skill Contracts

Goal:

Treat internal skills as stable Lua-first interfaces instead of compatibility
wrappers around older JSON/toolcall ideas.

Must have:

- Each skill has a subsystem-style contract: public functions, argument schema,
  return schema, examples, known model mistakes, and repair guidance.
- `command_agent` is the Runtime Agent: controlled runtime-safe Lua execution,
  direct helpers for common server operations, and a fallback chatcommand bridge.
- `worldedit_agent` is the Node Printer: native `print_plan` batch placement,
  high-level builders, and optional WorldEdit/WorldEditAdditions bridge tools.
- Agent prompt builder renders skill capabilities from these contracts without
  inventing APIs.

Should have:

- Common return format across skills:
  `{ ok=boolean, success=boolean, message=string, data=table }`.
- Tool availability exposed to context, including why a tool is unavailable.
- Compatibility aliases logged as compatibility use, not preferred API.
- Machine-readable tool manifests for each skill: tool name, argument schema,
  return schema, safety class, limits, examples, and repair hints.
- Prompt builder uses tool manifests instead of prose-only manuals where
  possible.

Deferred:

- Persistent skill settings UI.
- Skill marketplace or external skill discovery.
- Non-Lua tool calling.

Migration notes:

- Keep old compatibility aliases for one release where practical.
- Do not reintroduce JSON-heavy tool dispatch.
- Use docs to steer models away from deprecated aliases before removing them.

## 1.4.0 User-In-The-Loop Agent Runs

Goal:

Support deliberate user clarification without silently continuing an agent loop.

Must have:

- Explicit action return contract such as
  `{ done=false, await_user=true, message="..." }`.
- Runtime pauses the agent loop and stores resumable state.
- GUI/chat surfaces the question and resumes with the user's answer.
- Trace logs show pause, resume, and cancellation.

Deferred:

- Multi-user approval workflows.
- Long-lived background agents.

## 1.5.0 Agent Action Language

Goal:

Reduce free-form Lua generation by introducing a small declarative action
language for model-authored tool use. Lua remains the internal runtime, but the
model should usually emit one validated action spec instead of custom Lua
algorithms.

Rationale:

- Free-form Lua is too easy for models to misuse: invented APIs, variables
  shared across isolated `lua_action` blocks, oversized world operations, and
  visible planning text that does not correspond to completed work.
- Plain JSON is not expressive enough for Luanti agent workflows: actions need
  player-relative references, resumable workflow state, permissions, repair
  hints, and skill-specific defaults.
- A Lua-table envelope keeps Luanti integration simple while giving the model a
  constrained API surface.

Preferred shape:

```lua
return llm_connect.action({
  do_ = "mapgen_painter.terrain_scene",
  at = "@player",
  permit = "world_write",
  args = {
    style = "alpine",
    features = {
      { type = "mountain_ring", radius = 90, height = 45 },
      { type = "plateau", shape = "cylinder", radius = 28, height = 18 },
      { type = "lake", radius = 16, depth = 3 },
      { type = "rivers", count = 3, flow = "outward" },
    },
  },
})
```

Must have:

- `llm_connect.action(spec)` sandbox API with strict validation.
- Standard envelope fields: `do_`, `args`, `at`, `permit`, `continue`,
  `await_user`, and optional `id`.
- Router from `do_ = "skill.tool"` to the attached skill's manifest-backed
  tool dispatcher.
- Safety/permission integration before execution, including pending
  `Permit`/`Deny` GUI state.
- Clear error results designed for repair loops, not just human-readable
  failures.
- Prompt rule: prefer one documented action spec; avoid loops/custom
  algorithms unless explicitly needed.

Should have:

- Declarative references such as `@player`, `@selection`, `@look_target`, and
  relative offsets.
- Dry-run/preview convention for world writes.
- Step ledger rendering of the action spec summary.
- Conversion helpers so existing `skill.run(tool, args, player_name)` remains
  the execution backend.

Deferred:

- A text DSL separate from Lua-table syntax.
- General-purpose programming constructs in the action language.
- External network tools beyond existing provider/runtime boundaries.

Migration notes:

- Do not remove `lua_action`; narrow its preferred use to action envelopes and
  small glue code.
- Keep free-form Lua as a root/dev fallback, not the default model workflow.
- Skills with complex domains should expose high-level tools rather than
  forcing the model to hand-roll algorithms.

## 2.0.0 Luanti-First Maturity

Goal:

Reach a stable Luanti-focused agent platform with reliable multi-skill
workflows and a mature Smart Lua IDE experience. Until 2.0, do not introduce a
generic voxel-engine abstraction or architecture for hypothetical hosts.

Scope:

- Luanti remains the only implementation target before 2.0.
- Architecture work should serve concrete Luanti workflows: formspec GUI,
  chatcommands, mod storage, context lookup, skill routing, permissions,
  VoxelManip/world operations, and in-game development UX.
- Keep the core agent loop, action language, manifests, tracing, and provider
  clients cleanly separated from direct Luanti calls where that separation is
  already natural.
- Do not design a general host API for arbitrary voxel engines.
- Do not block Luanti features on future Minecraft portability.

Must have:

- Stable multi-skill workflow: attach skills, load context, select tools,
  execute actions, repair errors, request permission, resume, and summarize
  completion without losing the task thread.
- Smart Lua IDE: usable in-game/script workflow for inspecting available APIs,
  examples, action specs, recent errors, traces, and repair hints.
- Skill contracts and manifests are complete enough that the model can discover
  tools from local documentation instead of inventing APIs.
- Permission and safety model is consistent across world writes, command
  execution, mapgen operations, and future high-risk skills.
- Trace logs are structured enough to debug failed iterations without guessing
  whether the provider, prompt, executor, GUI, or skill caused the failure.

Deferred:

- Minecraft/Fabric/Forge/Paper port planning.
- Shared Luanti/Minecraft host adapter.
- Generic voxel-engine platform layer.
- External skill marketplace.

Revisit after 2.0:

- Evaluate a Minecraft port from real 2.0 contracts and logs, not from
  speculative abstractions.
- Extract shared concepts only if the second concrete host proves they are
  genuinely common.

## Later

- Automated Luanti integration harness for repeatable agent scenarios.
- Better world-operation rollback/snapshot UX.
- Richer building planners above `worldedit_agent`.
- Persistent settings migration tooling.
