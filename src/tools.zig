const std = @import("std");

pub const ToolError = error{InvalidToolCommand};
pub const NamedToolError = error{ InvalidToolName, InvalidArguments };

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const definitions = [_]ToolDef{
    .{ .name = "bash", .description = "Execute a shell command and return stdout.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"],\"additionalProperties\":false}" },
    .{ .name = "read_file", .description = "Read a file and return its contents.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}" },
    .{ .name = "list_files", .description = "List files and directories in a folder.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}" },
    .{ .name = "write_file", .description = "Write complete file contents to a path.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}" },
    .{ .name = "replace_in_file", .description = "Replace text in a file.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"find\",\"replace\"],\"additionalProperties\":false}" },
};

pub fn list() []const []const u8 {
    return &.{ "bash <command>", "read <path>", "list <path>", "write <path>", "replace <path>" };
}

pub fn execute(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    if (trimmed.len == 0) return ToolError.InvalidToolCommand;

    if (std.mem.startsWith(u8, trimmed, "read ")) {
        const path = std.mem.trim(u8, trimmed[5..], " \t");
        if (path.len == 0) return ToolError.InvalidToolCommand;
        return std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    }

    if (std.mem.startsWith(u8, trimmed, "list ")) {
        const path = std.mem.trim(u8, trimmed[5..], " \t");
        if (path.len == 0) return ToolError.InvalidToolCommand;
        return runBash(allocator, try std.fmt.allocPrint(allocator, "ls -la {s}", .{path}));
    }

    if (std.mem.startsWith(u8, trimmed, "bash ")) {
        const command = std.mem.trim(u8, trimmed[5..], " \t");
        if (command.len == 0) return ToolError.InvalidToolCommand;
        return runBash(allocator, command);
    }

    return ToolError.InvalidToolCommand;
}

pub fn executeNamed(allocator: std.mem.Allocator, name: []const u8, arguments_json: []const u8) ![]u8 {
    if (std.mem.eql(u8, name, "bash")) {
        const A = struct { command: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        return runBash(allocator, p.value.command orelse return NamedToolError.InvalidArguments);
    }
    if (std.mem.eql(u8, name, "read_file")) {
        const A = struct { path: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        return std.fs.cwd().readFileAlloc(allocator, p.value.path orelse return NamedToolError.InvalidArguments, 1024 * 1024);
    }
    if (std.mem.eql(u8, name, "list_files")) {
        const A = struct { path: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse ".";
        const cmd = try std.fmt.allocPrint(allocator, "ls -la {s}", .{path});
        defer allocator.free(cmd);
        return runBash(allocator, cmd);
    }
    if (std.mem.eql(u8, name, "write_file")) {
        const A = struct { path: ?[]const u8 = null, content: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse return NamedToolError.InvalidArguments;
        const content = p.value.content orelse return NamedToolError.InvalidArguments;
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
        return allocator.dupe(u8, "ok");
    }
    if (std.mem.eql(u8, name, "replace_in_file")) {
        const A = struct {
            path: ?[]const u8 = null,
            find: ?[]const u8 = null,
            replace: ?[]const u8 = null,
            all: ?bool = null,
        };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse return NamedToolError.InvalidArguments;
        const find = p.value.find orelse return NamedToolError.InvalidArguments;
        const repl = p.value.replace orelse return NamedToolError.InvalidArguments;
        const replace_all = p.value.all orelse true;

        const original = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
        defer allocator.free(original);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        var cursor: usize = 0;
        var replaced: usize = 0;
        while (std.mem.indexOfPos(u8, original, cursor, find)) |idx| {
            try out.appendSlice(allocator, original[cursor..idx]);
            try out.appendSlice(allocator, repl);
            cursor = idx + find.len;
            replaced += 1;
            if (!replace_all) break;
        }
        try out.appendSlice(allocator, original[cursor..]);
        if (replaced == 0) return allocator.dupe(u8, "no-op: pattern not found");
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(out.items);
        return std.fmt.allocPrint(allocator, "ok: replaced {d}", .{replaced});
    }
    return NamedToolError.InvalidToolName;
}

fn runBash(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", command },
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stderr);
    return result.stdout;
}
