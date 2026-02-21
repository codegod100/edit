# Terminal Manager Implementation Plan

> **REQUIRED SUB-SKILL:** Use the executing-plans skill to implement this plan task-by-task.

**Goal:** Implement a single-source-of-truth TerminalManager to fix Ctrl+C terminal cleanup issues.

**Architecture:** One global `TerminalManager` owns all terminal state. Signal handler calls `restore()` directly on 2nd Ctrl+C. All code uses `pushRaw()/popRaw()` pattern for nested raw mode.

**Tech Stack:** Zig, POSIX termios, signal handling

---

## Task 0: Create terminal.zig with TerminalManager

**TDD scenario:** New feature — full TDD cycle (but terminal code is hard to unit test, so we test build + manual verification)

**Files:**
- Create: `src/terminal.zig`

**Step 1: Create terminal.zig with TerminalManager struct**

```zig
const std = @import("std");
const builtin = @import("builtin");

/// Single source of truth for terminal state.
/// All raw mode operations go through this manager.
pub const TerminalManager = struct {
    original_termios: ?std.posix.termios = null,
    original_flags: ?u32 = null,
    in_raw_mode: bool = false,
    push_count: usize = 0,
    
    cancelled: bool = false,
    exit_requested: bool = false,
    
    const Self = @This();
    
    /// Initialize at program start. Saves original terminal state.
    pub fn init(self: *Self) void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;
        if (!std.posix.isatty(std.posix.STDIN_FILENO)) return;
        
        self.original_termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch null;
        self.original_flags = std.posix.fcntl(std.posix.STDIN_FILENO, .GETFL, 0) catch null;
        self.cancelled = false;
        self.exit_requested = false;
        self.in_raw_mode = false;
        self.push_count = 0;
    }
    
    /// Cleanup at program end. Guarantees terminal is restored.
    pub fn deinit(self: *Self) void {
        self.restore();
        self.installSignalHandler(false);
    }
    
    /// Enter raw mode. Safe to call multiple times (tracks nesting).
    pub fn pushRaw(self: *Self) void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;
        if (!std.posix.isatty(std.posix.STDIN_FILENO)) return;
        
        self.push_count += 1;
        if (self.push_count > 1) return; // Already in raw mode
        
        self.enterRawMode();
    }
    
    /// Exit raw mode. Only restores when all pushes are popped.
    pub fn popRaw(self: *Self) void {
        if (self.push_count == 0) return;
        self.push_count -= 1;
        if (self.push_count > 0) return; // Still nested
        
        self.restore();
    }
    
    /// Force restore - always works, safe to call from signal handler.
    /// Uses only async-signal-safe operations.
    pub fn restore(self: *Self) void {
        if (!self.in_raw_mode) return;
        
        // Restore termios (async-signal-safe)
        if (self.original_termios) |orig| {
            _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, orig);
        }
        
        // Restore blocking mode (async-signal-safe)
        if (self.original_flags) |flags| {
            _ = std.posix.fcntl(std.posix.STDIN_FILENO, .SETFL, flags);
        }
        
        self.in_raw_mode = false;
    }
    
    /// Check if cancellation was requested
    pub fn isCancelled(self: *Self) bool {
        return @atomicLoad(bool, &self.cancelled, .monotonic);
    }
    
    /// Check if exit was requested (double Ctrl+C)
    pub fn shouldExit(self: *Self) bool {
        return @atomicLoad(bool, &self.exit_requested, .monotonic);
    }
    
    /// Reset cancellation state
    pub fn reset(self: *Self) void {
        @atomicStore(bool, &self.cancelled, false, .monotonic);
        @atomicStore(bool, &self.exit_requested, false, .monotonic);
    }
    
    // Internal: enter raw mode
    fn enterRawMode(self: *Self) void {
        if (self.original_termios == null) return;
        
        var raw = self.original_termios.?;
        raw.lflag.ICANON = false;  // Disable line buffering
        raw.lflag.ECHO = false;    // Disable echo
        raw.lflag.ISIG = true;     // Keep signal handling (Ctrl+C works)
        
        if (builtin.os.tag == .linux) {
            raw.cc[6] = 1; // VMIN
            raw.cc[5] = 0; // VTIME
        } else if (builtin.os.tag == .macos) {
            raw.cc[16] = 1; // VMIN
            raw.cc[17] = 0; // VTIME
        }
        
        _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        
        // Set non-blocking for escape sequence polling
        const O_NONBLOCK: u32 = if (builtin.os.tag == .linux) 0o4000 else 0x0004;
        if (self.original_flags) |flags| {
            _ = std.posix.fcntl(std.posix.STDIN_FILENO, .SETFL, flags | O_NONBLOCK);
        }
        
        self.in_raw_mode = true;
    }
    
    /// Install or restore signal handler
    pub fn installSignalHandler(self: *Self, install: bool) void {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;
        
        if (install) {
            g_terminal_ptr = self;
            
            if (builtin.os.tag == .linux) {
                var act: std.os.linux.Sigaction = .{
                    .handler = .{ .handler = @ptrCast(&sigintHandler) },
                    .mask = std.mem.zeroes(std.os.linux.sigset_t),
                    .flags = 0,
                };
                _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null);
            } else if (builtin.os.tag == .macos) {
                const kernel_sigaction = extern struct {
                    handler: ?*const anyopaque,
                    mask: c_int,
                    flags: c_int,
                };
                var act: kernel_sigaction = .{
                    .handler = @ptrCast(&sigintHandler),
                    .mask = 0,
                    .flags = 0,
                };
                _ = std.posix.system.sigaction(2, @ptrCast(&act), null);
            }
        } else {
            // Restore default signal handler
            if (builtin.os.tag == .linux) {
                var act: std.os.linux.Sigaction = .{
                    .handler = .{ .handler = null },
                    .mask = std.mem.zeroes(std.os.linux.sigset_t),
                    .flags = 0,
                };
                _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null);
            } else if (builtin.os.tag == .macos) {
                const kernel_sigaction = extern struct {
                    handler: ?*const anyopaque,
                    mask: c_int,
                    flags: c_int,
                };
                var act: kernel_sigaction = .{
                    .handler = null,
                    .mask = 0,
                    .flags = 0,
                };
                _ = std.posix.system.sigaction(2, @ptrCast(&act), null);
            }
            g_terminal_ptr = null;
        }
    }
    
    /// Drain stdin buffer - removes pending input so it doesn't leak to shell
    pub fn drainStdin(self: *Self) void {
        if (!std.posix.isatty(std.posix.STDIN_FILENO)) return;
        _ = self; // Not used, but keeping API consistent
        
        const O_NONBLOCK: u32 = if (builtin.os.tag == .linux) 0o4000 else 0x0004;
        const orig_flags = std.posix.fcntl(std.posix.STDIN_FILENO, .GETFL, 0) catch return;
        const was_nonblocking = (orig_flags & O_NONBLOCK) != 0;
        
        if (!was_nonblocking) {
            _ = std.posix.fcntl(std.posix.STDIN_FILENO, .SETFL, orig_flags | O_NONBLOCK);
        }
        
        var buf: [256]u8 = undefined;
        var empty_reads: usize = 0;
        while (empty_reads < 3) {
            const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
            if (n == 0) {
                empty_reads += 1;
                std.Thread.sleep(2 * std.time.ns_per_ms);
            } else {
                empty_reads = 0;
            }
        }
        
        if (!was_nonblocking) {
            _ = std.posix.fcntl(std.posix.STDIN_FILENO, .SETFL, orig_flags);
        }
    }
};

// Global instance and pointer for signal handler
var g_terminal: TerminalManager = .{};
var g_terminal_ptr: ?*TerminalManager = null;

/// Get the global terminal manager
pub fn get() *TerminalManager {
    return &g_terminal;
}

/// Signal handler - async-signal-safe
fn sigintHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    const tm = g_terminal_ptr orelse return;
    
    const already_cancelled = @atomicLoad(bool, &tm.cancelled, .monotonic);
    const already_exit = @atomicLoad(bool, &tm.exit_requested, .monotonic);
    
    if (already_exit) {
        // 3rd Ctrl+C - nuclear exit
        std.posix.exit(130);
    } else if (already_cancelled) {
        // 2nd Ctrl+C - request exit, restore terminal
        @atomicStore(bool, &tm.exit_requested, true, .monotonic);
        tm.restore();
    } else {
        // 1st Ctrl+C - just cancel
        @atomicStore(bool, &tm.cancelled, true, .monotonic);
    }
}
```

