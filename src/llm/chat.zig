const std = @import("std");
const client = @import("client.zig");
const provider = @import("../provider.zig");
const codex = @import("codex.zig");
const types = @import("types.zig");
const utils = @import("utils.zig");

// Thread-local error storage
threadlocal var last_error_buf: [512]u8 = undefined;
threadlocal var last_error_len: usize = 0;

pub fn getLastProviderError() ?[]const u8 {
    if (last_error_len == 0) return null;
    return last_error_buf[0..last_error_len];
}

fn setLastError(msg: []const u8) void {
    const n = @min(msg.len, last_error_buf.len);
    @memcpy(last_error_buf[0..n], msg[0..n]);
    last_error_len = n;
}

pub fn chat(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    provider_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
    reasoning_effort: ?[]const u8,
) !types.ChatResponse {
    last_error_len = 0;
    // Auto-use "public" key for opencode free tier models
    const is_opencode_free = std.mem.eql(u8, provider_id, "opencode") and std.mem.indexOf(u8, model_id, "free") != null;
    const real_key = if (is_opencode_free) (if (api_key.len == 0) "public" else api_key) else api_key;

    if (std.mem.eql(u8, provider_id, "openai") and provider.isLikelyOAuthToken(real_key)) {
        return chatCodex(allocator, real_key, model_id, messages_json, tool_defs);
    }

    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        const bearer = try provider.effectiveCopilotBearerToken(allocator, real_key);
        defer allocator.free(bearer);

        const first_try = chatCopilotResponses(allocator, bearer, model_id, messages_json, tool_defs);
        if (first_try) |res| return res else |err| {
            if (err != types.QueryError.ModelProviderError) return err;
        }

        return chatGeneric(allocator, bearer, model_id, provider_id, messages_json, tool_defs, reasoning_effort);
    }

    return chatGeneric(allocator, real_key, model_id, provider_id, messages_json, tool_defs, reasoning_effort);
}

pub fn query(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api_key: ?[]const u8,
    model_id: []const u8,
    prompt: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
) ![]u8 {
    last_error_len = 0;
    const key = api_key orelse return types.QueryError.MissingApiKey;

    if (std.mem.eql(u8, provider_id, "anthropic")) {
        return queryAnthropic(allocator, key, model_id, prompt, tool_defs);
    }

    var json_prompt: std.ArrayListUnmanaged(u8) = .empty;
    defer json_prompt.deinit(allocator);
    try utils.writeJsonString(json_prompt.writer(allocator), prompt);
    const msgs_safe = try std.fmt.allocPrint(allocator, "[{{\"role\":\"user\",\"content\":\"{s}\"}}]", .{json_prompt.items});
    defer allocator.free(msgs_safe);

    const res = try chat(allocator, key, model_id, provider_id, msgs_safe, tool_defs, null);
    defer res.deinit(allocator);
    return try allocator.dupe(u8, res.text);
}

pub fn inferToolCall(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api_key: ?[]const u8,
    model_id: []const u8,
    prompt: []const u8,
    defs: []const types.ToolRouteDef,
    force_tool: bool,
) !?types.ToolRouteCall {
    const res = try inferToolCallWithThinking(allocator, provider_id, api_key, model_id, prompt, defs, force_tool);
    if (res) |r| {
        if (r.thinking) |t| allocator.free(t);
        return r.call;
    }
    return null;
}

pub fn inferToolCallWithThinking(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    api_key: ?[]const u8,
    model_id: []const u8,
    prompt: []const u8,
    defs: []const types.ToolRouteDef,
    force_tool: bool,
) !?types.ToolRouteResult {
    last_error_len = 0;
    if (!std.mem.eql(u8, provider_id, "openai")) return null;
    const key = api_key orelse return types.QueryError.MissingApiKey;

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
    defer allocator.free(auth_value);

    const uri = if (provider.isLikelyOAuthToken(key)) "https://chatgpt.com/backend-api/codex/responses" else "https://api.openai.com/v1/chat/completions";

    // Simplification: assume standardized chat body for forcing tools.
    const body = try buildChatBodyForRouting(allocator, model_id, prompt, defs, force_tool);
    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };

    const out = try client.httpRequest(allocator, .POST, uri, headers, &.{}, body);
    defer allocator.free(out);

    const call = try parseStandardToolCall(allocator, out);
    const thinking = try extractThinking(allocator, out);

    if (call) |c| {
        return types.ToolRouteResult{
            .call = types.ToolRouteCall{
                .tool = c.tool,
                .arguments_json = c.args,
            },
            .thinking = thinking,
        };
    }
    return null;
}

// Internal

