# LLM Connect

A Minetest mod that connects the game to a Large Language Model (LLM) using an OpenAI-compatible API endpoint.

## Purpose

This mod allows players to interact with an LLM directly within the Minetest chat.  
It sends the player's chat message along with relevant in-game context—such as server info, installed mods, and available materials—to a remote API endpoint.  
This enables the LLM to provide highly specific and helpful answers, e.g., on crafting items or locating resources in-game.

<!-- cite: 33,34,35 -->

## Features

- **In-game AI Chat:** Send prompts to the LLM using a simple chat command. <!-- cite: 36 -->
- **Context-Aware:** Automatically includes crucial server and material data in the prompts. <!-- cite: 37 -->
- **Configurable:** API key, endpoint URL, and model can be set via chat commands or the in-game menu. <!-- cite: 38,47 -->
- **Conversation History:** Maintains short-term conversation history for more relevant responses. <!-- cite: 39 -->
- **Robust Token Handling:** Supports sending `max_tokens` as an integer to avoid floating-point issues; optionally configurable via `settingtypes.txt` or chat commands.

## Implementation

- Built with Minetest's HTTP API for sending requests to an external, OpenAI-compatible endpoint. <!-- cite: 44 -->
- Structured to be understandable and extendable for new contributors.  
- Version: **0.7.7**

## Requirements

- A running Minetest server.  
- An API key from a supported service. <!-- cite: 40 -->
- Access to external AI services (online and/or offline).

## Supported API Endpoints

Successfully tested with:

- Open WebUI  
- LM Studio  
- Mistral AI  
- OpenAI API  
- Ollama and LocalAI (integer `max_tokens` ensures compatibility)

## Commands

- `/llm_setkey <key> [url] [model]` – Sets the API key, endpoint URL, and model. <!-- cite: 41 -->
- `/llm_setmodel <model>` – Sets the LLM model to be used.
- `/llm_set_endpoint <url>` – Sets the API endpoint URL.
- `/llm_set_context <count> [player]` – Sets the maximum context length for a player or all players.
- `/llm_reset` – Resets the conversation history for the current player.
- `/llm <prompt>` – Sends a message to the LLM. <!-- cite: 42 -->
- `/llm_integer` – Forces `max_tokens` to be sent as an integer (default).
- `/llm_float` – Sends `max_tokens` as a float (optional, experimental).

## Potential for Expansion

- Add support for more API endpoints. <!-- cite: 44 -->
- Integrate with additional in-game events or data sources (player inventory, world data).
- Improve error handling and performance.
- Create a graphical user interface (formspec) for configuration instead of relying solely on chat commands.

## Contributing

This project is in an early stage and welcomes contributions:

- Even small fixes help, especially with API integration, UI improvements, and performance tuning. <!-- cite: 45 -->
- Contributions from experienced developers are highly welcome. <!-- cite: 46 -->
- The goal is to build a robust, maintainable mod for the Minetest community.
