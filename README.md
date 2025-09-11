# LLM Connect

**A Minetest mod that connects the game to an LLM using an OpenAI-compatible API endpoint.**

### Purpose
This mod allows players to interact with a Large Language Model (LLM) directly within the Minetest chat. It sends the player's chat message along with relevant in-game context (server info, installed mods, and available materials) to a remote API endpoint. This enables the LLM to provide highly specific and helpful answers, for example, on how to craft items or where to find certain materials in the game.

### Features
* **In-game AI Chat**: Use a simple chat command to send prompts to the LLM.
* **Context-Aware**: Automatically includes crucial server and material data in the prompts.
* **Configurable**: The API key, endpoint URL, and model can be set via chat commands.
* **Conversation History**: Maintains a short-term conversation history for more relevant responses.

### Implementation
This mod was created with the help of an AI assistant to generate the core code. It utilizes Minetest's HTTP API to send requests to an external, OpenAI-compatible endpoint. The mod is structured to be easily understandable and extendable for new contributors.

### Requirements
* A running Minetest server.
* An API key from a supported service.
* **Access to external AI services (online and/or offline).**
* **Supported API Endpoints**:
    * [Open WebUI](https://github.com/open-webui/open-webui)
    * [LM Studio](https://lmstudio.ai/)
    * [Mistral AI](https://docs.mistral.ai/)
    * **OpenAI API**
    * **Please note**: This mod might have issues with some self-hosted backends like **Ollama** and **LocalAI**, as they may not correctly handle the floating-point numbers in the API requests.

### Commands
* `/llm_setkey <key> [url] [model]`
    * Sets the API key, URL, and model.
* `/llm_setmodel <model>`
    * Sets the LLM model to be used.
* `/llm_set_endpoint <url>`
    * Sets the API URL of the LLM endpoint.
* `/llm_set_context <count> [player]`
    * Sets the maximum context length for a player or all players.
* `/llm_reset`
    * Resets the conversation history for the current player.
* `/llm <prompt>`
    * Sends a message to the LLM.

### Potential for Expansion
This project is in an early stage and offers many possibilities for future development:
* Adding support for more API endpoints.
* Integrating with other in-game events and data sources (e.g., player inventory, world data).
* Improving error handling and performance.
* Creating a user interface (formspec) for configuration instead of relying on chat commands.

I am not an experienced programmer, and my primary goal is to make the mod known and have more experienced developers contribute to its further development. If you are a programmer and would like to help improve this mod, your contributions are highly welcome!
