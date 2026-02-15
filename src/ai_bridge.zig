const std = @import("std");
const logger = @import("logger.zig");

const OPENAI_CODEX_RESPONSES_ENDPOINT: []const u8 = "https://chatgpt.com/backend-api/codex/responses";
const COPILOT_RESPONSES_ENDPOINT: []const u8 = "https://api.githubcopilot.com/v1/responses";
const COPILOT_GITHUB_TOKEN_EXCHANGE_ENDPOINT: []const u8 = "https://api.github.com/copilot_internal/v2/token";
const COPILOT_EDITOR_VERSION: []const u8 = "vscode/1.85.0";
const COPILOT_EDITOR_PLUGIN_VERSION: []const u8 = "github-copilot-chat/0.23.0";

fn isLikelyOAuthToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "sk-")) return false;
    return std.mem.count(u8, token, ".") >= 2;
}

fn isLikelyJwtLike(token: []const u8) bool {
    // Heuristic: JWTs are dot-separated base64url segments; GitHub OAuth tokens (ghu_/gho_)
    // are short and typically do not contain multiple dots.
    return std.mem.count(u8, token, ".") >= 2 or std.mem.startsWith(u8, token, "eyJ");
}

fn exchangeGitHubTokenForCopilotApiToken(allocator: std.mem.Allocator, github_token: []const u8) !?[]u8 {
    // Copilot API often expects a short-lived JWT returned by GitHub's copilot_internal token endpoint.
    // See: https://api.github.com/copilot_internal/v2/token
    if (github_token.len == 0) return null;

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{github_token});
    defer allocator.free(auth_value);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    headers.user_agent = .{ .override = "zagent/0.1" };

    const extra = [_]std.http.Header{
        .{ .name = "accept", .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };

    const raw = httpRequest(allocator, .GET, COPILOT_GITHUB_TOKEN_EXCHANGE_ENDPOINT, headers, &extra, null) catch return null;
    defer allocator.free(raw);

    const Resp = struct { token: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Resp, allocator, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const tok = parsed.value.token orelse return null;
    const trimmed = std.mem.trim(u8, tok, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn effectiveCopilotBearerToken(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    // If the configured key is already a JWT-like token, use it directly.
    // Otherwise, treat it as a GitHub OAuth token and exchange it.
    if (isLikelyJwtLike(api_key)) return try allocator.dupe(u8, api_key);
    if (exchangeGitHubTokenForCopilotApiToken(allocator, api_key) catch null) |tok| return tok;
    return try allocator.dupe(u8, api_key);
}

fn writeJsonStringEscaped(w: anytype, s: []const u8) !void {
    // Emit a JSON string with standard escapes. For bytes >= 0x80, always escape as \u00XX
    // so the output is valid UTF-8 JSON regardless of input encoding.
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
                } else if (ch >= 0x80) {
                    try w.print("\\u00{x:0>2}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

var last_provider_error_buf: [512]u8 = undefined;
var last_provider_error_len: usize = 0;

fn setLastProviderError(msg: []const u8) void {
    const n = @min(msg.len, last_provider_error_buf.len);
    @memcpy(last_provider_error_buf[0..n], msg[0..n]);
    last_provider_error_len = n;
}

pub fn getLastProviderError() ?[]const u8 {
    if (last_provider_error_len == 0) return null;
    return last_provider_error_buf[0..last_provider_error_len];
}

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
    if (std.mem.eql(u8, provider_id, "openai") and isLikelyOAuthToken(api_key)) {
        return chatDirectOpenAICodexResponses(allocator, api_key, model_id, messages_json);
    }
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        const bearer = try effectiveCopilotBearerToken(allocator, api_key);
        defer allocator.free(bearer);

        // Copilot can expose multiple OpenAI-compatible surfaces. In practice:
        // - /v1/responses may be forbidden in some environments or for some models.
        // - a model may be "not supported" on Responses but still work on Chat Completions.
        // So we try Responses first, then fall back to Chat Completions for common provider errors.
        const primary = chatDirectCopilotResponses(allocator, bearer, model_id, messages_json);
        return primary catch |err| {
            if (err != error.ModelProviderError) return err;
            const detail = getLastProviderError() orelse return err;
            const is_forbidden = std.mem.indexOf(u8, detail, "forbidden") != null or
                std.mem.indexOf(u8, detail, "Terms of Service") != null;
            const is_not_supported = std.mem.indexOf(u8, detail, "not supported") != null or
                std.mem.indexOf(u8, detail, "model_not_supported") != null;

            if (!is_forbidden and !is_not_supported) return err;

            last_provider_error_len = 0;
            const config = getProviderConfig(provider_id);
            const body = try buildChatBody(allocator, model_id, messages_json, reasoning_effort);
            defer allocator.free(body);

            const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{bearer});
            defer allocator.free(auth_value);

            var headers = std.http.Client.Request.Headers{
                .authorization = .{ .override = auth_value },
                .content_type = .{ .override = "application/json" },
            };
            if (config.user_agent) |ua| headers.user_agent = .{ .override = ua };

            const extra = [_]std.http.Header{
                .{ .name = "accept", .value = "application/json" },
                .{ .name = "Editor-Version", .value = COPILOT_EDITOR_VERSION },
                .{ .name = "Editor-Plugin-Version", .value = COPILOT_EDITOR_PLUGIN_VERSION },
                .{ .name = "x-initiator", .value = "agent" },
                .{ .name = "Openai-Intent", .value = "conversation-edits" },
            };

            const raw = try httpRequest(allocator, .POST, config.endpoint, headers, &extra, body);
            defer allocator.free(raw);
            return parseChatResponse(allocator, raw);
        };
    }

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



fn chatDirectOpenAICodexResponses(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    messages_json: []const u8,
) !ChatResponse {
    last_provider_error_len = 0;

    const body = try buildCodexResponsesBody(allocator, model_id, messages_json);
    defer allocator.free(body);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };

    const raw = try httpRequest(
        allocator,
        .POST,
        OPENAI_CODEX_RESPONSES_ENDPOINT,
        headers,
        &.{.{ .name = "originator", .value = "zagent" }},
        body,
    );
    defer allocator.free(raw);

    return parseCodexResponsesStream(allocator, raw);
}

fn chatDirectCopilotResponses(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    messages_json: []const u8,
) !ChatResponse {
    last_provider_error_len = 0;

    const body = try buildCodexResponsesBody(allocator, model_id, messages_json);
    defer allocator.free(body);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    headers.user_agent = .{ .override = "zagent/0.1" };

    const extra = [_]std.http.Header{
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "Editor-Version", .value = COPILOT_EDITOR_VERSION },
        .{ .name = "Editor-Plugin-Version", .value = COPILOT_EDITOR_PLUGIN_VERSION },
        .{ .name = "x-initiator", .value = "agent" },
        .{ .name = "Openai-Intent", .value = "conversation-edits" },
    };
    const raw = try httpRequest(
        allocator,
        .POST,
        COPILOT_RESPONSES_ENDPOINT,
        headers,
        &extra,
        body,
    );
    defer allocator.free(raw);

    return parseCodexResponsesStream(allocator, raw);
}

fn buildCodexResponsesBody(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    messages_json: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, messages_json, .{ .ignore_unknown_fields = true }) catch {
        setLastProviderError("invalid messages json");
        return error.ModelResponseParseError;
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        setLastProviderError("messages json must be an array");
        return error.ModelResponseParseError;
    }

    var instructions: []const u8 = "";

    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);
    const w_in = input.writer(allocator);

    try w_in.writeAll("[");
    var wrote_any = false;

    for (parsed.value.array.items) |msg_val| {
        if (msg_val != .object) continue;
        const obj = msg_val.object;

        // Any per-message allocations must live until we've serialized this message.
        var owned_content: ?[]u8 = null;
        defer if (owned_content) |b| allocator.free(b);

        const role_val = obj.get("role") orelse continue;
        if (role_val != .string) continue;
        const role = role_val.string;

        if (std.mem.eql(u8, role, "system")) {
            if (obj.get("content")) |c| {
                if (c == .string) instructions = c.string;
            }
            continue;
        }

        const content_val = obj.get("content") orelse continue;
        if (content_val != .string) continue;
        var content = content_val.string;
        if (content.len == 0) continue;

        var out_role: []const u8 = if (std.mem.eql(u8, role, "assistant")) "assistant" else "user";
        if (std.mem.eql(u8, role, "tool")) {
            out_role = "user";
            // Keep tool output visible to the model even though we don't encode tool_result items.
            owned_content = try std.fmt.allocPrint(allocator, "[tool]\n{s}", .{content});
            content = owned_content.?;
        }

        if (wrote_any) try w_in.writeAll(",");
        wrote_any = true;

        try w_in.writeAll("{\"type\":\"message\",\"role\":\"");
        try writeJsonStringEscaped(w_in, out_role);
        const content_type: []const u8 = if (std.mem.eql(u8, out_role, "assistant")) "output_text" else "input_text";
        try w_in.writeAll("\",\"content\":[{\"type\":\"");
        try w_in.writeAll(content_type);
        try w_in.writeAll("\",\"text\":\"");
        try writeJsonStringEscaped(w_in, content);
        try w_in.writeAll("\"}]}" );
    }

    try w_in.writeAll("]");

    // Codex backend is strict about JSON Schema: additionalProperties must be present and false,
    // and required must include every key in properties.
    const tools_json =
        "[" ++
        "{\"type\":\"function\",\"name\":\"bash\",\"description\":\"Execute a shell command and return stdout.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"respond_text\",\"description\":\"Return final plain-text response when no more tools are needed.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read a file and return its contents.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"path\",\"offset\",\"limit\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"write_file\",\"description\":\"Write content to a file.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"replace_in_file\",\"description\":\"Replace text in a file.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"}},\"required\":[\"path\",\"find\",\"replace\"]},\"strict\":true}" ++
        "]";

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const w_out = out.writer(allocator);

    try w_out.writeAll("{\"model\":\"");
    try writeJsonStringEscaped(w_out, model_id);
    try w_out.writeAll("\",\"instructions\":\"");
    try writeJsonStringEscaped(w_out, instructions);
    try w_out.writeAll("\",\"input\":");
    try w_out.writeAll(input.items);
    try w_out.writeAll(",\"tools\":");
    try w_out.writeAll(tools_json);
    try w_out.writeAll(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"]}");

    return out.toOwnedSlice(allocator);
}

