const std = @import("std");
const logger = @import("logger.zig");

pub const ToolCall = struct {
    id: []const u8,
    tool: []const u8,
    args: []const u8,
};

pub const ChatResponse = struct {
    text: []const u8,
    reasoning: []const u8 = "",
    tool_calls: []ToolCall,
    finish_reason: []const u8,
};

const ProviderConfig = struct {
    endpoint: []const u8,
    referer: ?[]const u8,
    title: ?[]const u8,
    user_agent: ?[]const u8,
};

const ToolCallIn = struct {
    id: []const u8,
    type: []const u8,
    function: struct {
        name: []const u8,
        arguments: std.json.Value,
    },
};

const MessageIn = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCallIn = null,
    tool_call_id: ?[]const u8 = null,
};

const ResponseChoice = struct {
    message: struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
        tool_calls: ?[]ToolCallIn = null,
    },
    finish_reason: ?[]const u8 = null,
};

const ChatResponseRaw = struct {
    choices: ?[]ResponseChoice = null,
};

pub fn chatDirect(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    provider_id: []const u8,
    messages_json: []const u8,
    reasoning_effort: ?[]const u8,
) !ChatResponse {
    const config = getProviderConfig(provider_id);
    const body = try buildChatBody(allocator, model_id, messages_json, reasoning_effort);
    defer allocator.free(body);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    if (config.user_agent) |ua| headers.user_agent = .{ .override = ua };

    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(allocator);
    if (config.referer) |r| try extra_headers.append(allocator, .{ .name = "HTTP-Referer", .value = r });
    if (config.title) |t| try extra_headers.append(allocator, .{ .name = "X-Title", .value = t });

    const raw = try httpRequest(
        allocator,
        .POST,
        config.endpoint,
        headers,
        extra_headers.items,
        body,
    );
    defer allocator.free(raw);

    return parseChatResponse(allocator, raw);
}

fn parseChatResponse(allocator: std.mem.Allocator, raw: []const u8) !ChatResponse {
    var parsed = std.json.parseFromSlice(ChatResponseRaw, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        logger.err("Bridge parse error: {s}", .{@errorName(err)});
        return error.BridgeError;
    };
    defer parsed.deinit();

    const choices = parsed.value.choices orelse return error.BridgeError;
    if (choices.len == 0) return error.BridgeError;

    const message = choices[0].message;
    const finish_reason = choices[0].finish_reason orelse "";
    const reasoning = message.reasoning_content orelse message.thinking orelse "";

    var tool_calls = std.ArrayListUnmanaged(ToolCall).empty;
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

fn buildChatBody(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    messages_json: []const u8,
    reasoning_effort: ?[]const u8,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("{{\"model\":{f},\"messages\":{s}", .{ std.json.fmt(model_id, .{}), messages_json });
    try w.writeAll(",\"tools\":[");
    try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"Execute a shell command and return stdout.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read a file and return its contents.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"file_path\":{\"type\":\"string\"},\"file_name\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}}}}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"description\":\"Write content to a file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"file_path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"content\"]}}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"replace_in_file\",\"description\":\"Replace text in a file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"file_path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"old\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"},\"new\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\"}}}}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"todo_list\",\"description\":\"List todos.\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}");
    try w.writeAll("]");
    if (reasoning_effort) |effort| {
        try w.print(",\"reasoning_effort\":{f}", .{std.json.fmt(effort, .{})});
    }
    try w.writeAll("}");

    return out.toOwnedSlice(allocator);
}

fn getProviderConfig(provider_id: []const u8) ProviderConfig {
    if (std.mem.eql(u8, provider_id, "openai")) {
        return .{
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .referer = null,
            .title = null,
            .user_agent = null,
        };
    } else if (std.mem.eql(u8, provider_id, "opencode")) {
        return .{
            .endpoint = "https://opencode.ai/zen/v1/chat/completions",
            .referer = "https://opencode.ai/",
            .title = "opencode",
            .user_agent = "opencode/0.1.0 (linux; x86_64)",
        };
    } else if (std.mem.eql(u8, provider_id, "openrouter")) {
        return .{
            .endpoint = "https://openrouter.ai/api/v1/chat/completions",
            .referer = "https://zagent.local/",
            .title = "zagent",
            .user_agent = null,
        };
    } else {
        return .{
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .referer = null,
            .title = null,
            .user_agent = null,
        };
    }
}

fn httpRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var writer = out.writer(allocator);
    var writer_adapter = writer.adaptToNewApi(&.{});

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .headers = headers,
        .extra_headers = extra_headers,
        .payload = payload,
        .response_writer = &writer_adapter.new_interface,
    });

    return out.toOwnedSlice(allocator);
}
