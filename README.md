# zagent

**zagent** is a powerful, terminal-based AI coding assistant written in Zig. It is designed to act as an autonomous software engineer, capable of planning tasks, executing shell commands, editing files, and interacting with various LLM providers (GitHub Copilot, OpenAI, Anthropic, etc.) to build and refactor software.

## Features

-   **Autonomous Execution**: Can run shell commands, read/write files, and perform complex multi-step tasks without constant hand-holding.
-   **Plan & Progress**: Built-in `todo` system allows the agent to create plans, track progress, and auto-correct if it drifts off course.
-   **Robust Terminal UI**:
    -   Pinned status bar for context (model, provider, spinner).
    -   Scrollable timeline history with boxed inputs and outputs.
    -   Artifact-free rendering with ANSI-aware text wrapping.
-   **Modular Architecture**:
    -   `ai_bridge`: Unified interface for LLM providers.
    -   `model_loop`: Sophisticated agent loop with tool execution, error handling, and adaptive step limits.
    -   `repl`: Clean, stable read-eval-print loop for user interaction.
-   **Provider Agnostic**: Supports multiple AI providers via a unified configuration store.

## Installation

### Prerequisites

-   [Zig](https://ziglang.org/) (latest stable or master recommended)
-   `git`

### Build

Clone the repository and build the project using Zig:

```bash
git clone https://github.com/codegod100/edit.git zagent
cd zagent
zig build
```

The executable will be located at `zig-out/bin/zagent`.

## Usage

Run the agent directly:

```bash
./zig-out/bin/zagent
```

Or using the build system:

```bash
zig build run
```

### Commands

Inside the REPL, you can interact with the agent using natural language or special commands:

-   `/help`: Show available commands.
-   `/model [name]`: Switch the active model/provider.
-   `/connect [provider]`: Setup a new provider connection.
-   `/quit` or `Ctrl+D`: Exit the session.

### Scripting

You can pipe commands to `zagent` for automated workflows:

```bash
echo "Analyze the src/ directory and summarize the architecture" | ./zig-out/bin/zagent
```

## Configuration

Configuration files are stored in `~/.config/zagent/`. This includes:
-   `providers.json`: API keys and endpoints.
-   `selected_model.json`: Persistent user preferences.
-   `sessions/`: History and context for previous runs.

## Architecture

-   **`src/main.zig`**: Entry point and initialization.
-   **`src/repl/`**: Handles user input, command parsing, and the main UI loop.
-   **`src/model_loop/`**: The brain of the agent. Manages the conversation loop, executes tools (`src/tools.zig`), and handles the "Final Push" logic for task completion.
-   **`src/ai_bridge/`**: Abstraction layer for HTTP communication with various LLM APIs.
-   **`src/display.zig`**: UI rendering engine, handling ANSI codes, box drawing, and the scrolling region.

## License

MIT
