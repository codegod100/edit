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
        self.drainStdin();
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
        raw.lflag.ICANON = false; // Disable line buffering
        raw.lflag.ECHO = false; // Disable echo
        raw.lflag.ISIG = true; // Keep signal handling (Ctrl+C works)

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