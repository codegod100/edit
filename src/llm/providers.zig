const std = @import("std");
const client = @import("client.zig");
const types = @import("types.zig");

pub const ProviderConfig = struct {
    endpoint: []const u8,
    referer: ?[]const u8,
    title: ?[]const u8,
    user_agent: ?[]const u8,
};

pub const COPILOT_GITHUB_TOKEN_EXCHANGE_ENDPOINT = "https://api.github.com/copilot_internal/v2/token";
pub const COPILOT_EDITOR_VERSION = "vscode/1.85.0";
pub const COPILOT_EDITOR_PLUGIN_VERSION = "github-copilot-chat/0.23.0";

pub fn isLikelyOAuthToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "sk-")) return false;
    return std.mem.count(u8, token, ".") >= 2;
}

pub fn getProviderConfig(provider_id: []const u8) ProviderConfig {
    if (std.mem.eql(u8, provider_id, "opencode")) {
        return .{ .endpoint = "https://opencode.ai/zen/v1/chat/completions", .referer = "https://opencode.ai/", .title = "opencode", .user_agent = "opencode/0.1.0" };
    } else if (std.mem.eql(u8, provider_id, "openrouter")) {
        return .{ .endpoint = "https://openrouter.ai/api/v1/chat/completions", .referer = "https://zagent.local/", .title = "zagent", .user_agent = null };
    } else if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return .{ .endpoint = "https://api.githubcopilot.com/chat/completions", .referer = null, .title = null, .user_agent = "zagent/0.1" };
    }
    return .{ .endpoint = "https://api.openai.com/v1/chat/completions", .referer = null, .title = null, .user_agent = null };
}

pub fn getModelsEndpoint(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) return "https://api.openai.com/v1/models";
    if (std.mem.eql(u8, provider_id, "github-copilot")) return "https://api.githubcopilot.com/models";
    if (std.mem.eql(u8, provider_id, "opencode")) return "https://opencode.ai/zen/v1/models";
    if (std.mem.eql(u8, provider_id, "openrouter")) return "https://openrouter.ai/api/v1/models";
    return null;
}

pub fn effectiveCopilotBearerToken(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    if (isLikelyOAuthToken(api_key)) return try allocator.dupe(u8, api_key);

    // Token exchange logic
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    const headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
        .user_agent = .{ .override = "zagent/0.1" },
    };
    const extra = [_]std.http.Header{
        .{ .name = "accept", .value = "application/vnd.github+json" },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };

    // Call client wrapper
    const raw = client.httpRequest(allocator, .GET, COPILOT_GITHUB_TOKEN_EXCHANGE_ENDPOINT, headers, &extra, null) catch return try allocator.dupe(u8, api_key);
    defer allocator.free(raw);

    const Resp = struct { token: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Resp, allocator, raw, .{ .ignore_unknown_fields = true }) catch return try allocator.dupe(u8, api_key);
    defer parsed.deinit();

    if (parsed.value.token) |t| return allocator.dupe(u8, t);
    return allocator.dupe(u8, api_key);
}

pub fn appendCopilotHeaders(allocator: std.mem.Allocator, list: *std.ArrayList(std.http.Header)) !void {
    try list.append(allocator, .{ .name = "Editor-Version", .value = COPILOT_EDITOR_VERSION });
    try list.append(allocator, .{ .name = "Editor-Plugin-Version", .value = COPILOT_EDITOR_PLUGIN_VERSION });
    try list.append(allocator, .{ .name = "x-initiator", .value = "agent" });
    try list.append(allocator, .{ .name = "Openai-Intent", .value = "conversation-edits" });
}
