const std = @import("std");
const ai_bridge = @import("ai_bridge.zig");
const pm = @import("provider.zig");
const store = @import("provider_store.zig");

pub const CODEX_AUTH_PRIMARY_REL_PATH = ".codex/auth.json";
pub const CODEX_AUTH_LEGACY_REL_PATH = ".codex/copilot_auth.json";

pub const AuthMethod = enum {
    api,
    subscription,
};

pub const OPENAI_ISSUER = "https://auth.openai.com";
pub const OPENAI_CLIENT_ID = "pdlLIX2Y72MIl2rhLhTE9VV9bN81JgG7";
pub const GITHUB_DEVICE_CODE_URL = "https://github.com/login/device/code";
pub const GITHUB_DEVICE_TOKEN_URL = "https://github.com/login/oauth/access_token";
pub const GITHUB_DEVICE_CLIENT_ID = "Iv1.b507a08c87ecfe98";
pub const GITHUB_DEVICE_SCOPE = "read:user";
pub const GITHUB_DEVICE_VERIFY_URL = "https://github.com/login/device";

fn codexAuthPathAlloc(allocator: std.mem.Allocator, rel_path: []const u8) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.MissingHome;
    return std.fs.path.join(allocator, &.{ home, rel_path });
}

pub fn readCodexAuthToken(allocator: std.mem.Allocator) !?[]u8 {
    const paths = [_][]const u8{ CODEX_AUTH_PRIMARY_REL_PATH, CODEX_AUTH_LEGACY_REL_PATH };

    for (paths) |rel_path| {
        const path = codexAuthPathAlloc(allocator, rel_path) catch continue;
        defer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 128 * 1024);
        defer allocator.free(data);

        // Primary Codex format: { "tokens": { "access_token": "..." } }
        const Primary = struct {
            tokens: ?struct {
                access_token: ?[]const u8 = null,
            } = null,
            access_token: ?[]const u8 = null,
        };
        if (std.json.parseFromSlice(Primary, allocator, data, .{ .ignore_unknown_fields = true })) |parsed| {
            defer parsed.deinit();
            if (parsed.value.tokens) |t| {
                if (t.access_token) |tok| {
                    const trimmed = std.mem.trim(u8, tok, " \t\r\n");
                    if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
                }
            }
            if (parsed.value.access_token) |tok| {
                const trimmed = std.mem.trim(u8, tok, " \t\r\n");
                if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
            }
        } else |_| {}

        // Legacy fallback: { "token": "..." }
        const Legacy = struct {
            token: ?[]const u8 = null,
            access_token: ?[]const u8 = null,
        };
        if (std.json.parseFromSlice(Legacy, allocator, data, .{ .ignore_unknown_fields = true })) |parsed_legacy| {
            defer parsed_legacy.deinit();
            const token = parsed_legacy.value.token orelse parsed_legacy.value.access_token orelse continue;
            const trimmed = std.mem.trim(u8, token, " \t\r\n");
            if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
        } else |_| {}
    }

    return null;
}

pub fn writeCodexAuthToken(allocator: std.mem.Allocator, token: []const u8) !void {
    const trimmed = std.mem.trim(u8, token, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToken;

    const path = try codexAuthPathAlloc(allocator, CODEX_AUTH_LEGACY_REL_PATH);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    var tmp = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
    defer tmp.close();

    const payload = try std.fmt.allocPrint(allocator, "{{\n  \"token\": {f}\n}}\n", .{std.json.fmt(trimmed, .{})});
    defer allocator.free(payload);

    try tmp.writeAll(payload);
    try tmp.sync();

    try std.fs.renameAbsolute(tmp_path, path);
}

pub fn supportsSubscription(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "openai") or std.mem.eql(u8, provider_id, "github-copilot");
}

pub fn chooseAuthMethod(input: []const u8, allow_subscription: bool) AuthMethod {
    if (!allow_subscription) return .api;
    if (std.mem.eql(u8, input, "subscription") or std.mem.eql(u8, input, "sub") or std.mem.eql(u8, input, "oauth")) {
        return .subscription;
    }
    return .api;
}

