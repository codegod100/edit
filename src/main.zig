const std = @import("std");
const repl = @import("repl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    try repl.run(allocator);
}

test {
    _ = @import("skills.zig");
    _ = @import("repl.zig");
    _ = @import("provider_manager.zig");
    _ = @import("provider_store.zig");
}
