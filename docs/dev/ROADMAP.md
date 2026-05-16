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
- `command_agent` exposes stable Lua-first helpers for common command tasks,
  especially `set_time({time=...}, player_name)`.
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
- Startup failure before `[llm_connect] LLM Connect 1.2.0-dev init complete`.
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
- `command_agent` becomes a small command facade with direct helpers for common
  server operations and a fallback chatcommand bridge.
- `worldedit_agent` groups high-level builders separately from low-level
  primitives and optional WorldEditAdditions tools.
- Agent prompt builder renders skill capabilities from these contracts without
  inventing APIs.

Should have:

- Common return format across skills:
  `{ ok=boolean, success=boolean, message=string, data=table }`.
- Tool availability exposed to context, including why a tool is unavailable.
- Compatibility aliases logged as compatibility use, not preferred API.

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

## Later

- Automated Luanti integration harness for repeatable agent scenarios.
- Better world-operation rollback/snapshot UX.
- Richer building planners above `worldedit_agent`.
- Persistent settings migration tooling.
