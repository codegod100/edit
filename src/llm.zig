const std = @import("std");
const logger = @import("logger.zig");

pub const QueryError = error{
    MissingApiKey,
    UnsupportedProvider,
    EmptyModelResponse,
};

pub const ToolRouteDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const ToolRouteCall = struct {
    tool: []u8,
    arguments_json: []u8,

    pub fn deinit(self: ToolRouteCall, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
        allocator.free(self.arguments_json);
    }
};

const OPENAI_API_ENDPOINT = "https://api.openai.com/v1/responses";
const OPENAI_CODEX_ENDPOINT = "https://chatgpt.com/backend-api/codex/responses";

const OpenAIResponseMeta = struct {
    id: ?[]const u8,
    status: ?[]const u8,
};

fn parseOpenAIResponseMeta(allocator: std.mem.Allocator, json: []const u8) !OpenAIResponseMeta {
    const Meta = struct {
        id: ?[]const u8 = null,
        status: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(Meta, allocator, json, .{ .ignore_unknown_fields = true }) catch {
        return .{ .id = null, .status = null };
    };
    defer parsed.deinit();
    return .{
        .id = if (parsed.value.id) |id| try allocator.dupe(u8, id) else null,
        .status = if (parsed.value.status) |status| try allocator.dupe(u8, status) else null,
    };
}

pub fn query(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api_key: ?[]const u8,
    model_id: []const u8,
    prompt: []const u8,
) ![]u8 {
    const key = api_key orelse {
        logger.err("API key missing for provider: {s}", .{provider_id});
        return QueryError.MissingApiKey;
    };

    logger.logModelRequest(provider_id, model_id, prompt.len, false);

    const start_time = std.time.milliTimestamp();
    const result = if (std.mem.eql(u8, provider_id, "openai"))
        queryOpenAI(allocator, key, model_id, prompt)
    else if (std.mem.eql(u8, provider_id, "anthropic"))
        queryAnthropic(allocator, key, model_id, prompt)
    else if (std.mem.eql(u8, provider_id, "opencode"))
        queryOpenCodeZen(allocator, key, model_id, prompt)
    else
        error.UnsupportedProvider;

    return result catch |err| {
        _ = start_time;
        logger.logApiError(provider_id, "query", null, null, err);
        return err;
    };
}

fn queryOpenAI(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, prompt: []const u8) ![]u8 {
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth);

    const endpoint = if (isLikelyOAuthToken(api_key)) OPENAI_CODEX_ENDPOINT else OPENAI_API_ENDPOINT;
    const is_codex = std.mem.eql(u8, endpoint, OPENAI_CODEX_ENDPOINT);
    const body = try buildOpenAIRequestBody(allocator, model_id, prompt, is_codex);
    defer allocator.free(body);

    const output = try runCommandCapture(allocator, &.{
        "curl",
        "-sS",
        "-X",
        "POST",
        endpoint,
        "-H",
        "Content-Type: application/json",
        "-H",
        auth,
        "-H",
        "originator: zagent",
        "-d",
        body,
    });
    defer allocator.free(output);

    const first = try extractOpenAIText(allocator, output);
    if (first.len > 0) return first;
    defer allocator.free(first);

    const stream_text = try extractOpenAIStreamText(allocator, output);
    if (stream_text.len > 0) return stream_text;
    defer allocator.free(stream_text);

    if (std.mem.eql(u8, endpoint, OPENAI_API_ENDPOINT)) {
        const meta = try parseOpenAIResponseMeta(allocator, output);
        defer {
            if (meta.id) |id| allocator.free(id);
            if (meta.status) |status| allocator.free(status);
        }
        if (meta.id != null and meta.status != null and std.mem.eql(u8, meta.status.?, "in_progress")) {
            const follow_url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ OPENAI_API_ENDPOINT, meta.id.? });
            defer allocator.free(follow_url);

            var attempt: usize = 0;
            while (attempt < 15) : (attempt += 1) {
                std.Thread.sleep(400 * std.time.ns_per_ms);
                const polled = try runCommandCapture(allocator, &.{
                    "curl",
                    "-sS",
                    "-X",
                    "GET",
                    follow_url,
                    "-H",
                    auth,
                    "-H",
                    "originator: zagent",
                });
                defer allocator.free(polled);

                const parsed = try extractOpenAIText(allocator, polled);
                if (parsed.len > 0 and !std.mem.startsWith(u8, parsed, "Could not extract") and !std.mem.startsWith(u8, parsed, "JSON parse error") and !std.mem.startsWith(u8, parsed, "Wrapper parse error")) {
                    return parsed;
                }
                defer allocator.free(parsed);

                const step = try parseOpenAIResponseMeta(allocator, polled);
                defer {
                    if (step.id) |id| allocator.free(id);
                    if (step.status) |status| allocator.free(status);
                }
                if (step.status == null or !std.mem.eql(u8, step.status.?, "in_progress")) break;
            }
        }
    }

    if (output.len > 0) {
        const cap = @min(output.len, 1000);
        return std.fmt.allocPrint(allocator, "No text found in model response: {s}", .{output[0..cap]});
    }
    return std.fmt.allocPrint(allocator, "Empty response from API (0 bytes)", .{});
}

