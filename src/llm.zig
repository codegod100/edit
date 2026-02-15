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
    tool_defs: ?[]const ToolRouteDef,
) ![]u8 {
    // Auto-use "public" key for opencode free tier models
    const is_opencode_free = std.mem.eql(u8, provider_id, "opencode") and
        std.mem.indexOf(u8, model_id, "free") != null;

    const key = if (is_opencode_free)
        // For opencode free models, use "public" if no real key provided
        api_key orelse "public"
    else
        api_key orelse {
            logger.err("API key missing for provider: {s}", .{provider_id});
            return QueryError.MissingApiKey;
        };

    logger.logModelRequest(provider_id, model_id, prompt.len, tool_defs != null and tool_defs.?.len > 0);

    const start_time = std.time.milliTimestamp();
    const result = if (std.mem.eql(u8, provider_id, "anthropic"))
        queryAnthropic(allocator, key, model_id, prompt, tool_defs)
    else
        // All other providers use OpenAI-compatible API
        queryOpenAICompatible(allocator, key, model_id, prompt, tool_defs, provider_id);

    return result catch |err| {
        _ = start_time;
        logger.logApiError(provider_id, "query", null, null, err);
        return err;
    };
}

fn queryOpenAI(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, prompt: []const u8, _tool_defs: ?[]const ToolRouteDef) ![]u8 {
    _ = _tool_defs;
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    const endpoint = if (isLikelyOAuthToken(api_key)) OPENAI_CODEX_ENDPOINT else OPENAI_API_ENDPOINT;
    const is_codex = std.mem.eql(u8, endpoint, OPENAI_CODEX_ENDPOINT);
    const body = try buildOpenAIRequestBody(allocator, model_id, prompt, is_codex);
    defer allocator.free(body);

    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    const output = try httpRequest(
        allocator,
        .POST,
        endpoint,
        headers,
        &.{.{ .name = "originator", .value = "zagent" }},
        body,
    );
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
                const polled = try httpRequest(
                    allocator,
                    .GET,
                    follow_url,
                    headers,
                    &.{.{ .name = "originator", .value = "zagent" }},
                    null,
                );
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

pub const ToolRouteResult = struct {
    call: ToolRouteCall,
    thinking: ?[]const u8,
};

pub fn inferToolCallWithThinking(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api_key: ?[]const u8,
    model_id: []const u8,
    prompt: []const u8,
    defs: []const ToolRouteDef,
    force_tool: bool,
) !?ToolRouteResult {
    if (!std.mem.eql(u8, provider_id, "openai")) return null;
    const key = api_key orelse return QueryError.MissingApiKey;

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
    defer allocator.free(auth_value);

    const endpoint = if (isLikelyOAuthToken(key)) OPENAI_CODEX_ENDPOINT else OPENAI_API_ENDPOINT;
    const stream = std.mem.eql(u8, endpoint, OPENAI_CODEX_ENDPOINT);
    const body = try buildOpenAIToolRouteBody(allocator, model_id, prompt, defs, stream, force_tool);
    defer allocator.free(body);

    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    const output = try httpRequest(
        allocator,
        .POST,
        endpoint,
        headers,
        &.{.{ .name = "originator", .value = "zagent" }},
        body,
    );
    defer allocator.free(output);

    // Parse both the function call and any thinking content
    const call = try parseOpenAIFunctionCall(allocator, output);
    if (call == null) return null;

    // Try to extract thinking/reasoning from the response
    const thinking = try extractThinkingFromResponse(allocator, output);

    return .{
        .call = call.?,
        .thinking = thinking,
    };
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
    const result = try inferToolCallWithThinking(allocator, provider_id, api_key, model_id, prompt, defs, force_tool);
    if (result) |r| {
        if (r.thinking) |t| allocator.free(t);
        return r.call;
    }
    return null;
}

fn extractThinkingFromResponse(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    // Parse JSON to find thinking/reasoning fields
    const Resp = struct {
        reasoning: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
        thought: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
    };

    if (std.json.parseFromSlice(Resp, allocator, raw, .{ .ignore_unknown_fields = true })) |parsed| {
        defer parsed.deinit();
        const r = parsed.value;
        const thinking = r.reasoning orelse r.thinking orelse r.thought orelse r.reasoning_content;
        if (thinking) |t| {
            return try allocator.dupe(u8, t);
        }
    } else |_| {}

    return null;
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

    const system_prompt =
        "You are zagent, an AI coding assistant. Follow this exact workflow:\\n\\n" ++
        "STEP 1 - UNDERSTAND:\\n" ++
        "Say: 'Task: [what user wants]'\\n" ++
        "Say: 'Plan: [your approach]'\\n\\n" ++
        "STEP 2 - EXECUTE:\\n" ++
        "TOOL_CALL [tool] {args}\\n\\n" ++
        "STEP 3 - LEARN:\\n" ++
        "Say: 'Found: [key insight from result]'\\n\\n" ++
        "STEP 4 - NEXT:\\n" ++
        "Next tool or DONE\\n\\n" ++
        "SMART RULES:\\n" ++
        "- Never list same directory twice\\n" ++
        "- Use read_file, not list_files, to understand code\\n" ++
        "- Use offset/limit for big files (read_file {path, limit:100})\\n" ++
        "- paths are relative to cwd, not absolute\\n\\n" ++
        "Multiple TOOL_CALLs allowed per response.\\n";

    return std.fmt.allocPrint(
        allocator,
        "{f}",
        .{std.json.fmt(.{
            .model = model_id,
            .instructions = system_prompt,
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

fn queryAnthropic(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, prompt: []const u8, _tool_defs: ?[]const ToolRouteDef) ![]u8 {
    _ = _tool_defs;
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

    const headers = std.http.Client.Request.Headers{
        .content_type = .{ .override = "application/json" },
        .user_agent = .{ .override = "zagent/0.1" },
    };
    const output = try httpRequest(
        allocator,
        .POST,
        "https://api.anthropic.com/v1/messages",
        headers,
        &.{
            .{ .name = "anthropic-version", .value = "2023-06-01" },
            .{ .name = "x-api-key", .value = api_key },
        },
        body,
    );
    defer allocator.free(output);

    return extractAnthropicText(allocator, output);
}

const ProviderConfig = struct {
    endpoint: []const u8,
    referer: ?[]const u8,
    title: ?[]const u8,
    user_agent: ?[]const u8,
};

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
    } else if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return .{
            .endpoint = "https://api.githubcopilot.com/chat/completions",
            .referer = null,
            .title = null,
            .user_agent = null,
        };
    } else {
        // Default to OpenAI format
        return .{
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .referer = null,
            .title = null,
            .user_agent = null,
        };
    }
}

fn queryOpenAICompatible(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, prompt: []const u8, tool_defs: ?[]const ToolRouteDef, provider_id: []const u8) ![]u8 {
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    const config = getProviderConfig(provider_id);

    const system_prompt =
        "STOP LISTING. USE GREP. " ++
        "1. bash {\"command\":\"rg -l 'keyword' src/\"} to find files. " ++
        "2. read_file {\"path\":\"src/file.zig\",\"offset\":0,\"limit\":400} to inspect in chunks. " ++
        "2b. For large files, bisect with multiple read_file calls (vary offset) instead of full reads. " ++
        "3. edit to change. " ++
        "4. bash {\"command\":\"zig build\"} to verify. " ++
        "5. DONE. " ++
        "Files are in src/. Never list more than once. Prefer grep-first then targeted bounded reads. One tool per response. " ++
        "If unclear what user wants, ASK: 'QUESTION: What do you mean by X?' instead of guessing.";

    const Message = struct { role: []const u8, content: []const u8 };
    const messages = [_]Message{
        .{ .role = "system", .content = system_prompt },
        .{ .role = "user", .content = prompt },
    };

    // Build tools array if provided
    var tools_json: ?[]u8 = null;
    defer if (tools_json) |tj| allocator.free(tj);

    if (tool_defs) |defs| {
        var tools_arr = std.ArrayList(u8).empty;
        defer tools_arr.deinit(allocator);

        try tools_arr.appendSlice(allocator, "[");
        for (defs, 0..) |def, i| {
            if (i > 0) try tools_arr.appendSlice(allocator, ",");
            try tools_arr.appendSlice(allocator, "{\"type\":\"function\",\"function\":{\"name\":\"");
            try tools_arr.appendSlice(allocator, def.name);
            try tools_arr.appendSlice(allocator, "\",\"description\":\"");
            try tools_arr.appendSlice(allocator, def.description);
            try tools_arr.appendSlice(allocator, "\",\"parameters\":");
            try tools_arr.appendSlice(allocator, def.parameters_json);
            try tools_arr.appendSlice(allocator, "}}");
        }
        try tools_arr.appendSlice(allocator, "]");
        tools_json = try tools_arr.toOwnedSlice(allocator);
    }

    var body: []u8 = undefined;
    if (tools_json) |tj| {
        var body_arr = std.ArrayList(u8).empty;
        defer body_arr.deinit(allocator);
        const w = body_arr.writer(allocator);

        try w.print("{{\"model\":\"{s}\",\"messages\":", .{model_id});
        try w.print("[{{\"role\":\"user\",\"content\":\"", .{});
        for (prompt) |ch| {
            switch (ch) {
                '\\' => try w.print("\\\\", .{}),
                '"' => try w.print("\\\"", .{}),
                '\n' => try w.print("\\n", .{}),
                '\r' => try w.print("\\r", .{}),
                '\t' => try w.print("\\t", .{}),
                0x08 => try w.print("\\b", .{}),
                0x0C => try w.print("\\f", .{}),
                else => {
                    if (ch < 0x20) {
                        try w.print("\\u{x:0>4}", .{ch});
                    } else {
                        try w.print("{c}", .{ch});
                    }
                },
            }
        }
        try w.print("\"}}],\"tools\":{s}}}", .{tj});
        body = try body_arr.toOwnedSlice(allocator);
    } else {
        body = try std.fmt.allocPrint(
            allocator,
            "{f}",
            .{std.json.fmt(.{
                .model = model_id,
                .messages = messages[0..],
            }, .{})},
        );
    }
    defer allocator.free(body);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    if (config.user_agent) |ua| {
        headers.user_agent = .{ .override = ua };
    }

    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(allocator);
    if (config.referer) |r| try extra_headers.append(allocator, .{ .name = "HTTP-Referer", .value = r });
    if (config.title) |t| try extra_headers.append(allocator, .{ .name = "X-Title", .value = t });

    const output = try httpRequest(
        allocator,
        .POST,
        config.endpoint,
        headers,
        extra_headers.items,
        body,
    );
    defer allocator.free(output);

    return extractOpenAIText(allocator, output);
}

// queryOpenRouter removed - now handled by queryOpenAICompatible

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

// Extract tool calls from OpenAI-compatible response and format as text commands
fn extractToolCallsAsText(allocator: std.mem.Allocator, json: []const u8) !?[]u8 {
    const FunctionDef = struct { name: []const u8, arguments: []const u8 };
    const ToolCall = struct { type: []const u8, function: FunctionDef };
    const Message = struct { content: ?[]const u8 = null, tool_calls: ?[]const ToolCall = null };
    const Choice = struct { message: Message, finish_reason: ?[]const u8 = null };
    const Resp = struct { choices: ?[]const Choice = null };

    var parsed = std.json.parseFromSlice(Resp, allocator, json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const choices = parsed.value.choices orelse return null;
    if (choices.len == 0) return null;

    const tool_calls = choices[0].message.tool_calls orelse return null;
    if (tool_calls.len == 0) return null;

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    for (tool_calls) |tc| {
        if (!std.mem.eql(u8, tc.type, "function")) continue;
        try result.writer(allocator).print("TOOL_CALL {s} {s}\n", .{ tc.function.name, tc.function.arguments });
    }

    if (result.items.len == 0) return null;
    const value = try result.toOwnedSlice(allocator);
    return @as(?[]u8, value);
}

fn extractOpenAIText(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    // First check for tool calls
    if (try extractToolCallsAsText(allocator, json)) |tool_text| {
        return tool_text;
    }

    const OutputContent = struct { text: ?[]const u8 = null };
    const OutputItem = struct {
        text: ?[]const u8 = null,
        content: ?[]const OutputContent = null,
    };
    const Msg = struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        // Alternative field names for thinking content
        reasoning: ?[]const u8 = null,
        thought: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
    };
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
            const message = choices[0].message;
            // Check all possible thinking/reasoning field names
            const reasoning = message.reasoning_content orelse message.reasoning orelse message.thought orelse message.thinking;
            const has_reasoning = reasoning != null and reasoning.?.len > 0;
            const has_content = message.content != null and message.content.?.len > 0;

            if (has_reasoning or has_content) {
                var result = std.ArrayList(u8).empty;
                defer result.deinit(allocator);
                const w = result.writer(allocator);

                // Add terse thinking indicator (like OpenCode - just show it's thinking)
                if (has_reasoning) {
                    // Just show [thinking] indicator in dim gray, don't print full reasoning
                    try w.print("\x1b[90m[thinking]\x1b[0m ", .{});
                }

                // Add main content
                if (has_content) {
                    try w.print("{s}", .{message.content.?});
                }

                return @as(?[]u8, try result.toOwnedSlice(allocator));
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
