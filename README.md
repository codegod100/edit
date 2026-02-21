# zagent

`zagent` is a terminal AI coding agent written in Zig.

It can read/edit files, run shell commands, reason across multi-step tasks, and keep working context in-session. It supports multiple providers/models with a unified REPL workflow.

---

## 5-minute quickstart

### 1) Build

```bash
git clone https://github.com/codegod100/edit.git zagent
cd zagent
zig build
```

Binary:

```bash
./zig-out/bin/zagent
```

### 2) (Optional) pick model at startup

```bash
./zig-out/bin/zagent --model openai/gpt-5.3-codex
```

### 3) Connect provider in REPL

```text
/connect openai
/providers
/provider openai
/model
```

### 4) Ask for work

```text
Refactor src/repl/main.zig to simplify command handling.
```

### 5) Exit

```text
/quit
```

(or `Ctrl+D`)

---

## Core commands

### Provider + auth

- `/providers` — list providers and connection/auth status
- `/connect <provider>` — connect provider auth
- `/connect codex` — use Codex auth from `~/.codex/auth.json`
- `/provider <id>` — set active provider

### Model control

- `/model` — interactive model picker
- `/model <provider/model>` — set explicit model
- `/models` — list models for current context
- `--model <provider/model>` — startup model override

### Session + context

- `/restore` — restore previous context for current project
- `/clear` — clear timeline display
- `/quit` or `/exit` — leave session

### Utility

- `/skills`, `/skill <name>` — skill discovery/load
- `/tools` — list available tools
- `/usage` — usage summary for active provider (when supported)
- `/stats` — session stats
- `/ping` — liveness check
- `/effort <value|default>` — reasoning effort override

---

## How zagent works

### REPL + timeline

- Scrollable conversation timeline
- Pinned status bar (provider/model/path + spinner)
- `set_status` tool updates spinner text to show current subtask

### Model loop + tools

- `model_loop` executes tool-calling turns
- Tools include file IO, patching, shell execution, web fetch, todos, and status updates
- Tool output is streamed into timeline with truncation/formatting for readability

### Reliability contract

For implementation-intent requests, turns are guarded against fake progress:

- accepted if there is concrete work evidence (edits/files touched), or
- accepted if there is an explicit blocker with actionable cause

Otherwise zagent issues corrective retries (bounded), then fails explicitly instead of pretending completion.

---

## Authentication behavior

### OpenAI Codex OAuth

- `zagent` can consume Codex/OpenAI OAuth from:
  - `~/.codex/auth.json` (primary)
  - `~/.codex/copilot_auth.json` (legacy fallback)

### Environment precedence

- If a provider env var is set (e.g. `OPENAI_API_KEY`), env wins.
- If not set, provider-specific fallback sources may be used (e.g. codex auth file for OpenAI OAuth flow).

---

## Non-interactive mode (piped input)

You can pipe prompts into zagent:

```bash
echo "Summarize src/model_loop architecture" | ./zig-out/bin/zagent --model openai/gpt-5.3-codex
```

---

## Configuration storage

`~/.config/zagent/`

- `settings.json` — provider/model catalog and settings
- `provider.env` — stored provider key-value pairs
- `selected_model.json` — persisted provider/model selection
- `history` — command history
- `context-<hash>.json` — per-project conversation context
- `transcripts/` — session transcript logs

---

## Repository layout (contributor view)

- `src/main.zig` — entrypoint
- `src/repl/` — command parsing/handling + interactive loop
- `src/model_loop/` — orchestration, turn loop, tool enforcement
- `src/tools.zig` — tool definitions + execution
- `src/display.zig` — timeline/status bar/spinner rendering
- `src/auth.zig` — auth helpers (including codex auth file support)
- `src/provider.zig`, `src/model_select.zig` — provider/model resolution
- `src/ai_bridge/`, `src/llm/` — provider/backend HTTP integration layers

---

## Build/test/develop

Build:

```bash
zig build
```

Run:

```bash
./zig-out/bin/zagent
```

Run tests:

```bash
zig build test
```

---

## Troubleshooting FAQ

### “No active provider/model”

Run:

```text
/providers
/connect <provider>
/provider <id>
/model
```

### OpenAI shows non-codex models while using codex auth

Check for env override:

```bash
echo $OPENAI_API_KEY
```

If set, it overrides file-based codex auth.

### Tool call says status updated but spinner text looks wrong

`set_status` should show the provided status text in spinner/status bar while work continues.

### Model/backend returns HTTP 400

Most often model/provider mismatch or invalid tool schema for strict backends. Reconfirm:

```text
/provider <id>
/model <provider/model>
```

---

## License

MIT