pub fn connectSubscription(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    provider_id: []const u8,
    promptLineFn: *const fn (std.mem.Allocator, anytype, anytype, []const u8) anyerror!?[]u8,
) !?[]u8 {
    if (std.mem.eql(u8, provider_id, "openai")) {
        const start = try openaiDeviceStart(allocator);
        defer allocator.free(start.device_auth_id);
        defer allocator.free(start.user_code);

        try stdout.print("Open this URL in your browser: {s}/codex/device\n", .{OPENAI_ISSUER});
        try stdout.print("Enter code: {s}\n", .{start.user_code});
        const open_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "sh", "-c", "xdg-open https://auth.openai.com/codex/device >/dev/null 2>&1 || true" },
        });
        allocator.free(open_result.stdout);
        allocator.free(open_result.stderr);

        const proceed = try promptLineFn(allocator, stdin, stdout, "Press Enter after authorization (or type cancel): ");
        if (proceed) |p| {
            defer allocator.free(p);
            const t = std.mem.trim(u8, p, " \t\r\n");
            if (std.mem.eql(u8, t, "cancel")) return null;
        }

        const token = try openaiPollAndExchange(allocator, stdout, start.device_auth_id, start.user_code, start.interval_sec);
        if (token == null) {
            try stdout.print("Subscription login failed.\n", .{});
            return null;
        }
        return token;
    }

    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        const start = try githubDeviceStart(allocator);
        defer allocator.free(start.device_code);
        defer allocator.free(start.user_code);
        defer allocator.free(start.verification_uri);

        try stdout.print("To sign in to GitHub Copilot:\n", .{});
        try stdout.print("1. Open: {s}\n", .{start.verification_uri});
        try stdout.print("2. Enter code: {s}\n", .{start.user_code});
        const open_cmd = try std.fmt.allocPrint(
            allocator,
            "xdg-open {s} >/dev/null 2>&1 || true",
            .{start.verification_uri},
        );
        defer allocator.free(open_cmd);
        const open_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "sh", "-c", open_cmd },
        });
        allocator.free(open_result.stdout);
        allocator.free(open_result.stderr);

        try stdout.print("Waiting for authorization...\n", .{});
        const token = try githubPollAndExchange(
            allocator,
            stdout,
            start.device_code,
            start.interval_sec,
            start.expires_in_sec,
        );
        if (token) |t| {
            try stdout.print("Subscription authorized successfully.\n", .{});
            return t;
        }
        try stdout.print("GitHub OAuth login failed.\n", .{});
        return null;
    }

    try stdout.print("Subscription flow is currently supported only for openai and github-copilot.\n", .{});
    return null;
}

const OpenAIDeviceStart = struct {
    device_auth_id: []u8,
    user_code: []u8,
    interval_sec: u64,
};

const GitHubDeviceStart = struct {
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    interval_sec: u64,
    expires_in_sec: u64,
};

fn githubDeviceStart(allocator: std.mem.Allocator) !GitHubDeviceStart {
    const form = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&scope={s}",
        .{ GITHUB_DEVICE_CLIENT_ID, GITHUB_DEVICE_SCOPE },
    );
    defer allocator.free(form);

    const headers = std.http.Client.Request.Headers{
        .content_type = .{ .override = "application/x-www-form-urlencoded" },
        .user_agent = .{ .override = "zagent/0.1" },
    };
    const extra_headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json" },
    };
    const out = try httpRequest(
        allocator,
        .POST,
        GITHUB_DEVICE_CODE_URL,
        headers,
        &extra_headers,
        form,
    );
    defer allocator.free(out);

    const StartResp = struct {
        device_code: []const u8,
        user_code: []const u8,
        verification_uri: ?[]const u8 = null,
        interval: ?u64 = null,
        expires_in: ?u64 = null,
        @"error": ?[]const u8 = null,
        error_description: ?[]const u8 = null,
    };

    var parsed = try std.json.parseFromSlice(StartResp, allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.@"error" != null) {
        return error.CopilotDeviceAuthFailed;
    }

    return .{
        .device_code = try allocator.dupe(u8, parsed.value.device_code),
        .user_code = try allocator.dupe(u8, parsed.value.user_code),
        .verification_uri = try allocator.dupe(u8, parsed.value.verification_uri orelse GITHUB_DEVICE_VERIFY_URL),
        .interval_sec = parsed.value.interval orelse 5,
        .expires_in_sec = parsed.value.expires_in orelse 900,
    };
}

