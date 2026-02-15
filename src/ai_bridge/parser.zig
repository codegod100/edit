const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");
const logger = @import("../logger.zig");

pub fn parseCodexResponsesStream(allocator: std.mem.Allocator, raw: []const u8) !types.ChatResponse {
    errors.clearLastProviderError();

    // Expect SSE payload when stream=true.
    if (std.mem.indexOf(u8, raw, "data:") == null) {
        return try parseNonStreamResponse(allocator, raw);
    }

    var out_text: std.ArrayList(u8) = .empty;
    defer out_text.deinit(allocator);

    var current_name: ?[]u8 = null;
    defer if (current_name) |n| allocator.free(n);
    var args: std.ArrayList(u8) = .empty;
    defer args.deinit(allocator);
    var saw_args_delta: bool = false;

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line[5..], " \t");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;

        var ev = std.json.parseFromSlice(types.SSEEvent, allocator, payload, .{ .ignore_unknown_fields = true }) catch continue;
        defer ev.deinit();

        if (ev.value.item) |item| {
            if (item.type != null and std.mem.eql(u8, item.type.?, "function_call")) {
                if (current_name) |n| allocator.free(n);
                current_name = if (item.name) |n| try allocator.dupe(u8, n) else null;
                args.clearRetainingCapacity();
                saw_args_delta = false;
                if (item.arguments) |a| try args.appendSlice(allocator, a);
            }
        }
        if (ev.value.type) |t| {
            if (std.mem.endsWith(u8, t, "function_call_arguments.delta")) {
                if (!saw_args_delta) {
                    saw_args_delta = true;
                    if (args.items.len > 0) args.clearRetainingCapacity();
                }
                if (ev.value.delta) |d| try args.appendSlice(allocator, d);
                continue;
            }
            if (std.mem.endsWith(u8, t, ".delta")) {
                const piece = ev.value.delta orelse ev.value.text orelse ev.value.output_text;
                if (piece) |p| try out_text.appendSlice(allocator, p);
            }
        }
    }

    if (current_name != null and args.items.len > 0) {
        const calls = try allocator.alloc(types.ToolCall, 1);
        calls[0] = .{
            .id = try allocator.dupe(u8, "call_0"),
            .tool = current_name.?,
            .args = try allocator.dupe(u8, args.items),
        };
        current_name = null;
        return .{
            .text = try allocator.dupe(u8, ""),
            .reasoning = try allocator.dupe(u8, ""),
            .tool_calls = calls,
            .finish_reason = try allocator.dupe(u8, "tool_calls"),
        };
    }

    return .{
        .text = try allocator.dupe(u8, out_text.items),
        .reasoning = try allocator.dupe(u8, ""),
        .tool_calls = try allocator.alloc(types.ToolCall, 0),
        .finish_reason = try allocator.dupe(u8, "stop"),
    };
}

fn parseNonStreamResponse(allocator: std.mem.Allocator, raw: []const u8) !types.ChatResponse {
    // Attempt to parse JSON error shapes.
    if (std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true })) |root_parsed| {
        defer root_parsed.deinit();
        if (root_parsed.value == .object) {
            if (root_parsed.value.object.get("error")) |err_val| {
                if (err_val == .object) {
                    if (err_val.object.get("message")) |m| if (m == .string) errors.setLastProviderError(m.string);
                } else if (err_val == .string) {
                    errors.setLastProviderError(err_val.string);
                }
                return errors.ProviderError.ModelProviderError;
            }
            // Some providers return non-stream JSON even when stream=true.
            if (root_parsed.value.object.get("output")) |out_val| {
                if (out_val == .array) {
                    return try parseOutputArray(allocator, out_val, root_parsed);
                }
            }
            if (root_parsed.value.object.get("detail")) |d| {
                if (d == .string) {
                    errors.setLastProviderError(d.string);
                    return errors.ProviderError.ModelProviderError;
                }
            }
        }
    } else |_| {}

    // Plain-text provider errors
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len > 0) {
        const cap = @min(trimmed.len, 300);
        errors.setLastProviderError(trimmed[0..cap]);
        return errors.ProviderError.ModelProviderError;
    }

    errors.setLastProviderError("unexpected non-stream response from codex backend");
    return errors.ProviderError.ModelResponseParseError;
}

