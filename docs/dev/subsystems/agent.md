# Agent Subsystem

## Zweck

Runs the dual-channel agent loop: visible assistant text plus hidden
`lua_action` blocks executed through the runtime.

## Public Contract

- Agent prompts must describe the exact `lua_action` fence format.
- Action code receives `player_name`, safe `core` / `minetest`,
  `llm_connect.context`, and attached skills under `llm_connect.skills`.
- Actions finish with `{ done=true, message="..." }`.
- Actions request another iteration with
  `{ done=false, continue=true, message="..." }`.
- Failed actions may trigger repair retries through `agent_flow.lua`.

## Nicht-Ziele

- Skill implementation details do not belong in the agent loop.
- JSON-heavy tool dispatch should not be reintroduced.
- User clarification pauses are not implemented yet; see `ROADMAP.md`.

## Datenfluss

1. GUI/chat dispatch calls the agent runtime.
2. `agent_communication.lua` reads external subsystem state for the agent.
3. `agent_context.lua` builds system prompt, basic context, active skill
   summary, and cached retrieved context.
4. `api/llm_api.lua` sends the request and records trace output when enabled.
5. `parser_utils.lua` extracts `lua_action` blocks.
6. `agent_runtime.lua` executes actions through `runtime/core_executor.lua`.
7. `agent_flow.lua` decides stop, continue, context continuation, or repair retry.

## Settings

- `llm_agent_enabled`
- `llm_agent_max_iterations`
- `llm_agent_max_repair_retries`
- `llm_timeout_agent`
- `llm_live_trace_chat`
- `llm_live_trace_show_lua`
- `llm_live_trace_verbosity`
- `llm_live_trace_categories`

## Fehlerbilder

- `player_name` nil: sandbox/root-unrestricted execution did not propagate the
  active player.
- Repeated context loads: model is not acting on cached context or prompt does
  not make the next step clear.
- `agent aborted` after provider error: inspect response prompt log for HTTP
  status such as `429 Rate limit exceeded`.
- Model asks a visible question and continues anyway: expected until
  `await_user=true` support exists.

## Tests / Smoke Checks

- `luajit -b agent/agent_runtime.lua /tmp/agent_runtime.luac`
- Run a prompt that first loads `skills.worldedit_agent`, then acts in the next
  iteration.
- Disable `llm_agent_enabled` and verify no action executes.
- Force one bad action and verify repair count respects
  `llm_agent_max_repair_retries`.

## Offene Risiken

- Iteration repair can amplify provider rate-limit pressure.
- Visible text may overpromise before hidden actions actually succeed.
- User-in-the-loop clarification is not yet represented in the action contract.
