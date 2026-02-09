// Deprecated: Line handling is now implemented directly in the REPL module
// This file is kept for compatibility but should not be used

const std = @import("std");

pub const have_readline = false;

pub const ReadlineError = error{
    NotAvailable,
};

pub fn init() !void {
    return ReadlineError.NotAvailable;
}

pub fn deinit() void {}

pub fn readPrompt(_: std.mem.Allocator, _: []const u8) !?[]u8 {
    return ReadlineError.NotAvailable;
}

pub fn addToHistory(_: []const u8) void {}