fn parseOutputArray(allocator: std.mem.Allocator, out_val: std.json.Value, root_parsed: std.json.Parsed(std.json.Value)) !types.ChatResponse {
    var out_text = std.ArrayList(u8).empty;
    defer out_text.deinit(allocator);

    var tool_name: ?[]const u8 = null;
    var tool_args: ?[]const u8 = null;

    for (out_val.array.items) |item| {
        if (item != .object) continue;
        const obj = item.object;
        const typ = if (obj.get("type")) |t| if (t == .string) t.string else "" else "";

        if (std.mem.eql(u8, typ, "function_call")) {
            if (obj.get("name")) |n| {
                if (n == .string) tool_name = n.string;
            }
            if (obj.get("arguments")) |a| {
                if (a == .string) tool_args = a.string;
            }
            continue;
        }

        if (obj.get("text")) |txt| {
            if (txt == .string) {
                try out_text.appendSlice(allocator, txt.string);
            }
        }
        if (obj.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |part| {
                    if (part != .object) continue;
                    if (part.object.get("text")) |pt| {
                        if (pt == .string) try out_text.appendSlice(allocator, pt.string);
                    }
                }
            }
        }
    }

    if (tool_name != null and tool_args != null) {
        const calls = try allocator.alloc(types.ToolCall, 1);
        calls[0] = .{
            .id = try allocator.dupe(u8, "call_0"),
            .tool = try allocator.dupe(u8, tool_name.?),
            .args = try allocator.dupe(u8, tool_args.?),
        };
        return .{
            .text = try allocator.dupe(u8, ""),
            .reasoning = try allocator.dupe(u8, ""),
            .tool_calls = calls,
            .finish_reason = try allocator.dupe(u8, "tool_calls"),
        };
    }

    if (out_text.items.len == 0) {
        if (root_parsed.value.object.get("output_text")) |ot| {
            if (ot == .string) try out_text.appendSlice(allocator, ot.string);
        }
    }

    return .{
        .text = try allocator.dupe(u8, out_text.items),
        .reasoning = try allocator.dupe(u8, ""),
        .tool_calls = try allocator.alloc(types.ToolCall, 0),
        .finish_reason = try allocator.dupe(u8, "stop"),
    };
}

pub fn parseChatResponse(allocator: std.mem.Allocator, raw: []const u8) !types.ChatResponse {
    errors.clearLastProviderError();

    // Chat Completions should always return JSON. If we get plain text (common for 401/403 from some
    // upstreams), surface it as a provider error instead of a JSON parse error.
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] != '{' and trimmed[0] != '[') {
        const cap = @min(trimmed.len, 300);
        errors.setLastProviderError(trimmed[0..cap]);
        return errors.ProviderError.ModelProviderError;
    }

    // Try to parse and extract error information
    if (std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true })) |root_parsed| {
        defer root_parsed.deinit();
        if (root_parsed.value == .object) {
            if (root_parsed.value.object.get("error")) |err_val| {
                if (err_val == .object) {
                    try extractAndSetError(err_val.object);
                    return errors.ProviderError.ModelProviderError;
                }
            }
        }
    } else |_| {}

    // Try structured error envelope
    if (std.json.parseFromSlice(types.ErrorEnvelope, allocator, raw, .{ .ignore_unknown_fields = true })) |maybe_err| {
        defer maybe_err.deinit();
        if (maybe_err.value.@"error") |api_err| {
            try extractAndSetErrorFromEnvelope(api_err);
            return errors.ProviderError.ModelProviderError;
        }
    } else |_| {}

    var parsed = std.json.parseFromSlice(types.ChatResponseRaw, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Model response parse error: {s}; raw prefix: {s}", .{ @errorName(err), prefix });
        return errors.ProviderError.ModelResponseParseError;
    };
    defer parsed.deinit();

    const choices = parsed.value.choices orelse {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Model response missing choices; raw prefix: {s}", .{prefix});
        errors.setLastProviderError("response missing choices");
        return errors.ProviderError.ModelResponseMissingChoices;
    };
    if (choices.len == 0) {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Model response has empty choices; raw prefix: {s}", .{prefix});
        errors.setLastProviderError("response has empty choices");
        return errors.ProviderError.ModelResponseMissingChoices;
    }

    const message = choices[0].message;
    const finish_reason = choices[0].finish_reason orelse "";
    const reasoning = message.reasoning_content orelse message.thinking orelse "";

    var tool_calls = std.ArrayListUnmanaged(types.ToolCall).empty;
    errdefer {
        for (tool_calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.tool);
            allocator.free(tc.args);
        }
        tool_calls.deinit(allocator);
    }

    if (message.tool_calls) |calls| {
        for (calls) |tc| {
            const args_json = switch (tc.function.arguments) {
                .string => |s| try allocator.dupe(u8, s),
                else => try std.fmt.allocPrint(allocator, "{}", .{tc.function.arguments}),
            };
            try tool_calls.append(allocator, .{
                .id = try allocator.dupe(u8, tc.id),
                .tool = try allocator.dupe(u8, tc.function.name),
                .args = args_json,
            });
        }
    }

    return .{
        .text = try allocator.dupe(u8, message.content orelse ""),
        .reasoning = try allocator.dupe(u8, reasoning),
        .tool_calls = try tool_calls.toOwnedSlice(allocator),
        .finish_reason = try allocator.dupe(u8, finish_reason),
    };
}

