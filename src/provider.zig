const std = @import("std");
const client = @import("llm/client.zig");

// ============================================================
// Types
// ============================================================

pub const ProviderSpec = struct {
    id: []const u8,
    env_vars: []const []const u8,
    models: []const []const u8,
    // Configuration fields moved here from hardcoded getProviderConfig
    endpoint: []const u8,
    models_endpoint: ?[]const u8 = null,
    referer: ?[]const u8 = null,
    title: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
};

pub const ProviderState = struct {
    id: []const u8,
    key: ?[]const u8,
    connected: bool,
    models: []const []const u8,
};

pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const Options = struct {
    enabled_providers: ?[]const []const u8 = null,
    disabled_providers: []const []const u8 = &.{},
};

pub const ProviderConfig = struct {
    endpoint: []const u8,
    models_endpoint: ?[]const u8,
    referer: ?[]const u8,
    title: ?[]const u8,
    user_agent: ?[]const u8,
};

// Global storage for loaded specs so getProviderConfig can access them
// In a more complex app we'd pass this around, but for now this keeps
// compatibility with the existing pure function signature of getProviderConfig.
var g_provider_specs: ?[]ProviderSpec = null;
var g_specs_allocator: ?std.mem.Allocator = null;

pub fn deinitProviderSpecs() void {
    if (g_specs_allocator) |allocator| {
        if (g_provider_specs) |specs| {
            for (specs) |spec| {
                allocator.free(spec.id);
                for (spec.env_vars) |ev| allocator.free(ev);
                allocator.free(spec.env_vars);
                for (spec.models) |m| {
                    allocator.free(m);
                }
                allocator.free(spec.models);
                allocator.free(spec.endpoint);
                if (spec.models_endpoint) |me| allocator.free(me);
                if (spec.referer) |r| allocator.free(r);
                if (spec.title) |t| allocator.free(t);
                if (spec.user_agent) |ua| allocator.free(ua);
            }
            allocator.free(specs);
        }
    }
    g_provider_specs = null;
}

// ============================================================
// Hardcoded Provider Specs (Fallbacks)
// ============================================================

fn loadDefaultSpecs(allocator: std.mem.Allocator) ![]ProviderSpec {
    var specs = try std.ArrayListUnmanaged(ProviderSpec).initCapacity(allocator, 5);

    // OpenAI
    try specs.append(allocator, .{
        .id = try allocator.dupe(u8, "openai"),
        .env_vars = blk: {
            const ev = try allocator.alloc([]const u8, 1);
            ev[0] = try allocator.dupe(u8, "OPENAI_API_KEY");
            break :blk ev;
        },
        .models = blk: {
            const m = try allocator.alloc([]const u8, 2);
            m[0] = try allocator.dupe(u8, "gpt-4o");
            m[1] = try allocator.dupe(u8, "o3-mini");
            break :blk m;
        },
        .endpoint = try allocator.dupe(u8, "https://api.openai.com/v1/chat/completions"),
        .models_endpoint = try allocator.dupe(u8, "https://api.openai.com/v1/models"),
    });

    // OpenRouter
    try specs.append(allocator, .{
        .id = try allocator.dupe(u8, "openrouter"),
        .env_vars = blk: {
            const ev = try allocator.alloc([]const u8, 1);
            ev[0] = try allocator.dupe(u8, "OPENROUTER_API_KEY");
            break :blk ev;
        },
        .models = blk: {
            const m = try allocator.alloc([]const u8, 6);
            m[0] = try allocator.dupe(u8, "openrouter/anthropic/claude-3.5-sonnet");
            m[1] = try allocator.dupe(u8, "openrouter/anthropic/claude-3.7-sonnet");
            m[2] = try allocator.dupe(u8, "deepseek/deepseek-chat");
            m[3] = try allocator.dupe(u8, "deepseek/deepseek-r1");
            m[4] = try allocator.dupe(u8, "x-ai/grok-4.1-fast");
            m[5] = try allocator.dupe(u8, "openai/gpt-oss-120b");
            break :blk m;
        },
        .endpoint = try allocator.dupe(u8, "https://openrouter.ai/api/v1/chat/completions"),
        .models_endpoint = try allocator.dupe(u8, "https://openrouter.ai/api/v1/models"),
        .referer = try allocator.dupe(u8, "https://zagent.local/"),
        .title = try allocator.dupe(u8, "zagent"),
    });

    // Z.AI
    try specs.append(allocator, .{
        .id = try allocator.dupe(u8, "zai"),
        .env_vars = blk: {
            const ev = try allocator.alloc([]const u8, 1);
            ev[0] = try allocator.dupe(u8, "ZAI_API_KEY");
            break :blk ev;
        },
        .models = blk: {
            const m = try allocator.alloc([]const u8, 1);
            m[0] = try allocator.dupe(u8, "glm-4.7");
            break :blk m;
        },
        .endpoint = try allocator.dupe(u8, "https://api.z.ai/api/coding/paas/v4/chat/completions"),
        .models_endpoint = try allocator.dupe(u8, "https://api.z.ai/api/coding/paas/v4/models"),
        .referer = try allocator.dupe(u8, "https://z.ai/"),
        .title = try allocator.dupe(u8, "zagent"),
        .user_agent = try allocator.dupe(u8, "zagent/0.1"),
    });

    return specs.toOwnedSlice(allocator);
}

// ============================================================
// Provider Config (JSON loading)
// ============================================================

