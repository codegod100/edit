const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const sigset_t = linux.sigset_t;

var g_cancel_requested: bool = false;
var g_original_termios: ?std.posix.termios = null;

pub fn isCancelled() bool {
    return @atomicLoad(bool, &g_cancel_requested, .monotonic);
}

pub fn setCancelled() void {
    @atomicStore(bool, &g_cancel_requested, true, .monotonic);
}

pub fn resetCancelled() void {
    @atomicStore(bool, &g_cancel_requested, false, .monotonic);
}

var g_original_sigint: ?linux.Sigaction.handler_fn = null;

fn sigintHandler(sig: c_int) callconv(.c) void {
    _ = sig;
    @atomicStore(bool, &g_cancel_requested, true, .monotonic);
}

pub fn init() void {
    if (builtin.os.tag == .linux) {
        var act: linux.Sigaction = .{
            .handler = .{ .handler = @as(linux.Sigaction.handler_fn, @ptrCast(&sigintHandler)) },
            .mask = std.mem.zeroes(linux.sigset_t),
            .flags = linux.SA.RESTART,
        };
        var old: linux.Sigaction = undefined;
        _ = linux.sigaction(linux.SIG.INT, &act, &old);
        g_original_sigint = old.handler.handler;
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
}

pub fn deinit() void {
    if (builtin.os.tag == .linux) {
        if (g_original_sigint) |old_handler| {
            var act: linux.Sigaction = .{
                .handler = .{ .handler = old_handler },
                .mask = std.mem.zeroes(linux.sigset_t),
                .flags = 0,
            };
            _ = linux.sigaction(linux.SIG.INT, &act, null);
        }
    }
}

/// Set stdin to raw non-blocking mode for ESC detection during processing
pub fn enableRawMode() void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return;
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) return;

    if (g_original_termios == null) {
        g_original_termios = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch null;
    }

    if (g_original_termios) |orig| {
        var raw = orig;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        // VMIN=0, VTIME=0 for non-blocking
        if (builtin.os.tag == .linux) {
            raw.cc[6] = 0; // VMIN
            raw.cc[5] = 0; // VTIME
        } else if (builtin.os.tag == .macos) {
            raw.cc[16] = 0; // VMIN
            raw.cc[17] = 0; // VTIME
        }
        _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch {};

        // Set non-blocking
        const O_NONBLOCK: u32 = if (builtin.os.tag == .linux) 0o4000 else 0x0004;
        if (std.posix.fcntl(std.posix.STDIN_FILENO, std.posix.F.GETFL, 0)) |flags| {
            _ = std.posix.fcntl(std.posix.STDIN_FILENO, std.posix.F.SETFL, flags | O_NONBLOCK) catch {};
        } else |_| {}
    }
}

/// Restore stdin to normal mode for input
pub fn disableRawMode() void {
    if (g_original_termios) |orig| {
        _ = std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, orig) catch {};

        // Restore blocking mode
        const O_NONBLOCK: u32 = if (builtin.os.tag == .linux) 0o4000 else 0x0004;
        if (std.posix.fcntl(std.posix.STDIN_FILENO, std.posix.F.GETFL, 0)) |flags| {
            _ = std.posix.fcntl(std.posix.STDIN_FILENO, std.posix.F.SETFL, flags & ~O_NONBLOCK) catch {};
        } else |_| {}
    }
}

/// Poll stdin for ESC key (call during processing)
pub fn pollForEscape() void {
    if (g_original_termios == null) return;

    var buf: [64]u8 = undefined;
    const n = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
    if (n > 0) {
        for (buf[0..n]) |byte| {
            if (byte == 0x1B) {
                @atomicStore(bool, &g_cancel_requested, true, .monotonic);
            }
        }
    }
}