fn githubPollAndExchange(
    allocator: std.mem.Allocator,
    stdout: anytype,
    device_code: []const u8,
    base_interval_sec: u64,
    expires_in_sec: u64,
) !?[]u8 {
    var interval_sec = if (base_interval_sec == 0) @as(u64, 5) else base_interval_sec;
    const start_ms = std.time.milliTimestamp();
    const max_wait_ms: i64 = @intCast(expires_in_sec * std.time.ms_per_s);

    while ((std.time.milliTimestamp() - start_ms) < max_wait_ms) {
        const form = try std.fmt.allocPrint(
            allocator,
            "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code",
            .{ GITHUB_DEVICE_CLIENT_ID, device_code },
        );
        defer allocator.free(form);

        const headers = std.http.Client.Request.Headers{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = "zagent/0.1" },
        };
        const extra_headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
        };
        const out = try httpRequest(
            allocator,
            .POST,
            GITHUB_DEVICE_TOKEN_URL,
            headers,
            &extra_headers,
            form,
        );
        defer allocator.free(out);

        const TokenResp = struct {
            access_token: ?[]const u8 = null,
            @"error": ?[]const u8 = null,
            error_description: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(TokenResp, allocator, out, .{ .ignore_unknown_fields = true }) catch {
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        };
        defer parsed.deinit();

        if (parsed.value.access_token) |token| {
            return try allocator.dupe(u8, token);
        }

        const err_code = parsed.value.@"error" orelse "";
        if (std.mem.eql(u8, err_code, "authorization_pending")) {
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        }
        if (std.mem.eql(u8, err_code, "slow_down")) {
            interval_sec += 5;
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        }
        if (std.mem.eql(u8, err_code, "expired_token")) {
            try stdout.print("Copilot device code expired. Run /connect github-copilot again.\n", .{});
            return null;
        }
        if (std.mem.eql(u8, err_code, "access_denied")) {
            try stdout.print("Copilot authorization was denied.\n", .{});
            return null;
        }
        if (err_code.len > 0) {
            const detail = parsed.value.error_description orelse "no details";
            try stdout.print("Copilot authorization failed: {s} ({s})\n", .{ err_code, detail });
            return null;
        }

        try stdout.print("Copilot token response did not include an access token.\n", .{});
        return null;
    }

    try stdout.print("Copilot device authorization timed out.\n", .{});
    return null;
}

