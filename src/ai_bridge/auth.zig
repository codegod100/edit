const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");
const errors = @import("errors.zig");

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

    const raw = http.httpRequest(allocator, .GET, types.Constants.COPILOT_GITHUB_TOKEN_EXCHANGE_ENDPOINT, headers, &extra, null) catch return null;
    defer allocator.free(raw);

    const Resp = struct { token: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(Resp, allocator, raw, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const tok = parsed.value.token orelse return null;
    const trimmed = std.mem.trim(u8, tok, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn effectiveCopilotBearerToken(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    // If the configured key is already a JWT-like token, use it directly.
    // Otherwise, treat it as a GitHub OAuth token and exchange it.
    if (isLikelyJwtLike(api_key)) return try allocator.dupe(u8, api_key);
    if (exchangeGitHubTokenForCopilotApiToken(allocator, api_key) catch null) |tok| return tok;
    return try allocator.dupe(u8, api_key);
}

pub fn isOAuthToken(token: []const u8) bool {
    return isLikelyOAuthToken(token);
}