fn chatGeneric(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    provider_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
    reasoning_effort: ?[]const u8,
) !types.ChatResponse {
    const config = provider.getProviderConfig(provider_id);
    const body = try buildChatBody(allocator, model_id, messages_json, tool_defs, reasoning_effort);
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    if (config.user_agent) |ua| headers.user_agent = .{ .override = ua };

    var extra_headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer extra_headers.deinit(allocator);
    if (config.referer) |r| try extra_headers.append(allocator, .{ .name = "HTTP-Referer", .value = r });
    if (config.title) |t| try extra_headers.append(allocator, .{ .name = "X-Title", .value = t });

    const raw = try client.httpRequest(allocator, .POST, config.endpoint, headers, extra_headers.items, body);
    defer allocator.free(raw);
    allocator.free(body); // Free request body after use

    if (raw.len == 0) {
        std.log.err("Empty response from {s}", .{config.endpoint});
        return types.QueryError.ModelProviderError;
    }

    return parseChatResponse(allocator, raw);
}

fn chatCodex(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
) !types.ChatResponse {
    const body = try codex.buildCodexBody(allocator, model_id, messages_json, tool_defs);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };

    const raw = try client.httpRequest(
        allocator,
        .POST,
        "https://chatgpt.com/backend-api/codex/responses",
        headers,
        &.{.{ .name = "originator", .value = "zagent" }},
        body,
    );
    defer allocator.free(raw);

    return codex.parseCodexStream(allocator, raw);
}

fn chatCopilotResponses(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
) !types.ChatResponse {
    const body = try codex.buildCodexBody(allocator, model_id, messages_json, tool_defs);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    var extra: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer extra.deinit(allocator);
    try extra.append(allocator, .{ .name = "accept", .value = "text/event-stream" });
    try provider.appendCopilotHeaders(allocator, &extra);

    const raw = try client.httpRequest(
        allocator,
        .POST,
        "https://api.githubcopilot.com/v1/responses",
        headers,
        extra.items,
        body,
    );
    defer allocator.free(raw);

    return codex.parseCodexStream(allocator, raw);
}

fn buildChatBody(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const types.ToolRouteDef,
    reasoning_effort: ?[]const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("{{\"model\":\"{s}\",\"messages\":{s}", .{ model_id, messages_json });

    if (tool_defs) |defs| {
        if (defs.len > 0) {
            try w.writeAll(",\"tools\":[");
            for (defs, 0..) |d, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s},\"strict\":true}}}}", .{ d.name, d.description, d.parameters_json });
            }
            try w.writeAll("]");
        }
    }

    if (reasoning_effort) |effort| {
        try w.print(",\"reasoning_effort\":{f}", .{std.json.fmt(effort, .{})});
    }
    try w.writeAll("}");
    return out.toOwnedSlice(allocator);
}

fn buildChatBodyForRouting(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    prompt: []const u8,
    defs: []const types.ToolRouteDef,
    force: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("{{\"model\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":", .{model_id});
    try utils.writeJsonString(w, prompt);
    try w.writeAll("}]");

    if (defs.len > 0) {
        try w.writeAll(",\"tools\":[");
        for (defs, 0..) |d, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s},\"strict\":true}}}}", .{ d.name, d.description, d.parameters_json });
        }
        try w.writeAll("]");
        try w.print(",\"tool_choice\":\"{s}\"", .{if (force) "required" else "auto"});
    }

    try w.writeAll("}");
    return out.toOwnedSlice(allocator);
}

