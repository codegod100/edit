# Terminal Manager Architecture Design

**Date**: 2026-02-20
**Status**: Approved
**Problem**: Ctrl+C leaves terminal in raw mode, escape codes leak to shell

## Problem Statement

When pressing Ctrl+C twice to exit zagent, the terminal remains in raw mode. This causes:
- Up arrow shows `[A` escape codes instead of history
- Cursor jumps to unexpected positions (scroll region not reset)
- Shell behaves erratically until `reset` command

Root causes identified:
1. Two separate raw mode implementations (`line_editor.zig` and `cancel.zig`)
2. State saved to different places (local vs global)
3. Multiple cleanup paths with race conditions
4. Signal handler only sets flags, doesn't restore terminal

## Design Decision

**Single Global Terminal State** - One `TerminalManager` owns all terminal state. All code goes through it. Signal handler can safely call `restore()` directly.

## Architecture

### TerminalManager Struct

```zig
// src/terminal.zig

const TerminalManager = struct {
    original_termios: ?std.posix.termios = null,
    original_flags: ?u32 = null,  // fcntl O_NONBLOCK state
    in_raw_mode: bool = false,
    push_count: usize = 0,        // For nested raw mode requests
    
    cancelled: bool = false,      // 1st Ctrl+C
    exit_requested: bool = false, // 2nd Ctrl+C
    
    /// Initialize at program start - saves original terminal state
    pub fn init(self: *TerminalManager) void;
    
    /// Cleanup at program end - guarantees terminal is restored
    pub fn deinit(self: *TerminalManager) void;
    
    /// Enter raw mode. Safe to call multiple times (tracks nesting).
    pub fn pushRaw(self: *TerminalManager) void;
    
    /// Exit raw mode. Only restores when all pushes are popped.
    pub fn popRaw(self: *TerminalManager) void;
    
    /// Force restore - always works, safe to call from signal handler.
    /// Uses only async-signal-safe operations.
    pub fn restore(self: *TerminalManager) void;
};
```

### Signal Handling (Three-Level Ctrl+C)

```
1st Ctrl+C: cancelled = true
            Current operation should abort gracefully.

2nd Ctrl+C: exit_requested = true
            g_terminal.restore() called directly in signal handler.
            Main loop checks shouldExit() and exits.
            All defers still run.

3rd Ctrl+C: std.posix.exit(130)
            Nuclear option - immediate termination.
            Terminal already restored by 2nd Ctrl+C.
```

### Signal Handler Implementation

```zig
fn sigintHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    const already_cancelled = g_terminal.cancelled;
    const already_exit = g_terminal.exit_requested;
    
    if (already_exit) {
        // 3rd Ctrl+C - nuclear exit
        std.posix.exit(130);
    } else if (already_cancelled) {
        // 2nd Ctrl+C - request exit, restore terminal
        g_terminal.exit_requested = true;
        g_terminal.restore();  // Safe: only tcsetattr + fcntl
    } else {
        // 1st Ctrl+C - just cancel
        g_terminal.cancelled = true;
    }
}
```

### Push/Pop Pattern

```zig
/// Enter raw mode. Safe to call multiple times (tracks nesting).
pub fn pushRaw(self: *TerminalManager) void {
    self.push_count += 1;
    if (self.push_count > 1) return;  // Already in raw mode
    
    self.enterRawMode();
}

/// Exit raw mode. Only restores when all pushes are popped.
pub fn popRaw(self: *TerminalManager) void {
    if (self.push_count == 0) return;  // Defensive
    self.push_count -= 1;
    if (self.push_count > 0) return;  // Still nested
    
    self.restore();
}
```

## File Changes

| File | Change |
|------|--------|
| `src/terminal.zig` | **NEW** - TerminalManager implementation |
| `src/cancel.zig` | Thin wrapper over terminal.zig (compatibility) |
| `src/line_editor.zig` | Remove local termios, use pushRaw/popRaw |
| `src/repl/main.zig` | Remove enableRawMode/disableRawMode calls |
| `src/main.zig` | Call g_terminal.init()/deinit() |

## Migration Path

1. Create `src/terminal.zig` with `TerminalManager` struct
2. Update `cancel.zig` to use TerminalManager internally
3. Update `line_editor.zig` to use wrapper (remove local termios handling)
4. Remove dead code (duplicate saves, manual tcsetattr calls)
5. Test all exit paths

## Cleanup Guarantees

```
Normal exit:
  main() → g_terminal.deinit() → restore()

Error return:
  errdefer g_terminal.popRaw() → restore()

Second Ctrl+C:
  signal handler → g_terminal.restore() directly
  → main loop checks shouldExit() → break → deinit()

Third Ctrl+C (nuclear):
  signal handler → std.posix.exit(130)
  (terminal already restored by 2nd Ctrl+C)
```

**Key guarantee**: Signal handler's `restore()` on 2nd Ctrl+C fixes terminal BEFORE main loop checks `shouldExit()`. This eliminates the race condition.

## Testing

Manual verification checklist:
1. Start zagent
2. Press Ctrl+C once → should cancel current operation
3. Press up arrow → shell history should work (not show `[A`)
4. Press Ctrl+C twice rapidly → should exit cleanly
5. Press up arrow in shell → should show history, not escape codes
6. Verify cursor is at bottom of terminal, not stuck in scroll region