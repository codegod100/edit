const std = @import("std");

pub const ToolError = error{InvalidToolCommand};

pub fn list() []const []const u8 {
    return &.{ "read <path>", "bash <command>" };
}

pub fn execute(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    if (trimmed.len == 0) return ToolError.InvalidToolCommand;

    if (std.mem.startsWith(u8, trimmed, "read ")) {
        const path = std.mem.trim(u8, trimmed[5..], " \t");
        if (path.len == 0) return ToolError.InvalidToolCommand;
        return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    }

    if (std.mem.startsWith(u8, trimmed, "bash ")) {
        const command = std.mem.trim(u8, trimmed[5..], " \t");
        if (command.len == 0) return ToolError.InvalidToolCommand;

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "sh", "-c", command },
            .max_output_bytes = 256 * 1024,
        });
        defer allocator.free(result.stderr);

        return result.stdout;
    }

    return ToolError.InvalidToolCommand;
}
