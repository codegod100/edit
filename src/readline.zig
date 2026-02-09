const std = @import("std");

// Readline module - currently uses fallback implementation in Zig
// We use our custom readPromptLineFallback instead of an external library
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