fn parseCodexResponsesStream(allocator: std.mem.Allocator, raw: []const u8) !ChatResponse {
    // Expect SSE payload when stream=true.
    if (std.mem.indexOf(u8, raw, "data:") == null) {
        // Attempt to parse JSON error shapes.
        if (std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true })) |root_parsed| {
            defer root_parsed.deinit();
            if (root_parsed.value == .object) {
                if (root_parsed.value.object.get("error")) |err_val| {
                    if (err_val == .object) {
                        if (err_val.object.get("message")) |m| if (m == .string) setLastProviderError(m.string);
                    } else if (err_val == .string) {
                        setLastProviderError(err_val.string);
                    }
                    return error.ModelProviderError;
                }
                // Some providers return non-stream JSON even when stream=true.
                if (root_parsed.value.object.get("output")) |out_val| {
                    if (out_val == .array) {
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
                            const calls = try allocator.alloc(ToolCall, 1);
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
                            .tool_calls = try allocator.alloc(ToolCall, 0),
                            .finish_reason = try allocator.dupe(u8, "stop"),
                        };
                    }
                }
                if (root_parsed.value.object.get("detail")) |d| {
                    if (d == .string) {
                        setLastProviderError(d.string);
                        return error.ModelProviderError;
                    }
                }
            }
        } else |_| {}

        // Plain-text provider errors (e.g. "Access to this endpoint is forbidden...")
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            const cap = @min(trimmed.len, 300);
            setLastProviderError(trimmed[0..cap]);
            return error.ModelProviderError;
        }

        setLastProviderError("unexpected non-stream response from codex backend");
        return error.ModelResponseParseError;
    }

    var out_text = std.ArrayList(u8).empty;
    defer out_text.deinit(allocator);

    var current_name: ?[]u8 = null;
    defer if (current_name) |n| allocator.free(n);
    var args = std.ArrayList(u8).empty;
    defer args.deinit(allocator);
    var saw_args_delta: bool = false;

    const OutputItem = struct {
        type: ?[]const u8 = null,
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    };
    const SSEEvent = struct {
        type: ?[]const u8 = null,
        delta: ?[]const u8 = null,
        text: ?[]const u8 = null,
        output_text: ?[]const u8 = null,
        item: ?OutputItem = null,
    };

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line[5..], " \t");
        if (payload.len == 0 or std.mem.eql(u8, payload, "[DONE]")) continue;

        var ev = std.json.parseFromSlice(SSEEvent, allocator, payload, .{ .ignore_unknown_fields = true }) catch continue;
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
                    // When deltas are present, treat them as the source of truth; some streams also
                    // include a full `item.arguments` field which would otherwise duplicate args.
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
        const calls = try allocator.alloc(ToolCall, 1);
        calls[0] = .{
            .id = try allocator.dupe(u8, "call_0"),
            .tool = current_name.?,
            .args = try allocator.dupe(u8, args.items),
        };
        current_name = null; // ownership moved
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
        .tool_calls = try allocator.alloc(ToolCall, 0),
        .finish_reason = try allocator.dupe(u8, "stop"),
    };
}
fn parseChatResponse(allocator: std.mem.Allocator, raw: []const u8) !ChatResponse {
    last_provider_error_len = 0;

    // Chat Completions should always return JSON. If we get plain text (common for 401/403 from some
    // upstreams), surface it as a provider error instead of a JSON parse error.
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] != '{' and trimmed[0] != '[') {
        const cap = @min(trimmed.len, 300);
        setLastProviderError(trimmed[0..cap]);
        return error.ModelProviderError;
    }

    if (std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true })) |root_parsed| {
        defer root_parsed.deinit();
        if (root_parsed.value == .object) {
            if (root_parsed.value.object.get("error")) |err_val| {
                if (err_val == .object) {
                    const err_obj = err_val.object;
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
                        setLastProviderError(detail);
                    } else {
                        logger.err("Upstream model error object present with no details", .{});
                        setLastProviderError("provider returned an error object with no message");
                    }
                    return error.ModelProviderError;
                }
            }
        }
    } else |_| {}

    const ErrorCode = union(enum) {
        string: []const u8,
        integer: i64,
        float: f64,
    };
    const ErrorEnvelope = struct {
        @"error": ?struct {
            message: ?[]const u8 = null,
            code: ?ErrorCode = null,
            type: ?[]const u8 = null,
            metadata: ?struct {
                provider_name: ?[]const u8 = null,
            } = null,
        } = null,
    };
    if (std.json.parseFromSlice(ErrorEnvelope, allocator, raw, .{ .ignore_unknown_fields = true })) |maybe_err| {
        defer maybe_err.deinit();
        if (maybe_err.value.@"error") |api_err| {
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
                setLastProviderError(detail);
            } else {
                logger.err("Upstream model error object present with no details", .{});
                setLastProviderError("provider returned an error object with no message");
            }
            return error.ModelProviderError;
        }
    } else |_| {}

    var parsed = std.json.parseFromSlice(ChatResponseRaw, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Model response parse error: {s}; raw prefix: {s}", .{ @errorName(err), prefix });
        return error.ModelResponseParseError;
    };
    defer parsed.deinit();

    const choices = parsed.value.choices orelse {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Model response missing choices; raw prefix: {s}", .{prefix});
        setLastProviderError("response missing choices");
        return error.ModelResponseMissingChoices;
    };
    if (choices.len == 0) {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Model response has empty choices; raw prefix: {s}", .{prefix});
        setLastProviderError("response has empty choices");
        return error.ModelResponseMissingChoices;
    }

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
    // Keep schemas minimal and strict; some providers validate required/additionalProperties aggressively.
    try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"Execute a shell command and return stdout.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"respond_text\",\"description\":\"Return final plain-text response when no more tools are needed.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read a file and return its contents.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"path\",\"offset\",\"limit\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"description\":\"Write content to a file.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"replace_in_file\",\"description\":\"Replace text in a file.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"}},\"required\":[\"path\",\"find\",\"replace\"]},\"strict\":true}}");
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
    } else if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return .{
            .endpoint = "https://api.githubcopilot.com/chat/completions",
            .referer = null,
            .title = null,
            .user_agent = "zagent/0.1",
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



fn getModelsEndpoint(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) {
        return "https://api.openai.com/v1/models";
    } else if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return "https://api.githubcopilot.com/models";
    } else if (std.mem.eql(u8, provider_id, "opencode")) {
        return "https://opencode.ai/zen/v1/models";
    } else if (std.mem.eql(u8, provider_id, "openrouter")) {
        return "https://openrouter.ai/api/v1/models";
    } else {
        return null;
    }
}

