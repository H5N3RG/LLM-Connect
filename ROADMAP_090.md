# LLM Connect 0.9 Roadmap

This document outlines the development goals and planned improvements
for the 0.9 release of LLM Connect.

The focus of this version is stability, improved context handling,
and better integration between AI features and the Luanti environment.

---

## Overview

Version 0.9 aims to refine the existing AI integration and extend
the development tools provided by the Smart Lua IDE.

Key areas include:

- improved context awareness
- better IDE workflow
- enhanced WorldEdit integration
- improved error handling and execution feedback

---

## Completed Features

The following features are already implemented:

- Improved request timeout handling
- Expanded configuration options
- Wider IDE layout and improved UI usability
- Guide checkbox for code generation prompts
- Custom file indexing system replacing `core.get_dir_list`
- Improved proxy and API error handling

---

## IDE Context System ✓

All planned context elements are fully implemented:

- Active mods list injected into IDE generate calls
- Player position injected into IDE generate calls
- Currently opened file included in context
- Execution output from previous runs included in context

Additional context features beyond original scope:

- **IDE Asset Picker** (`ide_asset_picker.lua`) – three-tab browser for Nodes,
  Items/Tools, and Sounds with search, pagination, and selection highlighting.
  Selected assets are serialised into the LLM context as structured metadata
  (tiles, groups, sound presets, tool capabilities).
- **API Reference Injection** (`ide_api_stubs.lua`) – optional slim (~400 tokens)
  or full (~2000 tokens) Luanti API reference injected per session via toggle
  buttons in the IDE toolbar.

---

## Execution Feedback Loop ✓

All planned features are implemented:

- **Automatic error detection** – pre-executor runs before every real execution,
  catching syntax errors, naming-convention violations (`llm_connect:` prefix
  enforcement), and missing required fields (`tiles`, `inventory_image`, etc.)
  without triggering actual game registrations. The sandbox falls back to `_G`
  for all loaded mod globals (default, stairs, vector, etc.) so real API calls
  like `default.node_sound_ice_defaults()` work correctly during pre-check.
- **AI-assisted debugging** – Auto-Fix loop (`M.execute_with_retry`) retries
  failed executions automatically: on error the LLM receives the current code
  plus the full error output and returns a corrected version, which is written
  back into the editor and re-executed. The loop aborts on success, on repeated
  identical errors (LLM stuck), or after reaching the configurable iteration
  limit (`llm_ide_auto_fix_iterations`, default 3).
- **Improved output visualisation** – status bar shows last-run result (✓/✗),
  pre-check warnings are surfaced inline in the output panel, and the Auto-Fix
  button becomes active (highlighted amber) only after a failed run.

Security note: broken code is never written to `llm_startup.lua`. Persistence
only happens when execution succeeds.

---

## WorldEdit Integration ✓

- Context-aware structure generation with player position, selection, and
  nearby node sample
- Material-aware building suggestions via the material picker
- Improved prompt templates for single-shot and iterative loop modes
- WorldEditAdditions (WEA) integration: torus, ellipsoid, erode, convolve,
  overlay, layers, replacemix

---

## Prompt System Refinements ✓

- Lua code generation prompt updated with security rules, context awareness,
  and naming convention guidance
- WorldEdit system prompts refined for single-shot and loop modes
- Naming convention guide optionally injected into generate calls
- Language instruction system (29 languages, configurable repeat count)

---

## Future Ideas

Items still being explored for future versions or a 0.9.x release:

- Automatic debugging loops triggered without user interaction (currently
  requires the Auto-Fix button; fully autonomous mode not yet implemented)
- Extended IDE tooling (diff view, multi-file context, snippet library UI)
- Improved building automation (smarter iteration planning in WE loop)
- Agent-style workflows spanning chat and IDE in a single session

---

## Long-Term Vision

LLM Connect aims to evolve into a complete AI-assisted development
environment inside Luanti, enabling players and modders to experiment,
prototype, and build complex systems directly within the game.