fn extractAndSetError(err_obj: std.json.ObjectMap) !void {
    var buf: [320]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    if (err_obj.get("metadata")) |meta| {
        if (meta == .object) {
            if (meta.object.get("provider_name")) |pname| {
                if (pname == .string) {
                    try w.print("provider={s}", .{pname.string});
                }
            }
        }
    }
    if (err_obj.get("code")) |code| {
        if (fbs.pos > 0) try w.writeAll(" ");
        switch (code) {
            .string => |s| try w.print("code={s}", .{s}),
            .integer => |n| try w.print("code={d}", .{n}),
            .float => |n| try w.print("code={d}", .{n}),
            else => try w.print("code={s}", .{@tagName(code)}),
        }
    }
    if (err_obj.get("message")) |msg| {
        if (msg == .string) {
            if (fbs.pos > 0) try w.writeAll(" ");
            try w.print("message={s}", .{msg.string});
        }
    } else if (err_obj.get("type")) |kind| {
        if (kind == .string) {
            if (fbs.pos > 0) try w.writeAll(" ");
            try w.print("type={s}", .{kind.string});
        }
    }

    if (fbs.pos > 0) {
        const detail = fbs.getWritten();
        logger.err("Upstream model error: {s}", .{detail});
        errors.setLastProviderError(detail);
    } else {
        logger.err("Upstream model error object present with no details", .{});
        errors.setLastProviderError("provider returned an error object with no message");
    }
}

fn extractAndSetErrorFromEnvelope(api_err: anytype) !void {
    var buf: [320]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    if (api_err.metadata) |m| {
        if (m.provider_name) |pname| {
            try w.print("provider={s}", .{pname});
        }
    }
    if (api_err.code) |code| {
        if (fbs.pos > 0) try w.writeAll(" ");
        switch (code) {
            .string => |s| try w.print("code={s}", .{s}),
            .integer => |n| try w.print("code={d}", .{n}),
            .float => |n| try w.print("code={d}", .{n}),
        }
    }
    if (api_err.message) |msg| {
        if (fbs.pos > 0) try w.writeAll(" ");
        try w.print("message={s}", .{msg});
    } else if (api_err.type) |kind| {
        if (fbs.pos > 0) try w.writeAll(" ");
        try w.print("type={s}", .{kind});
    }

    if (fbs.pos > 0) {
        const detail = fbs.getWritten();
        logger.err("Upstream model error: {s}", .{detail});
        errors.setLastProviderError(detail);
    } else {
        logger.err("Upstream model error object present with no details", .{});
        errors.setLastProviderError("provider returned an error object with no message");
    }
}