fn openaiDeviceStart(allocator: std.mem.Allocator) !OpenAIDeviceStart {
    const body = try std.fmt.allocPrint(allocator, "{{\"client_id\":\"{s}\"}}", .{OPENAI_CLIENT_ID});
    defer allocator.free(body);

    const headers = std.http.Client.Request.Headers{
        .content_type = .{ .override = "application/json" },
        .user_agent = .{ .override = "zagent/0.1" },
    };
    const out = try httpRequest(
        allocator,
        .POST,
        OPENAI_ISSUER ++ "/api/accounts/deviceauth/usercode",
        headers,
        &.{},
        body,
    );
    defer allocator.free(out);

    const StartResp = struct {
        device_auth_id: []const u8,
        user_code: []const u8,
        interval: ?[]const u8 = null,
    };
    var parsed = try std.json.parseFromSlice(StartResp, allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const interval = if (parsed.value.interval) |s| std.fmt.parseInt(u64, s, 10) catch 5 else 5;
    return .{
        .device_auth_id = try allocator.dupe(u8, parsed.value.device_auth_id),
        .user_code = try allocator.dupe(u8, parsed.value.user_code),
        .interval_sec = if (interval == 0) 5 else interval,
    };
}

fn openaiPollAndExchange(
    allocator: std.mem.Allocator,
    stdout: anytype,
    device_auth_id: []const u8,
    user_code: []const u8,
    interval_sec: u64,
) !?[]u8 {
    var tries: usize = 0;
    while (tries < 120) : (tries += 1) {
        const poll_body = try std.fmt.allocPrint(
            allocator,
            "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}",
            .{ device_auth_id, user_code },
        );
        defer allocator.free(poll_body);

        const headers = std.http.Client.Request.Headers{
            .content_type = .{ .override = "application/json" },
            .user_agent = .{ .override = "zagent/0.1" },
        };
        const poll = try httpRequest(
            allocator,
            .POST,
            OPENAI_ISSUER ++ "/api/accounts/deviceauth/token",
            headers,
            &.{},
            poll_body,
        );
        defer allocator.free(poll);

        const PollResp = struct {
            authorization_code: ?[]const u8 = null,
            code_verifier: ?[]const u8 = null,
            @"error": ?[]const u8 = null,
            error_description: ?[]const u8 = null,
            message: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(PollResp, allocator, poll, .{ .ignore_unknown_fields = true }) catch {
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        };
        defer parsed.deinit();

        if (parsed.value.authorization_code == null or parsed.value.code_verifier == null) {
            if (parsed.value.@"error") |err_code| {
                const detail = parsed.value.error_description orelse parsed.value.message orelse "no details";
                if (std.mem.eql(u8, err_code, "authorization_pending")) {
                    std.Thread.sleep(interval_sec * std.time.ns_per_s);
                    continue;
                }
                if (std.mem.eql(u8, err_code, "expired_token")) {
                    try stdout.print("OpenAI device code expired. Run /connect codex again.\n", .{});
                    return null;
                }
                if (std.mem.eql(u8, err_code, "access_denied")) {
                    try stdout.print("OpenAI authorization denied.\n", .{});
                    return null;
                }
                try stdout.print("OpenAI authorization polling failed: {s} ({s})\n", .{ err_code, detail });
                return null;
            }
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        }

        const form = try std.fmt.allocPrint(
            allocator,
            "grant_type=authorization_code&code={s}&redirect_uri={s}/deviceauth/callback&client_id={s}&code_verifier={s}",
            .{ parsed.value.authorization_code.?, OPENAI_ISSUER, OPENAI_CLIENT_ID, parsed.value.code_verifier.? },
        );
        defer allocator.free(form);

        const token_headers = std.http.Client.Request.Headers{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
            .user_agent = .{ .override = "zagent/0.1" },
        };
        const token = try httpRequest(
            allocator,
            .POST,
            OPENAI_ISSUER ++ "/oauth/token",
            token_headers,
            &.{},
            form,
        );
        defer allocator.free(token);

        const TokenResp = struct {
            access_token: ?[]const u8 = null,
            refresh_token: ?[]const u8 = null,
            @"error": ?[]const u8 = null,
            error_description: ?[]const u8 = null,
            message: ?[]const u8 = null,
        };
        var tok = std.json.parseFromSlice(TokenResp, allocator, token, .{ .ignore_unknown_fields = true }) catch {
            const trimmed = std.mem.trim(u8, token, " \t\r\n");
            if (trimmed.len > 0) {
                try stdout.print("OpenAI token exchange returned non-JSON response: {s}\n", .{trimmed});
            }
            return null;
        };
        defer tok.deinit();

        if (tok.value.access_token) |access| {
            try stdout.print("Subscription authorized successfully.\n", .{});
            return try allocator.dupe(u8, access);
        }

        if (tok.value.@"error") |err_code| {
            const detail = tok.value.error_description orelse tok.value.message orelse "no details";
            try stdout.print("OpenAI token exchange failed: {s} ({s})\n", .{ err_code, detail });
            return null;
        }

        try stdout.print("OpenAI token exchange succeeded without an access_token.\n", .{});
        return null;
    }

    return null;
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

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .headers = headers,
        .extra_headers = extra_headers,
        .payload = payload,
        .response_writer = &allocating_writer.writer,
    });

    return try allocating_writer.toOwnedSlice();
}

pub fn isLikelyOAuthToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "sk-")) return false;
    // JWTs usually have 2 dots (header.payload.signature)
    return std.mem.count(u8, token, ".") >= 2;
}
