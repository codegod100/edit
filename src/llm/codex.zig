const std = @import("std");
const types = @import("types.zig");

fn writeJsonString(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '\"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 32) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

pub fn buildCodexBody(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    // Parse messages to transform from standard chat format to Codex format
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, messages_json, .{ .ignore_unknown_fields = true }) catch return types.QueryError.ModelResponseParseError;
    defer parsed.deinit();

    if (parsed.value != .array) return types.QueryError.ModelResponseParseError;

    var instructions: std.ArrayList(u8) = .empty;
    defer instructions.deinit(allocator);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    const w_in = input.writer(allocator);

    try w_in.writeAll("[");
    var wrote_any = false;

    for (parsed.value.array.items) |msg| {
        if (msg != .object) continue;
        const role = if (msg.object.get("role")) |r| (if (r == .string) r.string else "") else "";
        const content = if (msg.object.get("content")) |c| (if (c == .string) c.string else "") else "";

        if (std.mem.eql(u8, role, "system")) {
            if (instructions.items.len > 0) try instructions.appendSlice(allocator, "\n");
            try instructions.appendSlice(allocator, content);
            continue;
        }

        if (wrote_any) try w_in.writeAll(",");
        wrote_any = true;

        var out_role = role;
        var out_content = content;
        var owned_content: ?[]u8 = null;
        defer if (owned_content) |b| allocator.free(b);

        if (std.mem.eql(u8, role, "tool")) {
            out_role = "user";
            owned_content = try std.fmt.allocPrint(allocator, "[tool]\n{s}", .{content});
            out_content = owned_content.?;
        }

        // Map roles to Codex expected values
        try w_in.writeAll("{\"type\":\"message\",\"role\":\"");
        try w_in.writeAll(if (std.mem.eql(u8, out_role, "assistant")) "assistant" else "user");
        try w_in.writeAll("\",\"content\":[{\"type\":\"");
        try w_in.writeAll(if (std.mem.eql(u8, out_role, "assistant")) "output_text" else "input_text");
        try w_in.writeAll("\",\"text\":\"");
        try writeJsonString(w_in, out_content);
        try w_in.writeAll("\"}]}");
    }
    try w_in.writeAll("]");

    try w.print("{{\"model\":\"{s}\",\"instructions\":\"", .{model_id});
    try writeJsonString(w, instructions.items);
    try w.writeAll("\",\"input\":");
    try w.writeAll(input.items);

    if (tool_defs) |defs| {
        try w.writeAll(",\"tools\":[");
        for (defs, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"type\":\"function\",\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s},\"strict\":true}}", .{ d.name, d.description, d.parameters_json });
        }
        try w.writeAll("]");
    }

    try w.writeAll(",\"tool_choice\":\"auto\",\"stream\":true}");
    return out.toOwnedSlice(allocator);
}

pub fn parseCodexStream(allocator: std.mem.Allocator, raw: []const u8) !types.ChatResponse {
    var out_text: std.ArrayList(u8) = .empty;
    defer out_text.deinit(allocator);

    var current_tool_name: ?[]u8 = null;
    var current_tool_args: std.ArrayList(u8) = .empty;
    defer current_tool_args.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const payload = std.mem.trim(u8, trimmed[5..], " \t");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;

        const Event = struct {
            type: ?[]const u8 = null,
            item: ?struct {
                type: ?[]const u8 = null,
                name: ?[]const u8 = null,
                arguments: ?[]const u8 = null,
            } = null,
            delta: ?[]const u8 = null,
            output_text: ?[]const u8 = null,
        };
        var ev = std.json.parseFromSlice(Event, allocator, payload, .{ .ignore_unknown_fields = true }) catch continue;
        defer ev.deinit();

        if (ev.value.item) |itm| {
            if (std.mem.eql(u8, itm.type orelse "", "function_call")) {
                if (itm.name) |n| {
                    if (current_tool_name) |old| allocator.free(old);
                    current_tool_name = try allocator.dupe(u8, n);
                    current_tool_args.clearRetainingCapacity();
                }
                if (itm.arguments) |a| try current_tool_args.appendSlice(allocator, a);
            }
        }

        if (ev.value.type) |t| {
            if (std.mem.endsWith(u8, t, "function_call_arguments.delta")) {
                if (ev.value.delta) |d| try current_tool_args.appendSlice(allocator, d);
            }
            if (std.mem.endsWith(u8, t, ".delta")) {
                // Should be content delta?
                if (ev.value.output_text) |ot| try out_text.appendSlice(allocator, ot);
                // Sometimes delta itself is text?
                if (ev.value.delta) |d| {
                    if (current_tool_name == null) {
                        try out_text.appendSlice(allocator, d);
                    }
                }
            }
        } else {
            // Fallback if no type, check output_text
            if (ev.value.output_text) |t| try out_text.appendSlice(allocator, t);
        }
    }

    if (current_tool_name) |name| {
        const calls = try allocator.alloc(types.ToolCall, 1);
        calls[0] = .{
            .id = try allocator.dupe(u8, "call_0"),
            .tool = name, // ownership transferred
            .args = try current_tool_args.toOwnedSlice(allocator),
        };
        return .{
            .text = try allocator.dupe(u8, ""),
            .reasoning = try allocator.dupe(u8, ""),
            .tool_calls = calls,
            .finish_reason = try allocator.dupe(u8, "tool_calls"),
        };
    }

    return .{
        .text = try out_text.toOwnedSlice(allocator),
        .reasoning = try allocator.dupe(u8, ""),
        .tool_calls = try allocator.alloc(types.ToolCall, 0),
        .finish_reason = try allocator.dupe(u8, "stop"),
    };
}