pub fn loadProviderSpecs(allocator: std.mem.Allocator, config_dir: []const u8) ![]ProviderSpec {
    const settings_path = try std.fs.path.join(allocator, &.{ config_dir, "settings.json" });
    defer allocator.free(settings_path);

    const file = std.fs.openFileAbsolute(settings_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const specs = try loadDefaultSpecs(allocator);
            g_provider_specs = specs;
            g_specs_allocator = allocator;
            return specs;
        },
        else => return err,
    };
    defer file.close();

    const text = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(text);

    const Json = struct {
        providers: []struct {
            id: []const u8,
            env_vars: []const []const u8,
            endpoint: []const u8,
            models_endpoint: ?[]const u8 = null,
            referer: ?[]const u8 = null,
            title: ?[]const u8 = null,
            user_agent: ?[]const u8 = null,
            models: []const []const u8,
        },
    };

    var parsed = try std.json.parseFromSlice(Json, allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var specs = try std.ArrayListUnmanaged(ProviderSpec).initCapacity(allocator, parsed.value.providers.len);
    for (parsed.value.providers) |p| {
        const env_vars = try allocator.alloc([]const u8, p.env_vars.len);
        for (p.env_vars, 0..) |ev, i| env_vars[i] = try allocator.dupe(u8, ev);

        const models = try allocator.alloc([]const u8, p.models.len);
        for (p.models, 0..) |m, i| models[i] = try allocator.dupe(u8, m);

        const spec = ProviderSpec{
            .id = try allocator.dupe(u8, p.id),
            .env_vars = env_vars,
            .models = models,
            .endpoint = try allocator.dupe(u8, p.endpoint),
            .models_endpoint = if (p.models_endpoint) |me| try allocator.dupe(u8, me) else null,
            .referer = if (p.referer) |r| try allocator.dupe(u8, r) else null,
            .title = if (p.title) |t| try allocator.dupe(u8, t) else null,
            .user_agent = if (p.user_agent) |ua| try allocator.dupe(u8, ua) else null,
        };
        try specs.append(allocator, spec);
    }

    const final_specs = try specs.toOwnedSlice(allocator);
    g_provider_specs = final_specs;
    g_specs_allocator = allocator;
    return final_specs;
}

pub fn getProviderConfig(provider_id: []const u8) ProviderConfig {
    if (g_provider_specs) |specs| {
        for (specs) |spec| {
            if (std.mem.eql(u8, spec.id, provider_id)) {
                return .{
                    .endpoint = spec.endpoint,
                    .models_endpoint = spec.models_endpoint,
                    .referer = spec.referer,
                    .title = spec.title,
                    .user_agent = spec.user_agent,
                };
            }
        }
    }
    
    // Hardcoded fallbacks if nothing loaded or found (unlikely in practice)
    return .{
        .endpoint = "https://api.openai.com/v1/chat/completions",
        .models_endpoint = "https://api.openai.com/v1/models",
        .referer = null,
        .title = null,
        .user_agent = null,
    };
}

// ============================================================
// Provider State Resolution
// ============================================================

pub fn resolveProviderStates(
    allocator: std.mem.Allocator,
    specs: []const ProviderSpec,
    env: []const EnvPair,
    options: Options,
) ![]ProviderState {
    var out = try std.ArrayListUnmanaged(ProviderState).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (specs) |spec| {
        if (!isAllowed(spec.id, options)) continue;

        const found_value = findEnvValue(spec.env_vars, env);
        if (found_value == null) continue;

        const single_key = if (spec.env_vars.len == 1) found_value else null;
        try out.append(allocator, .{
            .id = spec.id,
            .key = single_key,
            .connected = true,
            .models = spec.models,
        });
    }

    return out.toOwnedSlice(allocator);
}

fn isAllowed(provider_id: []const u8, options: Options) bool {
    if (options.enabled_providers) |enabled| {
        if (!containsString(enabled, provider_id)) return false;
    }
    if (containsString(options.disabled_providers, provider_id)) return false;
    return true;
}

fn containsString(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn findEnvValue(names: []const []const u8, env: []const EnvPair) ?[]const u8 {
    for (names) |name| {
        for (env) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                if (pair.value.len > 0) return pair.value;
            }
        }
    }
    return null;
}

// ============================================================
// Default Model Selection
// ============================================================

pub fn defaultModelIDForProvider(provider_id: []const u8, models: []const []const u8) ?[]const u8 {
    const openai_priority = [_][]const u8{ "gpt-5-nano", "gpt-5-mini", "gpt-4o-mini" };
    const anthropic_priority = [_][]const u8{ "haiku", "sonnet" };
    const generic_priority = [_][]const u8{ "haiku", "flash", "nano", "mini" };

    const priority: []const []const u8 = if (std.mem.eql(u8, provider_id, "openai"))
        openai_priority[0..]
    else if (std.mem.eql(u8, provider_id, "anthropic"))
        anthropic_priority[0..]
    else
        generic_priority[0..];

    for (priority) |needle| {
        for (models) |model_id| {
            if (std.mem.indexOf(u8, model_id, needle) != null) return model_id;
        }
    }

    if (models.len > 0) return models[0];
    return null;
}

// ============================================================
// Copilot Token Handling
// ============================================================

pub const COPILOT_GITHUB_TOKEN_EXCHANGE_ENDPOINT = "https://api.github.com/copilot_internal/v2/token";
pub const COPILOT_EDITOR_VERSION = "vscode/1.85.0";
pub const COPILOT_EDITOR_PLUGIN_VERSION = "github-copilot-chat/0.23.0";

pub fn isLikelyOAuthToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "sk-")) return false;
    return std.mem.count(u8, token, ".") >= 2;
}

pub fn effectiveCopilotBearerToken(allocator: std.mem.Allocator, api_key: []const u8) ![]u8 {
    if (isLikelyOAuthToken(api_key)) return try allocator.dupe(u8, api_key);

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
