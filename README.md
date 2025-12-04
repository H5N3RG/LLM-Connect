# LLM Connect

A Luanti (formerly Minetest) mod that connects the game to a Large Language Model (LLM) using an OpenAI-compatible API endpoint.

## Purpose

This mod allows players to interact with an LLM directly within the Luanti chat.
It sends the player's chat message along with relevant in-game context—such as server info, installed mods, and available materials—to a remote API endpoint.
This enables the LLM to provide highly specific and helpful answers, e.g., on crafting items or locating resources in-game.

## Features

- **In-game AI Chat:** Send prompts to the LLM using a simple chat command. - **Context-Aware & Granular:** Automatically includes crucial server and material data in the prompts. **The inclusion of context elements (server info, mod list, materials, position) is now fully configurable via settings.** - **Configurable:** API key, endpoint URL, model, and all **context components** can be set via chat commands or the in-game menu. - **Conversation History:** Maintains short-term conversation history for more relevant responses. - **Robust Token Handling:** Supports sending `max_tokens` as an integer to avoid floating-point issues; optionally configurable via `settingtypes.txt` or chat commands.

## Implementation

- Built with Luanti's HTTP API for sending requests to an external, OpenAI-compatible endpoint. - Structured to be understandable and extendable for new contributors.
- Version: **0.7.8**

## Requirements

- A running Luanti server.
- An API key from a supported service. ## Supported API Endpoints

Successfully tested with:

- Open WebUI
- LM Studio
- Mistral AI
- OpenAI API
- Ollama and LocalAI (integer `max_tokens` ensures compatibility)

## Commands

- `/llm_setkey <key> [url] [model]` – Sets the API key, URL, and model for the LLM. - `/llm_setmodel <model>` – Sets the LLM model to be used.
- `/llm_set_endpoint <url>` – Sets the API endpoint URL.
- `/llm_set_context <count> [player]` – Sets the maximum context length for a player or all players.
- `/llm_reset` – Resets the conversation history and the cached metadata for the current player.
- `/llm <prompt>` – Sends a message to the LLM. - `/llm_integer` – Forces `max_tokens` to be sent as an integer (default).
- `/llm_float` – Sends `max_tokens` as a float (optional, experimental).

**Context Control (Configurable via In-Game Settings):**
The following context elements can be individually toggled `ON`/`OFF` in the Luanti main menu:
* Send Server Info (`llm_context_send_server_info`)
* Send Mod List (`llm_context_send_mod_list`)
* Send Commands List (`llm_context_send_commands`)
* Send Player Position (`llm_context_send_player_pos`)
* Send Available Materials (`llm_context_send_materials`)

## Potential for Expansion

- Add support for more API endpoints. - Integrate with additional in-game events or data sources (player inventory, world data).
- Improve error handling and performance.
- Create a graphical user interface (formspec) for configuration instead of relying solely on chat commands.

## Contributing

This project is in an early stage and welcomes contributions:

- Even small fixes help, especially with API integration, UI improvements, and performance tuning. - Contributions from experienced developers are highly welcome. ```


