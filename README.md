# zagent

**zagent** is a powerful, terminal-based AI coding assistant written in Zig. It is designed to act as an autonomous software engineer, capable of planning tasks, executing shell commands, editing files, and interacting with various LLM providers (GitHub Copilot, OpenAI, Anthropic, etc.) to build and refactor software.

## Features

-   **Autonomous Execution**: Can run shell commands, read/write files, and perform complex multi-step tasks without constant hand-holding.
-   **Plan & Progress**: Built-in `todo` system allows the agent to create plans, track progress, and auto-correct if it drifts off course.
-   **Robust Terminal UI**:
    -   Pinned status bar for context (model, provider, spinner).
    -   Scrollable timeline history with ANSI-aware text wrapping.
    -   Hardened line editor and history navigation (clean Up/Down recall, prompt-prefix normalization).
    -   Improved Ctrl+C/EOF terminal cleanup (reduced shell handoff artifacts).
    -   Spinner starts immediately for model turns (title generation removed from hot path).
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

Resume a previous session:

```bash
./zig-out/bin/zagent --resume
./zig-out/bin/zagent --resume <session-id>
```

Optional context restore behavior:

```bash
ZAGENT_RESTORE_CONTEXT=1 ./zig-out/bin/zagent
```

### Commands

Inside the REPL, you can interact with the agent using natural language or special commands:

-   `/providers`: List provider connection status.
-   `/connect [provider]`: Configure/connect a provider.
-   `/provider [id]`: Switch active provider.
-   `/model [provider/model]`: Switch active model.
-   `/models [filter]`: List available models.
-   `/usage`: Show quota + token/tool usage.
-   `/stats`: Show session stats.
-   `/skills`, `/skill <name>`, `/tools`: Introspection helpers.
-   `/clear`: Clear timeline.
-   `/restore`: Restore prior context for current project.
-   `/quit` or `Ctrl+D`: Exit session.

### Scripting

You can pipe commands to `zagent` for automated workflows:

```bash
echo "Analyze the src/ directory and summarize the architecture" | ./zig-out/bin/zagent
```

### Benchmarking and Trials

This repo now uses Harbor-imported Terminal-Bench tasks (formalized task source):

```bash
# Import dataset and build flat task index
scripts/import-terminal-bench.sh

# Run the first 3 imported tasks
scripts/import-terminal-bench.sh --run 3

# Run a specific imported task path
scripts/run-harbor-trial.sh --task third_party/terminal-bench-2/flat/<task-name>
```

See `docs/harbor-zagent-quickstart.md` for the full Harbor setup flow.

## Configuration

Configuration files are stored in `~/.config/zagent/`. This includes:
-   `settings.json`: Provider/model catalog and provider config.
-   `provider.env`: Provider API keys.
-   `selected_model.json`: Persistent user preferences.
-   `history`: Command history used for Up/Down navigation.
-   `context-<hash>.json`: Per-project conversation context used by restore/resume flows.

## Architecture

-   **`src/main.zig`**: Entry point and initialization.
-   **`src/repl/`**: Handles user input, command parsing, and the main UI loop.
-   **`src/model_loop/`**: The brain of the agent. Manages the conversation loop, executes tools (`src/tools.zig`), and handles the "Final Push" logic for task completion.
-   **`src/ai_bridge/`**: Abstraction layer for HTTP communication with various LLM APIs.
-   **`src/display.zig`**: UI rendering engine, handling ANSI codes, box drawing, and the scrolling region.

## License

MIT
