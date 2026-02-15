const std = @import("std");
const types = @import("types.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const errors = @import("errors.zig");
const logger = @import("../logger.zig");

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
    errors.clearLastProviderError();

    const effective_key = if (std.mem.eql(u8, provider_id, "github-copilot"))
        try auth.effectiveCopilotBearerToken(allocator, api_key)
    else
        try allocator.dupe(u8, api_key);
    defer allocator.free(effective_key);

    const use_codex_models = std.mem.eql(u8, provider_id, "openai") and auth.isOAuthToken(api_key);
    const endpoint = if (use_codex_models)
        types.Constants.OPENAI_CODEX_MODELS_ENDPOINT
    else
        config.getModelsEndpoint(provider_id) orelse {
            errors.setLastProviderError("provider does not support listing models");
            return errors.ProviderError.UnsupportedProvider;
        };

    const cfg = config.getProviderConfig(provider_id);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{effective_key});
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
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        try extra_headers.append(allocator, .{ .name = "accept", .value = "application/json" });
        try extra_headers.append(allocator, .{ .name = "Editor-Version", .value = types.Constants.COPILOT_EDITOR_VERSION });
        try extra_headers.append(allocator, .{ .name = "Editor-Plugin-Version", .value = types.Constants.COPILOT_EDITOR_PLUGIN_VERSION });
        try extra_headers.append(allocator, .{ .name = "x-initiator", .value = "user" });
        try extra_headers.append(allocator, .{ .name = "Openai-Intent", .value = "conversation-edits" });
    }

    const raw = try http.httpRequest(allocator, .GET, endpoint, headers, extra_headers.items, null);
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Models response parse error: {s}; raw prefix: {s}", .{ @errorName(err), prefix });
        errors.setLastProviderError("models response parse error");
        return errors.ProviderError.ModelResponseParseError;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        errors.setLastProviderError("models response is not an object");
        return errors.ProviderError.ModelResponseParseError;
    }

    // Check for error envelope
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

        // Add context for OpenAI permission failure
        if (std.mem.eql(u8, provider_id, "openai")) {
            const msg = fbs.getWritten();
            if (std.mem.indexOf(u8, msg, "Missing scopes") != null and std.mem.indexOf(u8, msg, "api.model.read") != null) {
                if (fbs.pos + 2 < buf.len) {
                    try w.writeAll("; ");
                    try w.writeAll("need api.model.read scope or a project/org role that grants model listing");
                }
            }
        }

        const detail = fbs.getWritten();
        logger.err("Upstream models error: {s}", .{detail});
        errors.setLastProviderError(detail);
        return errors.ProviderError.ModelProviderError;
    }

    const q = std.mem.trim(u8, filter, " \t\r\n");

    var out: std.ArrayList(u8) = .empty;
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
            errors.setLastProviderError("models response missing models");
            return errors.ProviderError.ModelResponseParseError;
        };
        if (models_val != .array) {
            errors.setLastProviderError("models response models is not an array");
            return errors.ProviderError.ModelResponseParseError;
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
            errors.setLastProviderError("models response missing data");
            return errors.ProviderError.ModelResponseParseError;
        };
        if (data_val != .array) {
            errors.setLastProviderError("models response data is not an array");
            return errors.ProviderError.ModelResponseParseError;
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
    errors.clearLastProviderError();

    const effective_key = if (std.mem.eql(u8, provider_id, "github-copilot"))
        try auth.effectiveCopilotBearerToken(allocator, api_key)
    else
        try allocator.dupe(u8, api_key);
    defer allocator.free(effective_key);

    const use_codex_models = std.mem.eql(u8, provider_id, "openai") and auth.isOAuthToken(api_key);
    const endpoint = if (use_codex_models)
        types.Constants.OPENAI_CODEX_MODELS_ENDPOINT
    else
        config.getModelsEndpoint(provider_id) orelse {
            errors.setLastProviderError("provider does not support listing models");
            return errors.ProviderError.UnsupportedProvider;
        };

    const cfg = config.getProviderConfig(provider_id);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{effective_key});
    defer allocator.free(auth_value);

    var headers = std.http.Client.Request.Headers{
        .authorization = .{ .override = auth_value },
        .content_type = .{ .override = "application/json" },
    };
    if (cfg.user_agent) |ua| headers.user_agent = .{ .override = ua };

    var extra_headers: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers.deinit(allocator);
    if (cfg.referer) |r| try extra_headers.append(allocator, .{ .name = "HTTP-Referer", .value = r });
    if (cfg.title) |t| try extra_headers.append(allocator, .{ .name = "X-Title", .value = t });
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        try extra_headers.append(allocator, .{ .name = "accept", .value = "application/json" });
        try extra_headers.append(allocator, .{ .name = "Editor-Version", .value = types.Constants.COPILOT_EDITOR_VERSION });
        try extra_headers.append(allocator, .{ .name = "Editor-Plugin-Version", .value = types.Constants.COPILOT_EDITOR_PLUGIN_VERSION });
        try extra_headers.append(allocator, .{ .name = "x-initiator", .value = "user" });
        try extra_headers.append(allocator, .{ .name = "Openai-Intent", .value = "conversation-edits" });
    }

    const raw = try http.httpRequest(allocator, .GET, endpoint, headers, extra_headers.items, null);
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .ignore_unknown_fields = true }) catch |err| {
        const prefix = if (raw.len > 400) raw[0..400] else raw;
        logger.err("Models response parse error: {s}; raw prefix: {s}", .{ @errorName(err), prefix });
        errors.setLastProviderError("models response parse error");
        return errors.ProviderError.ModelResponseParseError;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        errors.setLastProviderError("models response is not an object");
        return errors.ProviderError.ModelResponseParseError;
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
        errors.setLastProviderError(detail);
        return errors.ProviderError.ModelProviderError;
    }

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }

    if (use_codex_models) {
        const models_val = parsed.value.object.get("models") orelse {
            const prefix = if (raw.len > 300) raw[0..300] else raw;
            logger.err("Codex models response missing models; raw prefix: {s}", .{prefix});
            errors.setLastProviderError("models response missing models");
            return errors.ProviderError.ModelResponseParseError;
        };
        if (models_val != .array) {
            errors.setLastProviderError("models response models is not an array");
            return errors.ProviderError.ModelResponseParseError;
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
            errors.setLastProviderError("models response missing data");
            return errors.ProviderError.ModelResponseParseError;
        };
        if (data_val != .array) {
            errors.setLastProviderError("models response data is not an array");
            return errors.ProviderError.ModelResponseParseError;
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
