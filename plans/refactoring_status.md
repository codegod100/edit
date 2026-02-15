# Refactoring Plan and Status

## Objective
The primary goal is to refactor and organize the codebase by breaking down monolithic files (specifically the previous `repl.zig`, which was split into `repl_1` through `repl_11`, and similarly `ai_bridge.zig` and `model_loop.zig`) into smaller, modular, and maintainable files. The target file size is approximately 500 lines. This improves separation of concerns, readability, and testability.

## Progress (as of 2026-02-15)

### Completed Steps
1.  **Analyzed Existing Monoliths**: Reviewed `repl_*.zig`, `ai_bridge_*.zig`, and `model_loop_*.zig`.
2.  **Modularized REPL Structure**: Created a new directory `src/repl/` for the REPL-specific logic.
    *   `src/repl/commands.zig`: Contains the `CommandTag` enum and command parsing logic.
    *   `src/repl/state.zig`: Defines the `ReplState` struct to encapsulate REPL runtime state (config, providers, context, etc.).
    *   `src/repl/ui.zig`: Encapsulates user interaction logic, including `promptLine`, `interactiveModelSelect`, and terminal rendering helpers.
    *   `src/repl/handlers.zig`: Implements `handleCommand` to process specific REPL commands (`/help`, `/connect`, etc.), moving logic out of the main loop.
    *   `src/repl/main.zig`: Implements the core REPL loop, orchestrating input, command dispatch, and model execution.
3.  **Partially Consolidated Logic**: Moved logic from `repl_*.zig` files into the new structure, adapting imports to point correctly to shared modules (`../model_select.zig`, `../provider_manager.zig`, etc.).
4.  **Completed Zig 0.15.x API Migration**: Fixed all compilation errors across ~25+ files.

### Zig 0.15.x API Migration (COMPLETED)
**Key API Changes Applied**:
- `std.ArrayList(T).init(allocator)` → `var list: std.ArrayList(T) = .empty`
- `list.deinit()` → `list.deinit(allocator)`
- `list.append(item)` → `list.append(allocator, item)`
- `list.toOwnedSlice()` → `list.toOwnedSlice(allocator)`
- `list.writer()` → `list.writer(allocator)`
- `list.appendSlice(items)` → `list.appendSlice(allocator, items)`
- HTTP Client: Changed from `response_storage` to `response_writer` with `Allocating` writer
- File I/O: Using `deprecatedReader()`/`deprecatedWriter()` for old API compatibility

**Files Fixed** (25+ total):
- `src/provider_store.zig`, `src/model_select.zig`, `src/provider_manager.zig`
- `src/subagent.zig`, `src/todo.zig`, `src/config_store.zig`
- `src/auth.zig` - Updated ArrayList + HTTP client fetch API
- `src/repl/main.zig`, `src/line_editor.zig`, `src/repl/handlers.zig`, `src/repl/ui.zig`
- `src/ai_bridge.zig` - Fixed ArrayList + HTTP client API
- `src/llm/client.zig`, `src/llm/models.zig`, `src/llm/providers.zig`, `src/llm/chat.zig`, `src/llm/codex.zig`
- `src/tools.zig` - Fixed ArrayList + added missing helper functions
- `src/context.zig`, `src/utils.zig`

**Helper Functions Added to tools.zig**:
- `parseBashCommandFromArgs()` - Extract bash command from tool args
- `parsePrimaryPathFromArgs()` - Extract path/filePath from tool args
- `parseReadParamsFromArgs()` - Extract offset/limit from tool args
- `isMutatingToolName()` - Check if tool modifies files

### Build Status
✅ **BUILD SUCCESS** - All compilation errors resolved. The project now compiles successfully with Zig 0.15.x.

### Cleanup Status
✅ **BACKUP FILES REMOVED** - Deleted 32 untracked backup and test files.

### Next Phase: Further Modularization

Current file sizes vs 500-line target:
- `src/ai_bridge.zig`: **1268 lines** (2.5x target) - needs splitting
- `src/model_loop.zig`: **1105 lines** (2.2x target) - needs splitting

#### Proposed `src/ai_bridge/` module structure:
| File | Contents | Est. Lines |
|------|----------|------------|
| `types.zig` | ToolCall, ChatResponse, ProviderConfig structs | ~100 |
| `auth.zig` | OAuth, JWT handling, token exchange | ~150 |
| `json.zig` | JSON utilities (writeJsonStringEscaped) | ~50 |
| `http.zig` | httpRequest helper | ~50 |
| `chat.zig` | chatDirect, chatDirectOpenAICodexResponses, chatDirectCopilotResponses | ~300 |
| `models.zig` | listModelsDirect, fetchModelIDsDirect | ~200 |
| `body.zig` | buildCodexResponsesBody, buildChatBody | ~100 |
| `parser.zig` | parseCodexResponsesStream, parseChatResponse | ~250 |
| `main.zig` | Public exports, error handling | ~50 |

#### Proposed `src/model_loop/` module structure:
| File | Contents | Est. Lines |
|------|----------|------------|
| `types.zig` | SubagentThreadArgs struct | ~50 |
| `turn.zig` | runModelTurnWithTools (main tool loop) | ~350 |
| `legacy.zig` | runModel (alternative model runner) | ~450 |
| `tools.zig` | executeInlineToolCalls | ~100 |
| `subagent.zig` | Subagent thread handling | ~150 |

### Next Steps
1.  **Create `src/ai_bridge/` module**: Split 1268-line ai_bridge.zig into 9 focused files
2.  **Create `src/model_loop/` module**: Split 1105-line model_loop.zig into 5 focused files
3.  **Test after each split**: Ensure build continues to work

## References
*   `src/repl/` directory: New home for REPL logic.
*   `src/llm/` directory: Modular LLM provider implementations.
*   `src/main.zig`: Entry point.
*   `src/config_store.zig`, `src/provider_manager.zig`, `src/model_select.zig`: Core shared modules.