**Step 2: Build to verify no syntax errors**

Run: `zig build`
Expected: Compiles successfully

**Step 3: Commit**

```bash
git add src/terminal.zig
git commit -m "feat: add TerminalManager for unified terminal state"
```

---

## Task 1: Update cancel.zig as wrapper

**TDD scenario:** Modifying existing code — verify existing code still compiles

**Files:**
- Modify: `src/cancel.zig`

**Step 1: Replace cancel.zig with thin wrapper**

```zig
const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");

// Re-export for backward compatibility
pub const isCancelled = terminal.get().isCancelled;
pub const shouldExit = terminal.get().shouldExit;
pub const resetCancelled = terminal.get().reset;

/// Initialize signal handling (called from main)
pub fn init() void {
    const tm = terminal.get();
    tm.init();
    tm.installSignalHandler(true);
}

/// Cleanup (called from main on exit)
pub fn deinit() void {
    const tm = terminal.get();
    tm.drainStdin();
    tm.deinit();
}

/// Enable raw mode - use terminal manager
pub fn enableRawMode() void {
    terminal.get().pushRaw();
}

/// Disable raw mode - use terminal manager  
pub fn disableRawMode() void {
    terminal.get().popRaw();
}

/// Check if stdin is a TTY
pub fn isTty() bool {
    return std.posix.isatty(std.posix.STDIN_FILENO);
}

/// Begin processing (reset cancellation state)
pub fn beginProcessing() void {
    terminal.get().reset();
}

/// Drain stdin buffer
pub fn drainStdin() void {
    terminal.get().drainStdin();
}

/// Poll for escape key during long operations
pub fn pollForEscape() void {
    var buf: [64]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
    if (n > 0) {
        for (buf[0..n]) |byte| {
            if (byte == 0x1B) {
                @atomicStore(bool, &terminal.get().cancelled, true, .monotonic);
            }
        }
    }
}
```

