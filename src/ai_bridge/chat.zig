const std = @import("std");
const types = @import("types.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const body = @import("body.zig");
const parser = @import("parser.zig");
const http = @import("http.zig");
const errors = @import("errors.zig");

pub fn chatDirect(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    provider_id: []const u8,
    messages_json: []const u8,
    reasoning_effort: ?[]const u8,
) !types.ChatResponse {
    if (std.mem.eql(u8, provider_id, "openai") and auth.isOAuthToken(api_key)) {
        return chatDirectOpenAICodexResponses(allocator, api_key, model_id, messages_json);
    }
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        const bearer = try auth.effectiveCopilotBearerToken(allocator, api_key);
        defer allocator.free(bearer);

        // Copilot can expose multiple OpenAI-compatible surfaces. In practice:
        // - /v1/responses may be forbidden in some environments or for some models.
        // - a model may be "not supported" on Responses but still work on Chat Completions.
        // So we try Responses first, then fall back to Chat Completions for common provider errors.
        const primary = chatDirectCopilotResponses(allocator, bearer, model_id, messages_json);
        return primary catch |err| {
            if (err != errors.ProviderError.ModelProviderError) return err;
            const detail = errors.getLastProviderError() orelse return err;
            const is_forbidden = std.mem.indexOf(u8, detail, "forbidden") != null or
                std.mem.indexOf(u8, detail, "Terms of Service") != null;
            const is_not_supported = std.mem.indexOf(u8, detail, "not supported") != null or
                std.mem.indexOf(u8, detail, "model_not_supported") != null;

            if (!is_forbidden and !is_not_supported) return err;

            errors.clearLastProviderError();
            return try chatDirectCopilotChatCompletions(allocator, bearer, model_id, messages_json, reasoning_effort);
        };
    }

    const cfg = config.getProviderConfig(provider_id);
    const req_body = try body.buildChatBody(allocator, model_id, messages_json, reasoning_effort);
    defer allocator.free(req_body);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    if (cfg.user_agent) |ua| headers.user_agent = .{ .override = ua };

    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(allocator);
    if (cfg.referer) |r| try extra_headers.append(allocator, .{ .name = "HTTP-Referer", .value = r });
    if (cfg.title) |t| try extra_headers.append(allocator, .{ .name = "X-Title", .value = t });

    const raw = try http.httpRequest(
        allocator,
        .POST,
        cfg.endpoint,
        headers,
        extra_headers.items,
        req_body,
    );
    defer allocator.free(raw);

    return parser.parseChatResponse(allocator, raw);
}

fn chatDirectOpenAICodexResponses(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    messages_json: []const u8,
) !types.ChatResponse {
    errors.clearLastProviderError();

    const req_body = try body.buildCodexResponsesBody(allocator, model_id, messages_json);
    defer allocator.free(req_body);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };

    const raw = try http.httpRequest(
        allocator,
        .POST,
        types.Constants.OPENAI_CODEX_RESPONSES_ENDPOINT,
        headers,
        &.{.{ .name = "originator", .value = "zagent" }},
        req_body,
    );
    defer allocator.free(raw);

    return parser.parseCodexResponsesStream(allocator, raw);
}

fn chatDirectCopilotResponses(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    messages_json: []const u8,
) !types.ChatResponse {
    errors.clearLastProviderError();

    const req_body = try body.buildCodexResponsesBody(allocator, model_id, messages_json);
    defer allocator.free(req_body);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    headers.user_agent = .{ .override = "zagent/0.1" };

    const extra = [_]std.http.Header{
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "Editor-Version", .value = types.Constants.COPILOT_EDITOR_VERSION },
        .{ .name = "Editor-Plugin-Version", .value = types.Constants.COPILOT_EDITOR_PLUGIN_VERSION },
        .{ .name = "x-initiator", .value = "agent" },
        .{ .name = "Openai-Intent", .value = "conversation-edits" },
    };
    const raw = try http.httpRequest(
        allocator,
        .POST,
        types.Constants.COPILOT_RESPONSES_ENDPOINT,
        headers,
        &extra,
        req_body,
    );
    defer allocator.free(raw);

    return parser.parseCodexResponsesStream(allocator, raw);
}

fn chatDirectCopilotChatCompletions(
    allocator: std.mem.Allocator,
    bearer: []const u8,
    model_id: []const u8,
    messages_json: []const u8,
    reasoning_effort: ?[]const u8,
) !types.ChatResponse {
    const cfg = config.getProviderConfig("github-copilot");
    const req_body = try body.buildChatBody(allocator, model_id, messages_json, reasoning_effort);
    defer allocator.free(req_body);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{bearer});
    defer allocator.free(auth_value);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    if (cfg.user_agent) |ua| headers.user_agent = .{ .override = ua };

    const extra = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
        .{ .name = "Editor-Version", .value = types.Constants.COPILOT_EDITOR_VERSION },
        .{ .name = "Editor-Plugin-Version", .value = types.Constants.COPILOT_EDITOR_PLUGIN_VERSION },
        .{ .name = "x-initiator", .value = "agent" },
        .{ .name = "Openai-Intent", .value = "conversation-edits" },
    };

    const raw = try http.httpRequest(allocator, .POST, cfg.endpoint, headers, &extra, req_body);
    defer allocator.free(raw);

    return parser.parseChatResponse(allocator, raw);
}