pub fn inferToolCall(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api_key: ?[]const u8,
    model_id: []const u8,
    prompt: []const u8,
    defs: []const ToolRouteDef,
    force_tool: bool,
) !?ToolRouteCall {
    if (!std.mem.eql(u8, provider_id, "openai")) return null;
    const key = api_key orelse return QueryError.MissingApiKey;

    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{key});
    defer allocator.free(auth);

    const endpoint = if (isLikelyOAuthToken(key)) OPENAI_CODEX_ENDPOINT else OPENAI_API_ENDPOINT;
    const stream = std.mem.eql(u8, endpoint, OPENAI_CODEX_ENDPOINT);
    const body = try buildOpenAIToolRouteBody(allocator, model_id, prompt, defs, stream, force_tool);
    defer allocator.free(body);

    const output = try runCommandCapture(allocator, &.{
        "curl",               "-sS",                            "-X", "POST", endpoint,
        "-H",                 "Content-Type: application/json", "-H", auth,   "-H",
        "originator: zagent", "-d",                             body,
    });
    defer allocator.free(output);

    return parseOpenAIFunctionCall(allocator, output);
}

fn buildOpenAIToolRouteBody(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    prompt: []const u8,
    defs: []const ToolRouteDef,
    stream: bool,
    force_tool: bool,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("{{\"model\":\"{s}\",\"instructions\":\"You are a tool router. If a local tool should be used, emit a function call. Otherwise answer normally.\",\"input\":[{{\"role\":\"user\",\"content\":[{{\"type\":\"input_text\",\"text\":\"{s}\"}}]}}],\"tools\":[", .{ model_id, prompt });
    for (defs, 0..) |d, i| {
        if (i > 0) try w.print(",", .{});
        try w.print("{{\"type\":\"function\",\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s},\"strict\":true}}", .{ d.name, d.description, d.parameters_json });
    }
    try w.print("],\"tool_choice\":\"{s}\",\"store\":false,\"stream\":{s}}}", .{ if (force_tool) "required" else "auto", if (stream) "true" else "false" });
    return out.toOwnedSlice(allocator);
}

pub fn parseOpenAIFunctionCall(allocator: std.mem.Allocator, raw: []const u8) !?ToolRouteCall {
    const OutputItem = struct {
        type: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    };
    const Resp = struct { output: ?[]const OutputItem = null };

    if (std.json.parseFromSlice(Resp, allocator, raw, .{ .ignore_unknown_fields = true })) |parsed| {
        defer parsed.deinit();
        if (parsed.value.output) |items| {
            for (items) |item| {
                if (item.type != null and std.mem.eql(u8, item.type.?, "function_call") and item.name != null and item.arguments != null) {
                    return .{
                        .tool = try allocator.dupe(u8, item.name.?),
                        .arguments_json = try allocator.dupe(u8, item.arguments.?),
                    };
                }
            }
        }
    } else |_| {}

    var current_name: ?[]u8 = null;
    defer if (current_name) |n| allocator.free(n);
    var args = std.ArrayList(u8).empty;
    defer args.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line[5..], " \t");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;

        const SSEEvent = struct {
            type: ?[]const u8 = null,
            delta: ?[]const u8 = null,
            item: ?OutputItem = null,
        };
        var ev = std.json.parseFromSlice(SSEEvent, allocator, payload, .{ .ignore_unknown_fields = true }) catch continue;
        defer ev.deinit();

        if (ev.value.item) |item| {
            if (item.type != null and std.mem.eql(u8, item.type.?, "function_call")) {
                if (current_name) |n| allocator.free(n);
                current_name = if (item.name) |n| try allocator.dupe(u8, n) else null;
                if (item.arguments) |a| try args.appendSlice(allocator, a);
            }
        }
        if (ev.value.type) |t| {
            if (std.mem.endsWith(u8, t, "function_call_arguments.delta")) {
                if (ev.value.delta) |d| try args.appendSlice(allocator, d);
            }
        }
    }

    if (current_name != null and args.items.len > 0) {
        return .{
            .tool = try allocator.dupe(u8, current_name.?),
            .arguments_json = try allocator.dupe(u8, args.items),
        };
    }
    return null;
}

