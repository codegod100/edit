const std = @import("std");

// Readline support is available when compiled with -Dreadline flag
// Otherwise this module provides stub implementations
pub const have_readline = false;

pub const ReadlineError = error{
    InitializationFailed,
    ReadFailed,
    NotAvailable,
};

pub fn init() !void {
    return ReadlineError.NotAvailable;
}

pub fn deinit() void {
    // No-op
}

pub fn readPrompt(_: std.mem.Allocator, _: []const u8) !?[]u8 {
    return ReadlineError.NotAvailable;
}

pub fn addToHistory(_: []const u8) void {
    // No-op
}
