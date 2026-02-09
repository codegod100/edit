const std = @import("std");
const repl = @import("repl.zig");
const logger = @import("logger.zig");

pub fn multiply(a: i32, b: i32) i32 {
    return a * b;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Initialize verbose logging
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const log_path = try std.fs.path.join(allocator, &.{ home, ".config", "zagent", "debug.log" });
    defer allocator.free(log_path);

    try logger.init(allocator, .info, log_path);
    defer logger.deinit();

    logger.info("zagent starting up", .{});

    const result = multiply(10, 5);
    std.debug.print("10 * 5 = {}\n", .{result});

    try repl.run(allocator);

    logger.info("zagent shutting down", .{});
}

test {
    _ = @import("config_store.zig");
    _ = @import("llm.zig");
    _ = @import("models_catalog.zig");
    _ = @import("skills.zig");
    _ = @import("repl.zig");
    _ = @import("provider_manager.zig");
    _ = @import("provider_store.zig");
    _ = @import("logger.zig");
    _ = @import("ai_bridge.zig");
}
