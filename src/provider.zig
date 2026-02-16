const std = @import("std");
const client = @import("llm/client.zig");

// ============================================================
// Types
// ============================================================

pub const Model = struct {
    id: []const u8,
    display_name: []const u8,
};

pub const ProviderSpec = struct {
    id: []const u8,
    display_name: []const u8,
    env_vars: []const []const u8,
    models: []const Model,
};

pub const ProviderState = struct {
    id: []const u8,
    display_name: []const u8,
    key: ?[]const u8,
    connected: bool,
    models: []const Model,
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

// ============================================================
// Hardcoded Provider Specs (3 providers)
// ============================================================

pub fn loadProviderSpecs(allocator: std.mem.Allocator) ![]ProviderSpec {
    var specs = try std.ArrayListUnmanaged(ProviderSpec).initCapacity(allocator, 5);

    // OpenAI
    {
        const id = try allocator.dupe(u8, "openai");
        const display_name = try allocator.dupe(u8, "OpenAI");
        const env_vars = try allocator.alloc([]const u8, 1);
        env_vars[0] = try allocator.dupe(u8, "OPENAI_API_KEY");
        const models = try allocator.alloc(Model, 2);
        models[0] = .{
            .id = try allocator.dupe(u8, "gpt-4o"),
            .display_name = try allocator.dupe(u8, "GPT-4o"),
        };
        models[1] = .{
            .id = try allocator.dupe(u8, "o3-mini"),
            .display_name = try allocator.dupe(u8, "o3-mini"),
        };
        try specs.append(allocator, .{
            .id = id,
            .display_name = display_name,
            .env_vars = env_vars,
            .models = models,
        });
    }

    // OpenCode
    {
        const id = try allocator.dupe(u8, "opencode");
        const display_name = try allocator.dupe(u8, "OpenCode");
        const env_vars = try allocator.alloc([]const u8, 1);
        env_vars[0] = try allocator.dupe(u8, "OPENCODE_API_KEY");
        const models = try allocator.alloc(Model, 1);
        models[0] = .{
            .id = try allocator.dupe(u8, "kimi-k2.5"),
            .display_name = try allocator.dupe(u8, "Kimi K2.5"),
        };
        try specs.append(allocator, .{
            .id = id,
            .display_name = display_name,
            .env_vars = env_vars,
            .models = models,
        });
    }

    // OpenRouter
    {
        const id = try allocator.dupe(u8, "openrouter");
        const display_name = try allocator.dupe(u8, "OpenRouter");
        const env_vars = try allocator.alloc([]const u8, 1);
        env_vars[0] = try allocator.dupe(u8, "OPENROUTER_API_KEY");
        const models = try allocator.alloc(Model, 5);
        models[0] = .{
            .id = try allocator.dupe(u8, "openrouter/anthropic/claude-3.5-sonnet"),
            .display_name = try allocator.dupe(u8, "Claude 3.5 Sonnet"),
        };
        models[1] = .{
            .id = try allocator.dupe(u8, "openrouter/anthropic/claude-3.7-sonnet"),
            .display_name = try allocator.dupe(u8, "Claude 3.7 Sonnet"),
        };
        models[2] = .{
            .id = try allocator.dupe(u8, "deepseek/deepseek-chat"),
            .display_name = try allocator.dupe(u8, "DeepSeek V3"),
        };
        models[3] = .{
            .id = try allocator.dupe(u8, "deepseek/deepseek-r1"),
            .display_name = try allocator.dupe(u8, "DeepSeek R1"),
        };
        models[4] = .{
            .id = try allocator.dupe(u8, "x-ai/grok-4.1-fast"),
            .display_name = try allocator.dupe(u8, "Grok 4.1 Fast"),
        };
        try specs.append(allocator, .{
            .id = id,
            .display_name = display_name,
            .env_vars = env_vars,
            .models = models,
        });
    }

    // GitHub Copilot
    {
        const id = try allocator.dupe(u8, "github-copilot");
        const display_name = try allocator.dupe(u8, "GitHub Copilot");
        const env_vars = try allocator.alloc([]const u8, 1);
        env_vars[0] = try allocator.dupe(u8, "GITHUB_TOKEN");
        const models = try allocator.alloc(Model, 2);
        models[0] = .{
            .id = try allocator.dupe(u8, "github-copilot/gpt-4o"),
            .display_name = try allocator.dupe(u8, "GPT-4o"),
        };
        models[1] = .{
            .id = try allocator.dupe(u8, "github-copilot/gpt-4.1"),
            .display_name = try allocator.dupe(u8, "GPT-4.1"),
        };
        try specs.append(allocator, .{
            .id = id,
            .display_name = display_name,
            .env_vars = env_vars,
            .models = models,
        });
    }

    // Z.AI
    {
        const id = try allocator.dupe(u8, "zai");
        const display_name = try allocator.dupe(u8, "Z.AI");
        const env_vars = try allocator.alloc([]const u8, 1);
        env_vars[0] = try allocator.dupe(u8, "ZAI_API_KEY");
        const models = try allocator.alloc(Model, 1);
        models[0] = .{
            .id = try allocator.dupe(u8, "glm-4.7"),
            .display_name = try allocator.dupe(u8, "GLM-4.7"),
        };
        try specs.append(allocator, .{
            .id = id,
            .display_name = display_name,
            .env_vars = env_vars,
            .models = models,
        });
    }

    return specs.toOwnedSlice(allocator);
}

// ============================================================
// Provider Config (endpoints)
// ============================================================

pub fn getProviderConfig(provider_id: []const u8) ProviderConfig {
    if (std.mem.eql(u8, provider_id, "openrouter")) {
        return .{
            .endpoint = "https://openrouter.ai/api/v1/chat/completions",
            .models_endpoint = "https://openrouter.ai/api/v1/models",
            .referer = "https://zagent.local/",
            .title = "zagent",
            .user_agent = null,
        };
    } else if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return .{
            .endpoint = "https://api.githubcopilot.com/chat/completions",
            .models_endpoint = "https://api.githubcopilot.com/models",
            .referer = null,
            .title = null,
            .user_agent = "zagent/0.1",
        };
    } else if (std.mem.eql(u8, provider_id, "zai")) {
        return .{
            .endpoint = "https://api.z.ai/api/coding/paas/v4/chat/completions",
            .models_endpoint = "https://api.z.ai/api/coding/paas/v4/models",
            .referer = "https://z.ai/",
            .title = "zagent",
            .user_agent = "zagent/0.1",
        };
    } else if (std.mem.eql(u8, provider_id, "opencode")) {
        return .{
            .endpoint = "https://opencode.ai/zen/v1/chat/completions",
            .models_endpoint = "https://opencode.ai/zen/v1/models",
            .referer = "https://opencode.ai/",
            .title = "opencode",
            .user_agent = "opencode/0.1.0 (linux; x86_64)",
        };
    }
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
            .display_name = spec.display_name,
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

pub fn defaultModelIDForProvider(provider_id: []const u8, models: []const Model) ?[]const u8 {
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
        for (models) |model| {
            if (std.mem.indexOf(u8, model.id, needle) != null) return model.id;
        }
    }

    if (models.len > 0) return models[0].id;
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
