const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("terminal.zig");

// =============================================================================
// Ctrl+C Handling - Thin wrapper over TerminalManager
// =============================================================================
//
// This module provides backward-compatible API over the unified TerminalManager.
// All terminal state is managed by terminal.zig.
//
// States:
// 1. Normal - running, no interrupt
// 2. Cancelled - first Ctrl+C, should abort current operation
// 3. ExitRequested - second Ctrl+C, should exit immediately
//
// =============================================================================

/// Check if cancellation was requested
pub fn isCancelled() bool {
    return terminal.get().isCancelled();
}

/// Set cancellation flag (called on interrupt)
pub fn setCancelled() void {
    @atomicStore(bool, &terminal.get().cancelled, true, .monotonic);
}

/// Reset cancellation state (call before starting new input)
pub fn resetCancelled() void {
    terminal.get().reset();
}

/// Save original termios (for backward compatibility - no longer needed)
pub fn saveOriginalTermios(termios: std.posix.termios) void {
    // No longer needed - TerminalManager saves at init time
    _ = termios;
}

/// Check if exit was requested (double Ctrl+C)
pub fn shouldExit() bool {
    return terminal.get().shouldExit();
}

/// Prepare for processing (reset state)
pub fn beginProcessing() void {
    terminal.get().reset();
}

// =============================================================================
// Terminal Management - delegated to TerminalManager
// =============================================================================

/// Enable raw mode for interactive input
pub fn enableRawMode() void {
    terminal.get().pushRaw();
}

/// Disable raw mode and restore terminal
pub fn disableRawMode() void {
    terminal.get().popRaw();
}

/// Drain stdin buffer - MUST be called BEFORE restoring terminal
pub fn drainStdin() void {
    terminal.get().drainStdin();
}

/// Full cleanup: drain stdin, restore terminal
/// Call this before any exit
pub fn cleanup() void {
    const tm = terminal.get();
    tm.drainStdin();
    tm.restore();
}

// =============================================================================
// Signal Handling - delegated to TerminalManager
// =============================================================================

/// Install signal handlers
pub fn init() void {
    const tm = terminal.get();
    tm.init();
    tm.installSignalHandler(true);
}

/// Restore original signal handlers and clean up
pub fn deinit() void {
    terminal.get().deinit();
}

// =============================================================================
// Escape Key Polling (for cancel checking during processing)
// =============================================================================

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