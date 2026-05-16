# PLAN_OPTIONS.md - Decisions Needing User Approval

This file exists because the current session did not have an interactive
confirmation tool available, and several future implementation choices are
architectural rather than mechanical bug fixes.

## Decision 1: WorldEdit API Compatibility

Problem:

- Runtime logs show the model called
  `llm_connect.skills.worldedit_agent.set_nodes(...)`.
- The implemented public API is
  `llm_connect.skills.worldedit_agent.run(tool, args, player_name)`.

Option A: Prompt/context only

- Tighten prompt and context documentation so the model sees only `run(...)`.
- Do not add compatibility wrappers.
- Pros: smallest API surface; reduces long-term ambiguity.
- Cons: weaker models may still hallucinate direct helper names.

Option B: Add narrow compatibility wrappers

- Add wrappers such as `set_region(args, player_name)` or
  `set_nodes(region, node, player_name)` that delegate to supported tools.
- Pros: makes common hallucinations less catastrophic.
- Cons: expands public API and can hide prompt quality problems.

Option C: Add explicit API error helpers

- Add functions for common wrong names that return a clear structured error:
  `use worldedit_agent.run('set_region', {node=...}, player_name)`.
- Pros: improves repair loop without actually supporting the wrong API.
- Cons: still expands visible API surface.

Recommended default:

- Option A first. Consider Option C only if manual tests show repeated
  hallucination after prompt cleanup.

## Decision 2: Root Agent Execution Defaults

Problem:

- `llm_root` is intended to be powerful, but current code keeps root agent
  actions sandboxed unless explicit settings opt into unrestricted execution.

Option A: Keep current explicit opt-in defaults

- Root implies privileges but not unrestricted agent execution by default.
- Use `llm_root_agent_unrestricted`, `llm_root_bypass_safety_filters`, and
  `llm_root_allow_startup_execution`.
- Pros: safer default for accidental agent prompts.
- Cons: "root means root" is less literal until settings are enabled.

Option B: Make `llm_root` unrestricted by default

- Root agent actions run unsandboxed and bypass filters unless disabled.
- Pros: matches a literal root model.
- Cons: high blast radius from model mistakes.

Option C: Split root profiles

- Keep `llm_root` as privileged but sandboxed.
- Add a separate setting/profile such as `llm_superroot` or an in-game
  per-session toggle for unrestricted actions.
- Pros: explicit escalation in UI.
- Cons: more policy and UI complexity.

Recommended default:

- Option A unless the owner explicitly wants root actions to be unsandboxed by
  default.

## Decision 3: Skill Attachment Persistence

Problem:

- Skill attachment state currently lives in runtime memory through
  `M.player_skill_overrides`.
- It is not clear whether attachments should persist across server restarts.

Option A: Runtime-only attachment

- Attachments reset on restart.
- Pros: simple and safer while the skill system is evolving.
- Cons: repeated manual setup after restart.

Option B: Persist per-world attachment state

- Store target-player skill attachments in world storage.
- Pros: expected admin workflow for stable worlds.
- Cons: requires migration/versioning and clear reset UI.

Option C: Persist defaults only

- Global default skill states persist; per-player overrides remain runtime-only.
- Pros: avoids per-player state complexity.
- Cons: less precise for multiplayer.

Recommended default:

- Option A until skill UX is stable; revisit before release.

## Decision 4: Live Trace UI Scope

Problem:

- `agent/live_trace.lua` has an in-game trace formspec and chat stream.
- `gui/config_gui.lua` also has live trace controls.

Option A: Keep trace panel minimal

- Current trace panel remains a read-only buffer with refresh/clear.
- Pros: small implementation, low formspec risk.
- Cons: category filtering remains mostly settings-driven.

Option B: Add full trace controls into trace panel

- Add category toggles, verbosity selector, raw Lua toggle, and enable toggle
  directly to `llm_connect:live_trace`.
- Pros: better debugging workflow.
- Cons: more formspec complexity and more chance of UI parsing bugs.

Option C: Keep controls only in config GUI

- Trace panel only displays buffer; config GUI owns all settings.
- Pros: clearer ownership.
- Cons: more clicks during active debugging.

Recommended default:

- Option C until the config tooltip bug is fixed, then consider Option B.

## Decision 5: Context Continuation Policy

Problem:

- Successful context lookups currently request continuation so the agent can use
  newly loaded context in the next LLM turn.
- Repeated context-only loops waste tokens and iterations.

Option A: Keep continuation as-is

- Rely on model behavior and max iteration limit.
- Pros: no behavior change.
- Cons: repeated lookup loops remain possible.

Option B: Cache and suppress repeated identical context loads

- If the same key/query is loaded twice in one task, return a stop decision or
  inject cached content without another continuation.
- Pros: targeted fix for observed risk.
- Cons: requires careful state signature logic.

Option C: Require explicit continuation flag from context calls

- Context load returns content but does not automatically continue unless the
  action asks for it.
- Pros: simpler middleware semantics.
- Cons: weaker models may stop after lookup without acting.

Recommended default:

- Option B.
