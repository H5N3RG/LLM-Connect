# LLM Connect

**A Minetest mod that connects the game to an LLM using an OpenAI-compatible API endpoint.**

### Purpose
[cite_start]This mod allows players to interact with a Large Language Model (LLM) directly within the Minetest chat[cite: 33]. [cite_start]It sends the player's chat message along with relevant in-game context (server info, installed mods, and available materials) to a remote API endpoint[cite: 34]. [cite_start]This enables the LLM to provide highly specific and helpful answers, for example, on how to craft items or where to find certain materials in the game[cite: 35].

### Features
* [cite_start]**In-game AI Chat**: Use a simple chat command to send prompts to the LLM[cite: 36].
* [cite_start]**Context-Aware**: Automatically includes crucial server and material data in the prompts[cite: 37].
* [cite_start]**Configurable**: The API key, endpoint URL, and model can be set via chat commands and the in-game menu[cite: 38, 47].
* [cite_start]**Conversation History**: Maintains a short-term conversation history for more relevant responses[cite: 39].

### Implementation
[cite_start]This mod was created with the help of an AI assistant and is currently in its early stages[cite: 44]. It utilizes Minetest's HTTP API to send requests to an external, OpenAI-compatible endpoint. The mod is structured to be easily understandable and extendable for new contributors.

### Requirements
* A running Minetest server.
* [cite_start]An API key from a supported service[cite: 40].
* **Access to external AI services (online and/or offline).**

### Supported API Endpoints
[cite_start]This mod has been successfully tested with the following APIs:
* [Open WebUI](https://github.com/open-webui/open-webui)
* [LM Studio](https://lmstudio.ai/)
* [Mistral AI](https://docs.mistral.ai/)
* **OpenAI API**
* [cite_start]**Ollama** and **LocalAI** are also now compatible, as the mod supports sending `max_tokens` as an integer to avoid floating-point issues.

### Commands
* `/llm_setkey <key> [url] [model]`
    * [cite_start]Sets the API key, URL, and model[cite: 41].
* `/llm_setmodel <model>`
    * Sets the LLM model to be used.
* `/llm_set_endpoint <url>`
    * Sets the API URL of the LLM endpoint.
* `/llm_set_context <count> [player]`
    * Sets the maximum context length for a player or all players.
* `/llm_reset`
    * Resets the conversation history for the current player.
* `/llm <prompt>`
    * [cite_start]Sends a message to the LLM[cite: 42].

### Potential for Expansion
[cite_start]This project is in an early stage and offers many possibilities for future development[cite: 44]:
* Adding support for more API endpoints.
* Integrating with other in-game events and data sources (e.g., player inventory, world data).
* Improving error handling and performance.
* [cite_start]Creating a user interface (formspec) for configuration instead of relying on chat commands.

[cite_start]I am not an experienced programmer, and my primary goal is to make the mod known and have more experienced developers contribute to its further development[cite: 45]. [cite_start]If you are a programmer and would like to help improve this mod, your contributions are highly welcome! [cite: 46]
