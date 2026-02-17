const std = @import("std");
const types = @import("types.zig");
const client = @import("client.zig");
const utils = @import("utils.zig");

pub fn chat(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
) !types.ChatResponse {
    const body = try buildBody(allocator, model_id, messages_json, tool_defs);
    defer allocator.free(body);

    const headers = std.http.Client.Request.Headers{
        .content_type = .{ .override = "application/json" },
        .user_agent = .{ .override = "zagent/0.1" },
    };
    const extra = [_]std.http.Header{
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "anthropic-beta", .value = "prompt-caching-2024-07-31" },
    };

    const raw = try client.httpRequest(allocator, .POST, "https://api.anthropic.com/v1/messages", headers, &extra, body);
    defer allocator.free(raw);

    return parseResponse(allocator, raw);
}

fn buildBody(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, messages_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.writeAll("{");
    try w.print("\"model\":{f},", .{std.json.fmt(model_id, .{})});
    try w.writeAll("\"max_tokens\":4096,");

    // Separate system and messages
    var system_prompt: ?[]const u8 = null;
    var messages: std.ArrayListUnmanaged(std.json.Value) = .empty;
    defer messages.deinit(allocator);

    for (parsed.value.array.items) |msg| {
        const role = msg.object.get("role").?.string;
        if (std.mem.eql(u8, role, "system")) {
            system_prompt = msg.object.get("content").?.string;
        } else {
            try messages.append(allocator, msg);
        }
    }

    if (system_prompt) |sp| {
        try w.writeAll("\"system\":[{\"type\":\"text\",\"text\":");
        try w.print("{f}", .{std.json.fmt(sp, .{})});
        try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}],");
    }

    try w.writeAll("\"messages\":[");
    for (messages.items, 0..) |msg, i| {
        if (i > 0) try w.writeAll(",");
        
        const role = msg.object.get("role").?.string;
        // Cache the last user message to provide a prefix for the next turn
        const is_last_user = (i == messages.items.len - 1 and std.mem.eql(u8, role, "user"));
        
        if (is_last_user) {
            try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
            try w.print("{f}", .{std.json.fmt(msg.object.get("content").?.string, .{})});
            try w.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}]}");
        } else if (std.mem.eql(u8, role, "assistant") and msg.object.get("tool_calls") != null) {
            // Convert assistant tool calls to Anthropic format
            try w.writeAll("{\"role\":\"assistant\",\"content\":[");
            if (msg.object.get("content")) |c| {
                if (c == .string and c.string.len > 0) {
                    try w.writeAll("{\"type\":\"text\",\"text\":");
                    try w.print("{f}", .{std.json.fmt(c.string, .{})});
                    try w.writeAll("},");
                }
            }
            
            const tc_array = msg.object.get("tool_calls").?.array;
            for (tc_array.items, 0..) |tc, j| {
                if (j > 0) try w.writeAll(",");
                try w.writeAll("{\"type\":\"tool_use\",\"id\":");
                try w.print("{f}", .{std.json.fmt(tc.object.get("id").?.string, .{})});
                try w.writeAll(",\"name\":");
                try w.print("{f}", .{std.json.fmt(tc.object.get("function").?.object.get("name").?.string, .{})});
                try w.writeAll(",\"input\":");
                // Anthropic expects input as object, our args are JSON string
                const args_str = tc.object.get("function").?.object.get("arguments").?.string;
                try w.writeAll(args_str);
                try w.writeAll("}");
            }
            try w.writeAll("]}");
        } else if (std.mem.eql(u8, role, "tool")) {
            // Convert tool result to Anthropic format
            try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
            try w.print("{f}", .{std.json.fmt(msg.object.get("tool_call_id").?.string, .{})});
            try w.writeAll(",\"content\":");
            try w.print("{f}", .{std.json.fmt(msg.object.get("content").?.string, .{})});
            try w.writeAll("}]}");
        } else {
            try w.print("{f}", .{std.json.fmt(msg, .{})});
        }
    }
    try w.writeAll("]");

    // Tools
    if (tool_defs) |defs| {
        if (defs.len > 0) {
            try w.writeAll(",\"tools\":[");
            for (defs, 0..) |d, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"name\":{f},\"description\":{f},\"input_schema\":{s}}}", .{ 
                    std.json.fmt(d.name, .{}), 
                    std.json.fmt(d.description, .{}), 
                    d.parameters_json 
                });
            }
            try w.writeAll("]");
        }
    }

    try w.writeAll("}");
    return out.toOwnedSlice(allocator);
}

fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) !types.ChatResponse {
    const Resp = struct {
        content: []const struct {
            type: []const u8,
            text: ?[]const u8 = null,
            id: ?[]const u8 = null,
            name: ?[]const u8 = null,
            input: ?std.json.Value = null,
        },
        stop_reason: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(Resp, allocator, raw, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var text: []u8 = try allocator.dupe(u8, "");
    var tool_calls: std.ArrayListUnmanaged(types.ToolCall) = .empty;
    errdefer {
        allocator.free(text);
        for (tool_calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.tool);
            allocator.free(tc.args);
        }
        tool_calls.deinit(allocator);
    }

    for (parsed.value.content) |item| {
        if (std.mem.eql(u8, item.type, "text")) {
            if (item.text) |t| {
                const old_text = text;
                text = try std.mem.concat(allocator, u8, &.{ old_text, t });
                allocator.free(old_text);
            }
        } else if (std.mem.eql(u8, item.type, "tool_use")) {
            // Use std.json.fmt to stringify input object back to JSON string
            const args_json = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(item.input.?, .{})});
            
            try tool_calls.append(allocator, .{
                .id = try allocator.dupe(u8, item.id.?),
                .tool = try allocator.dupe(u8, item.name.?),
                .args = args_json,
            });
        }
    }

    return .{
        .text = text,
        .reasoning = try allocator.dupe(u8, ""),
        .tool_calls = try tool_calls.toOwnedSlice(allocator),
        .finish_reason = try allocator.dupe(u8, parsed.value.stop_reason orelse "stop"),
    };
}
