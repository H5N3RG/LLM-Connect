# GUI And Settings Subsystem

## Zweck

Provides in-game configuration and exposes runtime settings without requiring
manual `minetest.conf` edits for every development test.

## Public Contract

- `gui/config_gui.lua` owns the root-only config formspec.
- `gui/main_gui.lua` owns the player-facing main GUI and agent dispatch.
- Runtime config changes are runtime-only unless explicitly persisted by
  Luanti settings behavior.
- Every user-facing setting should be represented in `settingtypes.txt` and, if
  practical, in the config GUI.

## Nicht-Ziele

- Config GUI should not become a hidden feature registry.
- Deprecated IDE settings should not be treated as active policy anchors.
- GUI controls should not silently bypass runtime policy checks.

## Datenfluss

1. Player opens `/llm_config`.
2. `config_gui.lua` builds API or Agent tab formspec.
3. `handle_fields()` routes tab switches, checkboxes, dropdowns, and bottom
   buttons.
4. Save writes API/runtime settings and redraws the active tab.
5. Main GUI dispatch checks `llm_agent_enabled` before starting an agent run.

## Settings

Important active settings:

- `llm_api_key`
- `llm_api_url`
- `llm_model`
- `llm_timeout`
- `llm_timeout_chat`
- `llm_timeout_ide`
- `llm_timeout_agent`
- `llm_agent_enabled`
- `llm_agent_max_iterations`
- `llm_agent_max_repair_retries`
- `llm_live_trace_chat`
- `llm_live_trace_show_lua`
- `llm_live_trace_verbosity`
- `llm_live_trace_categories`
- `llm_root_agent_unrestricted`
- `llm_root_bypass_safety_filters`
- `llm_root_allow_startup_execution`

Deprecated or compatibility settings must be marked clearly in
`settingtypes.txt`.

## Fehlerbilder

- Bottom buttons work in API tab but not Agent tab: an Agent-tab field handler
  is consuming button submissions before save/reload/test/close.
- `Invalid tooltip element`: tooltip text or field name is not formspec-safe.
- Save appears to work but runtime ignores setting: setting is visible but not
  checked by the runtime path.

## Tests / Smoke Checks

- Open `/llm_config`, switch API and Agent tabs.
- On each tab press Save, Reload, Test API, and Close.
- Change `llm_agent_max_repair_retries`, save, and verify repair logs use the
  configured maximum.
- Toggle `llm_agent_enabled=false` and verify agent dispatch is blocked.

## Offene Risiken

- Formspects are easy to break with unescaped text.
- Dropdown `index_event=true` fields can be submitted together with buttons and
  must not preempt button handling.
- Runtime-only settings can be mistaken for persistent configuration.
