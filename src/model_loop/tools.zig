const std = @import("std");
const tools = @import("../tools.zig");
const display = @import("../display.zig");
const todo = @import("../todo.zig");
const utils = @import("../utils.zig");
const cancel = @import("../cancel.zig");
const orchestrator = @import("orchestrator.zig");

pub fn executeInlineToolCalls(
    allocator: std.mem.Allocator,
    stdout: anytype,
    response: []const u8,
    paths: *std.ArrayList([]u8),
    tool_calls: *usize,
    todo_list: *todo.TodoList,
) !?[]u8 {
    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer result_buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        if (cancel.isCancelled()) {
            try result_buf.writer(allocator).writeAll("Operation cancelled by user.");
            break;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "TOOL_CALL ")) continue;

        // Parse: TOOL_CALL name args
        const after_prefix = trimmed[10..]; // Skip "TOOL_CALL "
        const space_idx = std.mem.indexOfScalar(u8, after_prefix, ' ') orelse continue;
        const tool_name = after_prefix[0..space_idx];
        const args = std.mem.trim(u8, after_prefix[space_idx..], " \t");

        if (!tools.isKnownToolName(tool_name)) continue;

        tool_calls.* += 1;

        // Track path
        if (tools.parsePrimaryPathFromArgs(allocator, args)) |p| {
            var found = false;
            for (paths.items) |existing| {
                if (std.mem.eql(u8, existing, p)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try paths.append(p);
            } else {
                allocator.free(p);
            }
        }

        // Extract file path, bash command, or read params from args for display
        const file_path = tools.parsePrimaryPathFromArgs(allocator, args);
        defer if (file_path) |fp| allocator.free(fp);
        const bash_cmd = if (std.mem.eql(u8, tool_name, "bash"))
            tools.parseBashCommandFromArgs(allocator, args)
        else
            null;
        defer if (bash_cmd) |bc| allocator.free(bc);
        const read_params = if (std.mem.eql(u8, tool_name, "read") or std.mem.eql(u8, tool_name, "read_file"))
            try tools.parseReadParamsFromArgs(allocator, args)
        else
            null;

        // Build tool call description for timeline
        var tool_desc_buf: [512]u8 = undefined;
        var tool_desc_pos: usize = 0;
        const tool_desc_w = std.io.fixedBufferStream(&tool_desc_buf);
        const tool_desc_writer = tool_desc_w.writer();
        const shown_tool_name = if (std.mem.eql(u8, tool_name, "list_files") or std.mem.eql(u8, tool_name, "list"))
            "listing files in"
        else if (std.mem.eql(u8, tool_name, "set_status"))
            "updating status"
        else
            tool_name;
        tool_desc_writer.print("{s}• {s}{s}", .{ display.C_CYAN, shown_tool_name, display.C_RESET }) catch {};
        tool_desc_pos = @min(shown_tool_name.len + 2 + display.C_CYAN.len + display.C_RESET.len, tool_desc_buf.len);
        if (file_path) |fp| {
            const written = (std.fmt.bufPrint(tool_desc_buf[tool_desc_pos..], " {s}file={s}{s}", .{ display.C_CYAN, fp, display.C_RESET }) catch "").len;
            tool_desc_pos += written;
        }
        if (bash_cmd) |bc| {
            const max_cmd_len = 60;
            const display_cmd = if (bc.len > max_cmd_len) bc[0..max_cmd_len] else bc;
            const suffix = if (bc.len > max_cmd_len) "..." else "";
            const written = (std.fmt.bufPrint(tool_desc_buf[tool_desc_pos..], " {s}cmd=\"{s}{s}\"{s}", .{ display.C_CYAN, display_cmd, suffix, display.C_RESET }) catch "").len;
            tool_desc_pos += written;
        }
        if (read_params) |rp| {
            if (rp.offset) |off| {
                const written = (std.fmt.bufPrint(tool_desc_buf[tool_desc_pos..], " {s}offset={d}{s}", .{ display.C_DIM, off, display.C_RESET }) catch "").len;
                tool_desc_pos += written;
            }
            if (rp.limit) |lim| {
                const written = (std.fmt.bufPrint(tool_desc_buf[tool_desc_pos..], " {s}limit={d}{s}", .{ display.C_DIM, lim, display.C_RESET }) catch "").len;
                tool_desc_pos += written;
            }
        }
        orchestrator.toolOutput("{s}", .{tool_desc_buf[0..tool_desc_pos]});

        const tool_out = tools.executeNamed(allocator, tool_name, args, todo_list) catch |err| {
            if (err == tools.NamedToolError.Cancelled or cancel.isCancelled()) {
                try result_buf.writer(allocator).writeAll("Operation cancelled by user.");
                break;
            }
            try result_buf.writer(allocator).print("Tool {s} failed: {s}\n", .{ shown_tool_name, @errorName(err) });
            continue;
        };
        defer allocator.free(tool_out);

        if (tool_out.len > 0) {
            try display.printTruncatedCommandOutput(stdout, tool_out);
        }

        const no_ansi = try display.stripAnsi(allocator, tool_out);
        defer allocator.free(no_ansi);
        const clean_out = try utils.sanitizeTextForModel(allocator, no_ansi, 128 * 1024);
        defer allocator.free(clean_out);

        try result_buf.writer(allocator).print("Tool {s} result:\n{s}\n", .{ shown_tool_name, clean_out });
    }

    if (result_buf.items.len == 0) return null;
    const value = try result_buf.toOwnedSlice(allocator);
    return @as(?[]u8, value);
}