fn buildOpenAIRequestBody(allocator: std.mem.Allocator, model_id: []const u8, prompt: []const u8, stream: bool) ![]u8 {
    const InputText = struct {
        type: []const u8,
        text: []const u8,
    };
    const InputMessage = struct {
        role: []const u8,
        content: []const InputText,
    };

    const content = [_]InputText{.{ .type = "input_text", .text = prompt }};
    const input = [_]InputMessage{.{ .role = "user", .content = content[0..] }};

    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(.{
            .model = model_id,
            .instructions = "You are a helpful coding assistant.",
            .input = input[0..],
            .store = false,
            .stream = stream,
        }, .{})},
    );
}

fn extractOpenAIStreamText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line[5..], " \t");
        if (payload.len == 0) continue;
        if (std.mem.eql(u8, payload, "[DONE]")) continue;

        const Event = struct {
            type: ?[]const u8 = null,
            delta: ?[]const u8 = null,
            text: ?[]const u8 = null,
            output_text: ?[]const u8 = null,
        };

        var event = std.json.parseFromSlice(Event, allocator, payload, .{ .ignore_unknown_fields = true }) catch continue;
        defer event.deinit();

        if (event.value.type) |event_type| {
            if (!std.mem.endsWith(u8, event_type, ".delta")) continue;
        }

        const piece = event.value.delta orelse event.value.text orelse event.value.output_text orelse continue;
        try out.appendSlice(allocator, piece);
    }

    if (out.items.len == 0) {
        const preview_len = @min(raw.len, 800);
        return std.fmt.allocPrint(allocator, "No text in stream response ({d} bytes):\n{s}", .{ raw.len, raw[0..preview_len] });
    }
    return out.toOwnedSlice(allocator);
}

fn isLikelyOAuthToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "sk-")) return false;
    return std.mem.count(u8, token, ".") >= 2;
}

fn queryAnthropic(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, prompt: []const u8) ![]u8 {
    const Message = struct { role: []const u8, content: []const u8 };
    const messages = [_]Message{.{ .role = "user", .content = prompt }};

    const body = try std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(.{
            .model = model_id,
            .max_tokens = 1024,
            .messages = messages[0..],
        }, .{})},
    );
    defer allocator.free(body);

    const key_header = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
    defer allocator.free(key_header);

    const output = try runCommandCapture(allocator, &.{
        "curl",
        "-sS",
        "-X",
        "POST",
        "https://api.anthropic.com/v1/messages",
        "-H",
        "Content-Type: application/json",
        "-H",
        "anthropic-version: 2023-06-01",
        "-H",
        key_header,
        "-d",
        body,
    });
    defer allocator.free(output);

    return extractAnthropicText(allocator, output);
}

fn queryOpenCodeZen(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, prompt: []const u8) ![]u8 {
    const auth = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{api_key});
    defer allocator.free(auth);

    const Message = struct { role: []const u8, content: []const u8 };
    const messages = [_]Message{.{ .role = "user", .content = prompt }};

    const body = try std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(.{
            .model = model_id,
            .messages = messages[0..],
        }, .{})},
    );
    defer allocator.free(body);

    const output = try runCommandCapture(allocator, &.{
        "curl",
        "-sS",
        "-X",
        "POST",
        "https://opencode.ai/zen/v1/chat/completions",
        "-H",
        "Content-Type: application/json",
        "-H",
        auth,
        "-d",
        body,
    });
    defer allocator.free(output);

    return extractOpenAIText(allocator, output);
}

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 2 * 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    return result.stdout;
}

