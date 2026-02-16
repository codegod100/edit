const std = @import("std");
const client = @import("client.zig");
const provider = @import("../provider.zig");
const types = @import("types.zig");

pub fn fetchModelIDs(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    provider_id: []const u8,
) ![][]u8 {
    const effective_key = if (std.mem.eql(u8, provider_id, "github-copilot"))
        try provider.effectiveCopilotBearerToken(allocator, api_key)
    else
        try allocator.dupe(u8, api_key);
    defer allocator.free(effective_key);

    const use_codex_models = std.mem.eql(u8, provider_id, "openai") and provider.isLikelyOAuthToken(api_key);
    const endpoint = if (use_codex_models)
        "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0"
    else
        provider.getModelsEndpoint(provider_id) orelse return types.QueryError.UnsupportedProvider;

    const config = provider.getProviderConfig(provider_id);
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{effective_key});
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
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        try provider.appendCopilotHeaders(allocator, &extra_headers);
    }

    const raw = try client.httpRequest(allocator, .GET, endpoint, headers, extra_headers.items, null);
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true }) catch return types.QueryError.ModelResponseParseError;
    defer parsed.deinit();

    if (parsed.value != .object) return types.QueryError.ModelResponseParseError;

    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    if (use_codex_models) {
        const models_val = parsed.value.object.get("models") orelse return types.QueryError.ModelResponseParseError;
        if (models_val != .array) return types.QueryError.ModelResponseParseError;
        for (models_val.array.items) |item| {
            if (item != .object) continue;
            if (item.object.get("slug")) |slug_val| {
                if (slug_val == .string) try out.append(allocator, try allocator.dupe(u8, slug_val.string));
            }
        }
    } else {
        const data_val = parsed.value.object.get("data") orelse return types.QueryError.ModelResponseParseError;
        if (data_val != .array) return types.QueryError.ModelResponseParseError;

        for (data_val.array.items) |item| {
            if (item != .object) continue;
            if (item.object.get("id")) |id_val| {
                if (id_val == .string) try out.append(allocator, try allocator.dupe(u8, id_val.string));
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeModelIDs(allocator: std.mem.Allocator, ids: []const []u8) void {
    for (ids) |s| allocator.free(s);
    allocator.free(ids);
}