**Step 2: Build to verify**

Run: `zig build`
Expected: Compiles successfully

**Step 3: Commit**

```bash
git add src/cancel.zig
git commit -m "refactor: make cancel.zig a thin wrapper over TerminalManager"
```

---

## Task 2: Update line_editor.zig to use push/pop

**TDD scenario:** Modifying tested code — manual test after changes

**Files:**
- Modify: `src/line_editor.zig`

**Step 1: Remove local termios handling, use terminal manager**

Find the section near line 95-105 that has:
```zig
const original = std.posix.tcgetattr(stdin_file.handle) catch { ... };
cancel.saveOriginalTermios(original);
// Save to global so signal handler can restore on Ctrl+C
cancel.saveOriginalTermios(original);

var raw = original;
// ... raw mode setup ...
std.posix.tcsetattr(stdin_file.handle, .NOW, raw) catch ...;
```

Replace with:
```zig
const terminal = @import("terminal.zig");

// At start of readPromptLine, after prompt setup:
terminal.get().pushRaw();
defer terminal.get().popRaw();
```

**Step 2: Remove the old defer block**

Find and remove the defer that does manual cleanup:
```zig
defer {
    cancel.drainStdin();
    std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};
}
```

**Step 3: Update shouldExit check**

The check `if (cancel.shouldExit())` should still work since cancel.zig wraps the terminal manager.

**Step 4: Build to verify**

Run: `zig build`
Expected: Compiles successfully

**Step 5: Commit**

```bash
git add src/line_editor.zig
git commit -m "refactor: use TerminalManager in line_editor.zig"
```

---

## Task 3: Update repl/main.zig raw mode calls

**TDD scenario:** Modifying existing code — verify build and test

**Files:**
- Modify: `src/repl/main.zig`

**Step 1: Find enableRawMode/disableRawMode calls**

Search for these patterns:
- `cancel.enableRawMode()`
- `cancel.disableRawMode()`

**Step 2: Review and simplify**

The calls should still work via the cancel.zig wrapper. Just verify they're in the right places:
- `enableRawMode()` before model processing
- `disableRawMode()` after (in defer)

If there are redundant calls, remove them. The push/pop pattern handles nesting.

**Step 3: Build to verify**

Run: `zig build`
Expected: Compiles successfully

**Step 4: Commit**

```bash
git add src/repl/main.zig
git commit -m "refactor: verify raw mode calls use TerminalManager"
```

---

## Task 4: Update main.zig init/deinit

**TDD scenario:** Modifying existing code — verify build

**Files:**
- Modify: `src/main.zig`

**Step 1: Verify cancel.init() and cancel.deinit() are called**

The existing `cancel.init()` and `cancel.deinit()` calls should work, but verify they're at the right scope:
- `init()` called early in main (before any terminal operations)
- `deinit()` called on exit (via defer or explicit call)

**Step 2: Check error handling path**

Verify that `cancel.deinit()` runs even on error:
```zig
repl.run(...) catch |err| {
    cancel.deinit();
    return err;
};
```

**Step 3: Build to verify**

Run: `zig build`
Expected: Compiles successfully

**Step 4: Commit**

```bash
git add src/main.zig
git commit -m "refactor: verify init/deinit use TerminalManager"
```

---

## Task 5: Build and test

**TDD scenario:** Integration test — manual verification

**Step 1: Full build**

Run: `zig build`
Expected: Clean build with no errors

**Step 2: Manual test - Normal exit**

```bash
./zig-out/bin/zagent
# Type: hello
# Wait for response
# Type: /quit
# Press up arrow in shell
```
Expected: Shell history works, no escape codes

**Step 3: Manual test - Single Ctrl+C**

```bash
./zig-out/bin/zagent
# Press Ctrl+C once
# Press up arrow
```
Expected: Shell history works, prompt resets

**Step 4: Manual test - Double Ctrl+C**

```bash
./zig-out/bin/zagent
# Press Ctrl+C twice rapidly
# Press up arrow in shell
```
Expected: Shell history works, no escape codes, cursor at bottom

**Step 5: Manual test - Triple Ctrl+C**

```bash
./zig-out/bin/zagent
# Press Ctrl+C three times rapidly
```
Expected: Immediate exit (nuclear option)

**Step 6: Final commit**

```bash
git add -A
git commit -m "fix: terminal cleanup on Ctrl+C via TerminalManager"
```

---

## Checkpoint

After all tasks complete:
- Terminal is always restored on exit
- Double Ctrl+C restores terminal before exit
- Triple Ctrl+C forces immediate exit
- Push/pop pattern allows nested raw mode safely
- Single source of truth in `terminal.zig`