fn extractOpenAIText(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const OutputContent = struct { text: ?[]const u8 = null };
    const OutputItem = struct {
        text: ?[]const u8 = null,
        content: ?[]const OutputContent = null,
    };
    const Msg = struct { content: ?[]const u8 = null };
    const Choice = struct { message: Msg };
    const ApiError = struct { message: ?[]const u8 = null };
    const Resp = struct {
        output_text: ?[]const u8 = null,
        output: ?[]const OutputItem = null,
        choices: ?[]const Choice = null,
        @"error": ?ApiError = null,
    };

    const Wrapper = struct {
        response: ?Resp = null,
        result: ?Resp = null,
        data: ?Resp = null,
    };

    var parsed = std.json.parseFromSlice(Resp, allocator, json, .{ .ignore_unknown_fields = true }) catch |parse_err| {
        const preview_len = @min(json.len, 800);
        return std.fmt.allocPrint(allocator, "JSON parse error ({s}) for response ({d} bytes):\n{s}", .{ @errorName(parse_err), json.len, json[0..preview_len] });
    };
    defer parsed.deinit();

    if (try extractFromResp(allocator, parsed.value)) |text| return text;

    var wrapped = std.json.parseFromSlice(Wrapper, allocator, json, .{ .ignore_unknown_fields = true }) catch |wrap_err| {
        const preview_len = @min(json.len, 800);
        return std.fmt.allocPrint(allocator, "Wrapper parse error ({s}) for response ({d} bytes):\n{s}", .{ @errorName(wrap_err), json.len, json[0..preview_len] });
    };
    defer wrapped.deinit();

    if (wrapped.value.response) |r| {
        if (try extractFromResp(allocator, r)) |text| return text;
    }
    if (wrapped.value.result) |r| {
        if (try extractFromResp(allocator, r)) |text| return text;
    }
    if (wrapped.value.data) |r| {
        if (try extractFromResp(allocator, r)) |text| return text;
    }

    // Return the raw API response as the error message so users can see what went wrong
    const preview_len = @min(json.len, 800);
    return std.fmt.allocPrint(allocator, "Could not extract text from API response ({d} bytes):\n{s}", .{ json.len, json[0..preview_len] });
}

fn extractFromResp(allocator: std.mem.Allocator, resp: anytype) !?[]u8 {
    if (resp.output_text) |text| {
        if (text.len > 0) return try allocator.dupe(u8, text);
    }
    if (resp.output) |items| {
        for (items) |item| {
            if (item.text) |text| {
                if (text.len > 0) return try allocator.dupe(u8, text);
            }
            if (item.content) |parts| {
                for (parts) |part| {
                    if (part.text) |text| {
                        if (text.len > 0) return try allocator.dupe(u8, text);
                    }
                }
            }
        }
    }
    if (resp.choices) |choices| {
        if (choices.len > 0) {
            if (choices[0].message.content) |text| {
                if (text.len > 0) return try allocator.dupe(u8, text);
            }
        }
    }

    if (resp.@"error") |err| {
        if (err.message) |msg| {
            if (msg.len > 0) return try std.fmt.allocPrint(allocator, "API error: {s}", .{msg});
        }
    }

    return null;
}

fn extractAnthropicText(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const Content = struct { text: ?[]const u8 = null };
    const Resp = struct { content: ?[]const Content = null };

    var parsed = std.json.parseFromSlice(Resp, allocator, json, .{ .ignore_unknown_fields = true }) catch {
        return allocator.dupe(u8, json);
    };
    defer parsed.deinit();

    if (parsed.value.content) |content| {
        for (content) |part| {
            if (part.text) |text| {
                if (text.len > 0) return allocator.dupe(u8, text);
            }
        }
    }
    const preview_len = @min(json.len, 800);
    return std.fmt.allocPrint(allocator, "No text in Anthropic response ({d} bytes):\n{s}", .{ json.len, json[0..preview_len] });
}

test "extract openai output_text" {
    const allocator = std.testing.allocator;
    const out = try extractOpenAIText(allocator, "{\"output_text\":\"hello\"}");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "extract anthropic text" {
    const allocator = std.testing.allocator;
    const out = try extractAnthropicText(allocator, "{\"content\":[{\"text\":\"hi there\"}]}");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hi there", out);
}

test "extract openai nested output content" {
    const allocator = std.testing.allocator;
    const out = try extractOpenAIText(allocator, "{\"output\":[{\"content\":[{\"text\":\"nested hello\"}]}]}");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("nested hello", out);
}

test "extract openai error message" {
    const allocator = std.testing.allocator;
    const out = try extractOpenAIText(allocator, "{\"error\":{\"message\":\"invalid api key\"}}");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("API error: invalid api key", out);
}

test "oauth token detector" {
    try std.testing.expect(!isLikelyOAuthToken("sk-test-key"));
    try std.testing.expect(isLikelyOAuthToken("a.b.c"));
}

test "codex body includes instructions" {
    const allocator = std.testing.allocator;
    const body = try buildOpenAIRequestBody(allocator, "gpt-5.3-codex", "hello", true);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "instructions") != null);
}

