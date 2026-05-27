# External Skills

External skills are separately installed Luanti mods that expose agent-facing
runtime capabilities through the public LLM-Connect registry ABI.

## Lifecycle and Security Model

An external skill is a normal Luanti mod. The server administrator installs and
enables it intentionally, and its `mod.conf` declares:

```ini
depends = llm_connect
```

Luanti loads `llm_connect` first, then loads the external mod. The external mod
self-registers by calling `llm_connect.registry.register_skill(...)` or the
stable alias `llm_connect.skill_registry.register_skill(...)`.

LLM-Connect does not scan neighboring mod directories, does not `dofile()`
third-party skill code, and does not load mods that Luanti has not enabled.
`registry.discover_external()` is only a post-load validation and reporting
pass over external skills that already registered themselves.

## Minimal Mod Structure

```text
llm_connect_example_skill/
├── mod.conf
└── init.lua
```

## Minimal mod.conf

```ini
name = llm_connect_example_skill
title = LLM Connect Example Skill
description = Minimal external LLM-Connect skill
author = Example
license = LGPL-3.0-or-later
version = 0.1.0
depends = llm_connect
```

## Minimal init.lua

```lua
local modname = core.get_current_modname()
local llm = rawget(_G, "llm_connect")
local registry = llm and (llm.skill_registry or llm.registry)

if not registry or type(registry.register_skill) ~= "function" then
    core.log("error", "[" .. modname .. "] LLM-Connect registry unavailable")
    return
end

local ok, err = registry.register_skill({
    id = "example_skill",
    label = "Example Skill",
    version = "0.1.0",
    description = "Minimal external LLM-Connect skill.",
    origin = "external",
    provider_mod = modname,
    required_priv = "llm_agent",
    default_enabled = false,
    tool_count = 1,

    api = {
        run = function(tool_name, args, player_name)
            if tool_name == "ping" then
                return {
                    ok = true,
                    success = true,
                    message = "pong",
                    data = { args = args or {}, player_name = player_name },
                }
            end
            return { ok = false, success = false, message = "unknown tool" }
        end,
    },
})

if not ok then
    core.log("error", "[" .. modname .. "] external skill registration failed: " .. tostring(err))
end
```

## register_skill Fields

Required for external skills:

- `id`: stable skill namespace, using letters, numbers, `_`, `-`, `.`, or `:`.
- `origin = "external"`: canonical external provenance marker.
- `provider_mod`: non-empty Luanti mod name, normally `core.get_current_modname()`.
- `api`: table containing `run`.
- `api.run`: function called as `run(tool_name, args, player_name)`.

Recommended:

- `label`
- `version`
- `description`
- `required_priv = "llm_agent"`
- `default_enabled = false`
- `tool_count`

Optional provenance fields:

- `provider_version`
- `source`
- `homepage`

## Runtime ABI

After successful registration, LLM-Connect mounts the runtime API at:

```lua
llm_connect.skills.<skill_id>.run("<tool_name>", args, player_name)
```

The mount is atomic for external skills. If metadata, provenance, or `api.run`
validation fails, the skill is not recorded and no partial runtime table is
installed.

## Attachment Behavior

Registered skills are visible to the registry but are not usable by an agent
unless existing attach and privilege rules permit use. External skills should
set `default_enabled = false` unless they intentionally want to be attached by
default.

## Collision Policy

External skills cannot overwrite internal skill IDs. An external skill also
cannot overwrite a skill from another external `provider_mod`. A repeated
registration of the same external skill ID from the same `provider_mod` is
treated as a deterministic refresh.

## Validation and Debugging

`llm_connect.registry.discover_external()` returns a structured report:

```lua
{
    discovered = 1,
    valid = 1,
    invalid = 0,
    skills = {
        {
            id = "external_skill_probe",
            origin = "external",
            provider_mod = "llm_connect_external_skill_probe",
            version = "0.1.0",
            ok = true,
        },
    },
    errors = {},
}
```

The latest report is stored on:

```lua
llm_connect.registry.external_skill_report
```

Use the inert fixture at
`tests/fixtures/llm_connect_external_skill_probe/` as the reference example for
the Block 1 ABI.