const OPENAI_CODEX_MODELS_ENDPOINT: []const u8 = "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0";

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        var ok = true;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

pub fn listModelsDirect(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    provider_id: []const u8,
    filter: []const u8,
) ![]u8 {
    last_provider_error_len = 0;

    const effective_key = if (std.mem.eql(u8, provider_id, "github-copilot"))
        try effectiveCopilotBearerToken(allocator, api_key)
    else
        try allocator.dupe(u8, api_key);
    defer allocator.free(effective_key);

    const use_codex_models = std.mem.eql(u8, provider_id, "openai") and isLikelyOAuthToken(api_key);
    const endpoint = if (use_codex_models)
        OPENAI_CODEX_MODELS_ENDPOINT
    else
        getModelsEndpoint(provider_id) orelse {
            setLastProviderError("provider does not support listing models");
            return error.UnsupportedProvider;
        };

    const config = getProviderConfig(provider_id);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{effective_key});
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
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        try extra_headers.append(allocator, .{ .name = "accept", .value = "application/json" });
        try extra_headers.append(allocator, .{ .name = "Editor-Version", .value = COPILOT_EDITOR_VERSION });
        try extra_headers.append(allocator, .{ .name = "Editor-Plugin-Version", .value = COPILOT_EDITOR_PLUGIN_VERSION });
        try extra_headers.append(allocator, .{ .name = "x-initiator", .value = "user" });
        try extra_headers.append(allocator, .{ .name = "Openai-Intent", .value = "conversation-edits" });
    }

    const raw = try httpRequest(allocator, .GET, endpoint, headers, extra_headers.items, null);
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Models response parse error: {s}; raw prefix: {s}", .{ @errorName(err), prefix });
        setLastProviderError("models response parse error");
        return error.ModelResponseParseError;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        setLastProviderError("models response is not an object");
        return error.ModelResponseParseError;
    }

    // Error envelope variants we see in the wild:
    // - {"error": {"message": ..., "code": ...}}
    // - {"error": "..."}
    if (parsed.value.object.get("error")) |err_val| {
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        switch (err_val) {
            .string => |s| {
                try w.print("message={s}", .{s});
            },
            .object => |obj| {
                if (obj.get("code")) |code| {
                    switch (code) {
                        .string => |s| try w.print("code={s}", .{s}),
                        .integer => |n| try w.print("code={d}", .{n}),
                        .float => |n| try w.print("code={d}", .{n}),
                        else => {},
                    }
                }
                if (obj.get("message")) |msg| {
                    if (msg == .string) {
                        if (fbs.pos > 0) try w.writeAll(" ");
                        try w.print("message={s}", .{msg.string});
                    }
                } else if (obj.get("type")) |kind| {
                    if (kind == .string) {
                        if (fbs.pos > 0) try w.writeAll(" ");
                        try w.print("type={s}", .{kind.string});
                    }
                }
            },
            else => {
                try w.writeAll("provider returned an error");
            },
        }

        // Add a bit of actionable context for the common OpenAI permission failure.
        if (std.mem.eql(u8, provider_id, "openai")) {
            const msg = fbs.getWritten();
            if (std.mem.indexOf(u8, msg, "Missing scopes") != null and std.mem.indexOf(u8, msg, "api.model.read") != null) {
                // Keep it short to fit the fixed buffer.
                if (fbs.pos + 2 < buf.len) {
                    try w.writeAll("; ");
                    try w.writeAll("need api.model.read scope or a project/org role that grants model listing");
                }
            }
        }

        const detail = fbs.getWritten();
        logger.err("Upstream models error: {s}", .{detail});
        setLastProviderError(detail);
        return error.ModelProviderError;
    }

    const q = std.mem.trim(u8, filter, " \t\r\n");

    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("Available models for {s}", .{provider_id});
    if (use_codex_models) {
        try w.writeAll(" (codex backend)");
    }
    if (q.len > 0) try w.print(" (filter: {s})", .{q});
    try w.writeAll(":\n");

    const limit: usize = 200;
    var total: usize = 0;
    var matched: usize = 0;
    var printed: usize = 0;

    if (use_codex_models) {
        const models_val = parsed.value.object.get("models") orelse {
            const prefix = if (raw.len > 300) raw[0..300] else raw;
            logger.err("Codex models response missing models; raw prefix: {s}", .{prefix});
            setLastProviderError("models response missing models");
            return error.ModelResponseParseError;
        };
        if (models_val != .array) {
            setLastProviderError("models response models is not an array");
            return error.ModelResponseParseError;
        }

        for (models_val.array.items) |item| {
            if (item != .object) continue;
            const slug_val = item.object.get("slug") orelse continue;
            if (slug_val != .string) continue;
            const slug = slug_val.string;
            total += 1;

            if (q.len > 0 and !containsIgnoreCase(slug, q)) continue;
            matched += 1;

            if (printed < limit) {
                try w.print("- {s}\n", .{slug});
                printed += 1;
            }
        }
    } else {
        const data_val = parsed.value.object.get("data") orelse {
            const prefix = if (raw.len > 300) raw[0..300] else raw;
            logger.err("Models response missing data; raw prefix: {s}", .{prefix});
            setLastProviderError("models response missing data");
            return error.ModelResponseParseError;
        };
        if (data_val != .array) {
            setLastProviderError("models response data is not an array");
            return error.ModelResponseParseError;
        }

        for (data_val.array.items) |item| {
            if (item != .object) continue;
            const id_val = item.object.get("id") orelse continue;
            if (id_val != .string) continue;
            const id = id_val.string;
            total += 1;

            if (q.len > 0 and !containsIgnoreCase(id, q)) continue;
            matched += 1;

            if (printed < limit) {
                try w.print("- {s}\n", .{id});
                printed += 1;
            }
        }
    }

    if (matched > printed) {
        try w.print("... and {d} more\n", .{matched - printed});
    }
    try w.print("Matched {d}/{d}\n", .{ matched, total });

    return out.toOwnedSlice(allocator);
}