test "openai body sends input as list" {
    const allocator = std.testing.allocator;
    const body = try buildOpenAIRequestBody(allocator, "gpt-5.3-codex", "hello", true);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[") != null);
}

test "openai body sets store false" {
    const allocator = std.testing.allocator;
    const body = try buildOpenAIRequestBody(allocator, "gpt-5.3-codex", "hello", true);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
}

test "openai body sets stream true for codex" {
    const allocator = std.testing.allocator;
    const body = try buildOpenAIRequestBody(allocator, "gpt-5.3-codex", "hello", true);
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
}

test "extract stream text from sse data lines" {
    const allocator = std.testing.allocator;
    const raw = "data: {\"delta\":\"hello \"}\n\ndata: {\"delta\":\"world\"}\n\ndata: [DONE]\n";
    const out = try extractOpenAIStreamText(allocator, raw);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "parse function call from json output" {
    const allocator = std.testing.allocator;
    const raw = "{\"output\":[{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"input\\\":\\\"ls\\\"}\"}]}";
    const call = try parseOpenAIFunctionCall(allocator, raw);
    try std.testing.expect(call != null);
    defer {
        var c = call.?;
        c.deinit(allocator);
    }
    try std.testing.expectEqualStrings("bash", call.?.tool);
    try std.testing.expect(std.mem.indexOf(u8, call.?.arguments_json, "\"input\":\"ls\"") != null);
}

test "parse function call from sse deltas" {
    const allocator = std.testing.allocator;
    const raw =
        "data: {\"item\":{\"type\":\"function_call\",\"name\":\"read\",\"arguments\":\"{\\\"input\\\":\\\"src/\"}}\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"main.zig\\\"}\"}\n";
    const call = try parseOpenAIFunctionCall(allocator, raw);
    try std.testing.expect(call != null);
    defer {
        var c = call.?;
        c.deinit(allocator);
    }
    try std.testing.expectEqualStrings("read", call.?.tool);
    try std.testing.expect(std.mem.indexOf(u8, call.?.arguments_json, "src/main.zig") != null);
}

test "extract stream text from event plus data lines" {
    const allocator = std.testing.allocator;
    const raw =
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n" ++
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"!\"}\n\n" ++
        "data: [DONE]\n";
    const out = try extractOpenAIStreamText(allocator, raw);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Hi!", out);
}

test "stream parser ignores done payload to avoid duplicate text" {
    const allocator = std.testing.allocator;
    const raw =
        "event: response.output_text.delta\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hi\"}\n\n" ++
        "event: response.output_text.done\n" ++
        "data: {\"type\":\"response.output_text.done\",\"text\":\"Hi\"}\n\n" ++
        "data: [DONE]\n";
    const out = try extractOpenAIStreamText(allocator, raw);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("Hi", out);
}

test "non-json response returns formatted error" {
    const allocator = std.testing.allocator;
    const out = try extractOpenAIText(allocator, "event: x\ndata: y");
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "JSON parse error"));
}

test "extract openai wrapped response object" {
    const allocator = std.testing.allocator;
    const out = try extractOpenAIText(allocator, "{\"response\":{\"output_text\":\"wrapped\"}}");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("wrapped", out);
}

test "parse openai response meta" {
    const allocator = std.testing.allocator;
    const meta = try parseOpenAIResponseMeta(allocator, "{\"id\":\"resp_123\",\"status\":\"in_progress\"}");
    defer {
        if (meta.id) |id| allocator.free(id);
        if (meta.status) |status| allocator.free(status);
    }
    try std.testing.expect(meta.id != null);
    try std.testing.expect(meta.status != null);
    try std.testing.expectEqualStrings("resp_123", meta.id.?);
    try std.testing.expectEqualStrings("in_progress", meta.status.?);
}
