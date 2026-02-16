const std = @import("std");

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

    pub fn deinit(self: *ProviderState, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const Options = struct {
    enabled_providers: ?[]const []const u8 = null,
    disabled_providers: []const []const u8 = &.{},
};

pub const ProviderManager = struct {
    pub fn resolve(
        allocator: std.mem.Allocator,
        specs: []const ProviderSpec,
        env: []const EnvPair,
        options: Options,
    ) ![]ProviderState {
        var out = try std.ArrayListUnmanaged(ProviderState).initCapacity(allocator, 0);
        errdefer out.deinit(allocator);

        for (specs) |spec| {
            if (!isAllowed(spec.id, options)) continue;

            // Allow opencode without API key for free tier models
            const is_opencode = std.mem.eql(u8, spec.id, "opencode");
            const found_value = findEnvValue(spec.env_vars, env, is_opencode);
            if (found_value == null and !is_opencode) continue;

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

    pub fn freeResolved(allocator: std.mem.Allocator, states: []ProviderState) void {
        allocator.free(states);
    }

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
};

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

fn findEnvValue(names: []const []const u8, env: []const EnvPair, is_opencode: bool) ?[]const u8 {
    for (names) |name| {
        for (env) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                // For opencode, allow empty value (free tier uses "public" key)
                if (is_opencode or pair.value.len > 0) return pair.value;
            }
        }
    }
    return null;
}

test "resolve loads provider when env key exists" {
    const allocator = std.testing.allocator;
    const specs = [_]ProviderSpec{.{
        .id = "anthropic",
        .display_name = "Anthropic",
        .env_vars = &.{"ANTHROPIC_API_KEY"},
        .models = &.{.{ .id = "claude-sonnet-4", .display_name = "Claude Sonnet 4" }},
    }};
    const env = [_]EnvPair{.{ .name = "ANTHROPIC_API_KEY", .value = "test-key" }};

    const states = try ProviderManager.resolve(allocator, &specs, &env, .{});
    defer ProviderManager.freeResolved(allocator, states);

    try std.testing.expectEqual(@as(usize, 1), states.len);
    try std.testing.expectEqualStrings("anthropic", states[0].id);
    try std.testing.expect(states[0].connected);
    try std.testing.expect(states[0].key != null);
}

test "resolve honors disabled providers" {
    const allocator = std.testing.allocator;
    const specs = [_]ProviderSpec{
        .{ .id = "anthropic", .display_name = "Anthropic", .env_vars = &.{"ANTHROPIC_API_KEY"}, .models = &.{} },
        .{ .id = "openai", .display_name = "OpenAI", .env_vars = &.{"OPENAI_API_KEY"}, .models = &.{} },
    };
    const env = [_]EnvPair{
        .{ .name = "ANTHROPIC_API_KEY", .value = "a" },
        .{ .name = "OPENAI_API_KEY", .value = "o" },
    };

    const states = try ProviderManager.resolve(allocator, &specs, &env, .{
        .disabled_providers = &.{"openai"},
    });
    defer ProviderManager.freeResolved(allocator, states);

    try std.testing.expectEqual(@as(usize, 1), states.len);
    try std.testing.expectEqualStrings("anthropic", states[0].id);
}

test "resolve honors enabled providers allowlist" {
    const allocator = std.testing.allocator;
    const specs = [_]ProviderSpec{
        .{ .id = "anthropic", .display_name = "Anthropic", .env_vars = &.{"ANTHROPIC_API_KEY"}, .models = &.{} },
        .{ .id = "openai", .display_name = "OpenAI", .env_vars = &.{"OPENAI_API_KEY"}, .models = &.{} },
    };
    const env = [_]EnvPair{
        .{ .name = "ANTHROPIC_API_KEY", .value = "a" },
        .{ .name = "OPENAI_API_KEY", .value = "o" },
    };

    const states = try ProviderManager.resolve(allocator, &specs, &env, .{
        .enabled_providers = &.{"openai"},
    });
    defer ProviderManager.freeResolved(allocator, states);

    try std.testing.expectEqual(@as(usize, 1), states.len);
    try std.testing.expectEqualStrings("openai", states[0].id);
}

test "default model prefers known smaller models" {
    const models = [_]Model{
        .{ .id = "gpt-4o", .display_name = "GPT 4o" },
        .{ .id = "gpt-5-nano", .display_name = "GPT 5 Nano" },
        .{ .id = "gpt-5", .display_name = "GPT 5" },
    };

    const selected = ProviderManager.defaultModelIDForProvider("openai", &models);
    try std.testing.expect(selected != null);
    try std.testing.expectEqualStrings("gpt-5-nano", selected.?);
}