fn parseChatResponse(allocator: std.mem.Allocator, raw: []const u8) !types.ChatResponse {
    const Resp = struct {
        choices: ?[]const struct {
            message: struct {
                content: ?[]const u8 = null,
                tool_calls: ?[]const struct {
                    id: []const u8,
                    function: struct {
                        name: []const u8,
                        arguments: []const u8,
                    },
                } = null,
                reasoning_content: ?[]const u8 = null,
            },
            finish_reason: ?[]const u8 = null,
        } = null,
        @"error": ?struct {
            message: ?[]const u8 = null,
            code: ?[]const u8 = null,
        } = null,
    };

    var parsed = std.json.parseFromSlice(Resp, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        // Check if this is an API error response
        if (std.mem.indexOf(u8, raw, "\"error\"")) |_| {
            std.log.err("API error: {s}", .{raw[0..@min(raw.len, 500)]});
            return types.QueryError.ModelProviderError;
        }
        std.log.err("Failed to parse model response: {s}", .{@errorName(err)});
        std.log.err("Raw response: {s}", .{raw[0..@min(raw.len, 500)]});
        return types.QueryError.ModelResponseParseError;
    };
    defer parsed.deinit();

    if (parsed.value.@"error") |e| {
        if (e.message) |m| {
            setLastError(m);
        }
        return types.QueryError.ModelProviderError;
    }

    if (parsed.value.choices) |choices| {
        if (choices.len > 0) {
            const c = choices[0];

            // Build result step by step with proper cleanup
            var text: []u8 = &.{};
            var reasoning: []u8 = &.{};
            var finish_reason: []u8 = &.{};
            var tool_calls: []types.ToolCall = &.{};

            // Parse tool calls first
            var tools: std.ArrayListUnmanaged(types.ToolCall) = .empty;
            defer {
                // If we error before moving to result, cleanup tools
                if (tool_calls.len == 0) {
                    for (tools.items) |tc| {
                        allocator.free(tc.id);
                        allocator.free(tc.tool);
                        allocator.free(tc.args);
                    }
                    tools.deinit(allocator);
                }
            }

            if (c.message.tool_calls) |tc| {
                for (tc) |t| {
                    try tools.append(allocator, .{
                        .id = try allocator.dupe(u8, t.id),
                        .tool = try allocator.dupe(u8, t.function.name),
                        .args = try allocator.dupe(u8, t.function.arguments),
                    });
                }
            }

            // Now allocate remaining fields with cleanup
            errdefer allocator.free(text);
            text = try allocator.dupe(u8, c.message.content orelse "");

            errdefer allocator.free(reasoning);
            reasoning = try allocator.dupe(u8, c.message.reasoning_content orelse "");

            errdefer allocator.free(finish_reason);
            finish_reason = try allocator.dupe(u8, c.finish_reason orelse "");

            // Move tool calls ownership (disables the defer cleanup)
            tool_calls = try tools.toOwnedSlice(allocator);

            return .{
                .text = text,
                .reasoning = reasoning,
                .tool_calls = tool_calls,
                .finish_reason = finish_reason,
            };
        }
    }

    if (raw.len > 0 and raw[0] != '{' and raw[0] != '[') {
        const cap = @min(raw.len, 500);
        setLastError(raw[0..cap]);
        return types.QueryError.ModelProviderError;
    }

    return types.QueryError.ModelResponseMissingChoices;
}

fn parseStandardToolCall(allocator: std.mem.Allocator, raw: []const u8) !?struct { tool: []u8, args: []u8 } {
    const resp = parseChatResponse(allocator, raw) catch return null;
    defer resp.deinit();

    if (resp.tool_calls.len > 0) {
        return .{
            .tool = try allocator.dupe(u8, resp.tool_calls[0].tool),
            .args = try allocator.dupe(u8, resp.tool_calls[0].args),
        };
    }
    return null;
}

fn extractThinking(allocator: std.mem.Allocator, raw: []const u8) !?[]const u8 {
    const T = struct { choices: ?[]const struct { message: struct { reasoning_content: ?[]const u8 = null } } = null };
    var p = std.json.parseFromSlice(T, allocator, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer p.deinit();
    if (p.value.choices) |c| {
        if (c.len > 0) {
            if (c[0].message.reasoning_content) |rc| return allocator.dupe(u8, rc);
        }
    }
    return null;
}

fn queryAnthropic(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, prompt: []const u8, tool_defs: ?[]const types.ToolRouteDef) ![]u8 {
    _ = tool_defs; // Not supported

    var prompt_esc: std.ArrayListUnmanaged(u8) = .empty;
    defer prompt_esc.deinit(allocator);
    try utils.writeJsonString(prompt_esc.writer(allocator), prompt);

    const full_body = try std.fmt.allocPrint(allocator, "{{\"model\":\"{s}\",\"max_tokens\":1024,\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}", .{ model_id, prompt_esc.items });
    defer allocator.free(full_body);

    const headers = std.http.Client.Request.Headers{
        .content_type = .{ .override = "application/json" },
        .user_agent = .{ .override = "zagent/0.1" },
    };
    const extra = [_]std.http.Header{
        .{ .name = "anthropic-version", .value = "2023-06-01" },
        .{ .name = "x-api-key", .value = api_key },
    };

    const out = try client.httpRequest(allocator, .POST, "https://api.anthropic.com/v1/messages", headers, &extra, full_body);
    defer allocator.free(out);

    const T = struct { content: ?[]const struct { text: ?[]const u8 = null } = null };
    var p = std.json.parseFromSlice(T, allocator, out, .{ .ignore_unknown_fields = true }) catch return types.QueryError.ModelResponseParseError;
    defer p.deinit();

    if (p.value.content) |c| {
        if (c.len > 0) {
            if (c[0].text) |t| return allocator.dupe(u8, t);
        }
    }
    return types.QueryError.ModelResponseMissingChoices;
}
