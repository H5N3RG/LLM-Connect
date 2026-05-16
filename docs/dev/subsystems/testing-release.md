# Testing And Release Discipline

## Zweck

Keeps development grounded in runtime evidence instead of assumptions from old
roadmap files or custom smoke tools.

## Public Contract

- `debug.txt` and prompt logs are primary evidence for agent behavior.
- `lemr` is a coarse load smoke test only.
- `luajit -b` is the minimum syntax gate for changed Lua files.
- `docs/dev/TESTS.md` contains manual in-game scenarios.
- `docs/dev/ISSUES.md` or root `ISSUES.md` tracks live log-derived bugs.

## Nicht-Ziele

- Do not treat `lemr` as proof that an in-game agent workflow works.
- Do not merge architecture changes based only on docs without checking code.
- Do not make destructive git cleanup during release prep unless explicitly
  requested.

## Datenfluss

1. Read bottom of `debug.txt`.
2. Read relevant prompt request/response logs.
3. Patch code or docs.
4. Run syntax checks.
5. Run `lemr` as load smoke if useful.
6. Run manual in-game scenario.
7. Update docs or issue list with what was learned.

## Settings

Testing often touches:

- `llm_trace_prompt_log`
- `llm_live_trace_chat`
- `llm_live_trace_show_lua`
- `llm_agent_max_iterations`
- `llm_agent_max_repair_retries`

## Fehlerbilder

- Provider `429`: rate limit, not necessarily agent logic failure.
- Empty response trace: inspect HTTP status in response prompt log.
- Server restart after player leaves: may be client freeze/shutdown, not agent
  abort by itself.
- Partial world build before failure: generated Lua did work before the failing
  statement.

## Tests / Smoke Checks

Recommended before pushing `dev/1.2.0`:

```sh
for f in $(rg --files -g '*.lua'); do luajit -b "$f" /tmp/llm_connect_syntax.out || exit 1; done
```

```sh
lemr ./LLM-Connect
```

Then run the release-relevant manual tests from `docs/dev/TESTS.md`.

## Offene Risiken

- No fully automated Luanti integration harness exists yet.
- Provider variability can hide or expose prompt weaknesses.
- Dirty worktrees may contain unrelated user edits; verify commit scope before
  pushing.