pub fn fetchModelIDsDirect(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    provider_id: []const u8,
) ![][]u8 {
    last_provider_error_len = 0;

    const effective_key = if (std.mem.eql(u8, provider_id, "github-copilot"))
        try effectiveCopilotBearerToken(allocator, api_key)
    else
        try allocator.dupe(u8, api_key);
    defer allocator.free(effective_key);

    const use_codex_models = std.mem.eql(u8, provider_id, "openai") and isLikelyOAuthToken(api_key);
    const endpoint = if (use_codex_models)
        OPENAI_CODEX_MODELS_ENDPOINT
    else
        getModelsEndpoint(provider_id) orelse {
            setLastProviderError("provider does not support listing models");
            return error.UnsupportedProvider;
        };

    const config = getProviderConfig(provider_id);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{effective_key});
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
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        try extra_headers.append(allocator, .{ .name = "accept", .value = "application/json" });
        try extra_headers.append(allocator, .{ .name = "Editor-Version", .value = COPILOT_EDITOR_VERSION });
        try extra_headers.append(allocator, .{ .name = "Editor-Plugin-Version", .value = COPILOT_EDITOR_PLUGIN_VERSION });
        try extra_headers.append(allocator, .{ .name = "x-initiator", .value = "user" });
        try extra_headers.append(allocator, .{ .name = "Openai-Intent", .value = "conversation-edits" });
    }

    const raw = try httpRequest(allocator, .GET, endpoint, headers, extra_headers.items, null);
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Models response parse error: {s}; raw prefix: {s}", .{ @errorName(err), prefix });
        setLastProviderError("models response parse error");
        return error.ModelResponseParseError;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        setLastProviderError("models response is not an object");
        return error.ModelResponseParseError;
    }

    if (parsed.value.object.get("error")) |err_val| {
        var buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        switch (err_val) {
            .string => |s| {
                try w.print("message={s}", .{s});
            },
            .object => |obj| {
                if (obj.get("code")) |code| {
                    switch (code) {
                        .string => |s| try w.print("code={s}", .{s}),
                        .integer => |n| try w.print("code={d}", .{n}),
                        .float => |n| try w.print("code={d}", .{n}),
                        else => {},
                    }
                }
                if (obj.get("message")) |msg| {
                    if (msg == .string) {
                        if (fbs.pos > 0) try w.writeAll(" ");
                        try w.print("message={s}", .{msg.string});
                    }
                } else if (obj.get("type")) |kind| {
                    if (kind == .string) {
                        if (fbs.pos > 0) try w.writeAll(" ");
                        try w.print("type={s}", .{kind.string});
                    }
                }
            },
            else => {
                try w.writeAll("provider returned an error");
            },
        }

        const detail = fbs.getWritten();
        logger.err("Upstream models error: {s}", .{detail});
        setLastProviderError(detail);
        return error.ModelProviderError;
    }

    var out = std.ArrayList([]u8).empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    if (use_codex_models) {
        const models_val = parsed.value.object.get("models") orelse {
            const prefix = if (raw.len > 300) raw[0..300] else raw;
            logger.err("Codex models response missing models; raw prefix: {s}", .{prefix});
            setLastProviderError("models response missing models");
            return error.ModelResponseParseError;
        };
        if (models_val != .array) {
            setLastProviderError("models response models is not an array");
            return error.ModelResponseParseError;
        }

        for (models_val.array.items) |item| {
            if (item != .object) continue;
            const slug_val = item.object.get("slug") orelse continue;
            if (slug_val != .string) continue;
            try out.append(allocator, try allocator.dupe(u8, slug_val.string));
        }
    } else {
        const data_val = parsed.value.object.get("data") orelse {
            const prefix = if (raw.len > 300) raw[0..300] else raw;
            logger.err("Models response missing data; raw prefix: {s}", .{prefix});
            setLastProviderError("models response missing data");
            return error.ModelResponseParseError;
        };
        if (data_val != .array) {
            setLastProviderError("models response data is not an array");
            return error.ModelResponseParseError;
        }

        for (data_val.array.items) |item| {
            if (item != .object) continue;
            const id_val = item.object.get("id") orelse continue;
            if (id_val != .string) continue;
            try out.append(allocator, try allocator.dupe(u8, id_val.string));
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn freeModelIDs(allocator: std.mem.Allocator, ids: [][]u8) void {
    for (ids) |s| allocator.free(s);
    allocator.free(ids);
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

    // Use an allocating writer that supports `rebase`, which the stdlib HTTP decompressor requires.
    // (ArrayList writer adapters may panic with unreachableRebase during gzip/deflate.)
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    // Avoid compressed responses: Zig stdlib decompressor may require Writer.rebase support, and
    // some writer adapters (or Zig versions) can still hit unreachableRebase. "identity" keeps
    // the response uncompressed in practice.
    var all_headers = std.ArrayList(std.http.Header).empty;
    defer all_headers.deinit(allocator);
    try all_headers.ensureTotalCapacity(allocator, extra_headers.len + 1);
    var has_ae = false;
    for (extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) has_ae = true;
        try all_headers.append(allocator, h);
    }
    if (!has_ae) {
        try all_headers.append(allocator, .{ .name = "accept-encoding", .value = "identity" });
    }

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .headers = headers,
        .extra_headers = all_headers.items,
        .payload = payload,
        .response_writer = &out.writer,
    });

    return out.toOwnedSlice();
}
