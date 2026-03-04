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

## In Progress

These features are currently under active development:

### IDE Context System

The IDE will provide additional contextual information to the LLM.

Planned context elements include:

- active mods list
- player position
- currently opened file
- execution output from previous runs

This will allow the LLM to generate more accurate and relevant code.

---

## Planned Improvements

### Execution Feedback Loop

Improve the interaction between generated code and the execution system.

Possible features:

- automatic error detection
- AI-assisted debugging
- improved output visualization

---

### WorldEdit Integration

Further improvements to AI-assisted building tools:

- context-aware structure generation
- material-aware building suggestions
- improved prompt templates

---

### Prompt System Refinements

Improve system prompts used for:

- Lua code generation
- WorldEdit assistance
- general chat interactions

The goal is more consistent and reliable responses.

---

## Future Ideas

Ideas being explored for future versions:

- agent-style AI workflows
- multi-step code generation and correction
- automatic debugging loops
- extended IDE tooling
- improved building automation tools

---

## Long-Term Vision

LLM Connect aims to evolve into a complete AI-assisted development
environment inside Luanti, enabling players and modders to experiment,
prototype, and build complex systems directly within the game.
