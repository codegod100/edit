const std = @import("std");
const pm = @import("provider_manager.zig");
const store = @import("provider_store.zig");
const ai_bridge = @import("ai_bridge.zig");
const utils = @import("utils.zig");
const auth = @import("auth.zig");
const context = @import("context.zig");

pub const OwnedModelSelection = struct {
    provider_id: []const u8,
    model_id: []const u8,

    pub fn deinit(self: OwnedModelSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model_id);
    }
};

pub const ModelSelection = struct {
    provider_id: []const u8,
    model_id: []const u8,
};

pub const ModelOption = struct {
    provider_id: []const u8,
    model_id: []const u8,
    display_name: []const u8,
};

pub fn defaultProviderSpecs() []const pm.ProviderSpec {
    return &.{
        .{
            .id = "anthropic",
            .display_name = "Anthropic",
            .env_vars = &.{"ANTHROPIC_API_KEY"},
            .models = &.{
                .{ .id = "claude-sonnet-4", .display_name = "Claude Sonnet 4" },
                .{ .id = "claude-haiku-4.5", .display_name = "Claude Haiku 4.5" },
            },
        },
        .{
            .id = "openai",
            .display_name = "OpenAI",
            .env_vars = &.{"OPENAI_API_KEY"},
            .models = &.{
                .{ .id = "gpt-5", .display_name = "GPT-5" },
                .{ .id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
            },
        },
        .{
            .id = "google",
            .display_name = "Google",
            .env_vars = &.{"GOOGLE_GENERATIVE_AI_API_KEY"},
            .models = &.{
                .{ .id = "gemini-2.5-pro", .display_name = "Gemini 2.5 Pro" },
                .{ .id = "gemini-2.5-flash", .display_name = "Gemini 2.5 Flash" },
            },
        },
        .{
            .id = "openrouter",
            .display_name = "OpenRouter",
            .env_vars = &.{"OPENROUTER_API_KEY"},
            .models = &.{
                .{ .id = "anthropic/claude-3.5-sonnet", .display_name = "Claude 3.5 Sonnet" },
                .{ .id = "google/gemini-2.0-flash-001", .display_name = "Gemini 2.0 Flash" },
                .{ .id = "minimax/minimax-m2.5", .display_name = "MiniMax M2.5" },
            },
        },
        .{
            .id = "opencode",
            .display_name = "OpenCode",
            .env_vars = &.{"OPENCODE_API_KEY"},
            .models = &.{
                .{ .id = "kimi-k2.5", .display_name = "Kimi K2.5" },
            },
        },
    };
}

pub fn envPairsForProviders(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    stored: []const store.StoredPair,
) ![]pm.EnvPair {
    var out = try std.ArrayListUnmanaged(pm.EnvPair).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (providers) |provider| {
        // Always include opencode even without API key (free tier uses "public")
        const is_opencode = std.mem.eql(u8, provider.id, "opencode");
        var found_any = false;

        for (provider.env_vars) |name| {
            for (stored) |pair| {
                if (std.mem.eql(u8, pair.name, name)) {
                    try out.append(allocator, .{ .name = pair.name, .value = pair.value });
                    found_any = true;
                }
            }
            const value = std.posix.getenv(name) orelse continue;
            try out.append(allocator, .{ .name = name, .value = value });
            found_any = true;
        }

        // For opencode, add a placeholder if no key found so it passes through
        if (is_opencode and !found_any and provider.env_vars.len > 0) {
            try out.append(allocator, .{ .name = provider.env_vars[0], .value = "" });
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn resolveProviderStates(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    stored: []const store.StoredPair,
) ![]pm.ProviderState {
    const env_pairs = try envPairsForProviders(allocator, providers, stored);
    defer allocator.free(env_pairs);
    return pm.ProviderManager.resolve(allocator, providers, env_pairs, .{});
}

pub fn isConnected(provider_id: []const u8, connected: []const pm.ProviderState) bool {
    for (connected) |item| {
        if (std.mem.eql(u8, item.id, provider_id)) return true;
    }
    return false;
}

pub fn findConnectedProvider(connected: []const pm.ProviderState, provider_id: []const u8) ?pm.ProviderState {
    for (connected) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

pub fn findProviderSpecByID(providers: []const pm.ProviderSpec, provider_id: []const u8) ?pm.ProviderSpec {
    for (providers) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

pub fn providerHasModel(providers: []const pm.ProviderSpec, provider_id: []const u8, model_id: []const u8) bool {
    // OpenRouter is an aggregator and its model catalog changes frequently; don't hard-fail on
    // stale local catalogs. `/model` already does an optional live check for OpenRouter.
    if (std.mem.eql(u8, provider_id, "openrouter")) return true;
    const provider = findProviderSpecByID(providers, provider_id) orelse return false;
    for (provider.models) |model| {
        if (std.mem.eql(u8, model.id, model_id)) return true;
    }
    return false;
}

pub fn chooseDefaultModelForConnected(provider: pm.ProviderState) ?[]const u8 {
    if (std.mem.eql(u8, provider.id, "openai") and provider.key != null and auth.isLikelyOAuthToken(provider.key.?)) {
        // Subscription/OAuth token uses the Codex backend: default to a Codex model.
        var best: ?[]const u8 = null;
        for (provider.models) |m| {
            if (!utils.isCodexModelId(m.id)) continue;
            // Prefer newer/larger by simple lexical bias, falling back to first match.
            if (best == null) best = m.id else if (std.mem.lessThan(u8, best.?, m.id)) best = m.id;
        }
        if (best) |b| return b;
        // No codex model found - return first available model for OAuth fallback
        if (provider.models.len > 0) return provider.models[0].id;
        return null;
    }
    return pm.ProviderManager.defaultModelIDForProvider(provider.id, provider.models);
}

const config_store = @import("config_store.zig");

pub fn chooseActiveModel(
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
    selected: ?config_store.SelectedModel,
    reasoning_effort: ?[]const u8,
) ?context.ActiveModel {
    if (selected) |sel| {
        const provider = findConnectedProvider(connected, sel.provider_id);
        if (!providerHasModel(providers, sel.provider_id, sel.model_id)) return null;
        if (std.mem.eql(u8, sel.provider_id, "openai") and provider != null and provider.?.key != null and auth.isLikelyOAuthToken(provider.?.key.?)) {
            if (!utils.isCodexModelId(sel.model_id)) return null;
        }
        return .{
            .provider_id = sel.provider_id,
            .model_id = sel.model_id,
            .api_key = if (provider) |p| p.key else null,
            .reasoning_effort = reasoning_effort,
        };
    }

    if (connected.len == 0) return null;
    const provider = connected[0];
    const default_model = chooseDefaultModelForConnected(provider) orelse return null;
    return .{
        .provider_id = provider.id,
        .model_id = default_model,
        .api_key = provider.key,
        .reasoning_effort = reasoning_effort,
    };
}

pub fn collectModelOptions(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
    only_provider_id: ?[]const u8,
) ![]ModelOption {
    var out = try std.ArrayListUnmanaged(ModelOption).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (providers) |spec| {
        if (only_provider_id) |pid| {
            if (!std.mem.eql(u8, spec.id, pid)) continue;
        }
        // Only offer models for providers that are currently connected.
        if (!isConnected(spec.id, connected)) continue;

        // Special case: OpenAI "subscription" auth (OAuth/JWT-ish token) uses the Codex backend, which
        // only supports Codex models. Filter out non-codex models so /model can't select unsupported ids.
        const state = findConnectedProvider(connected, spec.id);
        const openai_oauth = std.mem.eql(u8, spec.id, "openai") and state != null and state.?.key != null and auth.isLikelyOAuthToken(state.?.key.?);
        const copilot_live_allowlist = std.mem.eql(u8, spec.id, "github-copilot") and state != null and state.?.key != null;
        if (openai_oauth or copilot_live_allowlist) {
            // Prefer live allowlist from the provider, but fall back to substring filter on failure.
            var allowed_ids: ?[][]u8 = null;
            if (state.?.key) |k| {
                allowed_ids = ai_bridge.fetchModelIDsDirect(allocator, k, spec.id) catch null;
            }
            defer if (allowed_ids) |ids| ai_bridge.freeModelIDs(allocator, ids);

            if (allowed_ids) |ids| {
                var seen = std.StringHashMap(void).init(allocator);
                defer seen.deinit();

                for (ids) |id| {
                    _ = try seen.put(id, {});
                }

                // Add catalog models that are allowed.
                for (spec.models) |m| {
                    if (seen.contains(m.id)) {
                        try out.append(allocator, .{ .provider_id = spec.id, .model_id = m.id, .display_name = m.display_name });
                        _ = seen.remove(m.id);
                    }
                }

                // Add any allowed models not present in our static catalog.
                var it = seen.keyIterator();
                while (it.next()) |key_ptr| {
                    const id = key_ptr.*;
                    try out.append(allocator, .{ .provider_id = spec.id, .model_id = id, .display_name = id });
                }
                continue;
            } else {
                if (copilot_live_allowlist) {
                    // If Copilot model listing fails, fall back to static catalog.
                    for (spec.models) |m| {
                        try out.append(allocator, .{ .provider_id = spec.id, .model_id = m.id, .display_name = m.display_name });
                    }
                    continue;
                }
                for (spec.models) |m| {
                    if (utils.isCodexModelId(m.id)) {
                        try out.append(allocator, .{ .provider_id = spec.id, .model_id = m.id, .display_name = m.display_name });
                    }
                }
                continue;
            }
        }

        for (spec.models) |m| {
            try out.append(allocator, .{ .provider_id = spec.id, .model_id = m.id, .display_name = m.display_name });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn filterModelOptions(allocator: std.mem.Allocator, options: []const ModelOption, query: []const u8) ![]ModelOption {
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return allocator.dupe(ModelOption, options);

    var out = try std.ArrayListUnmanaged(ModelOption).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (options) |o| {
        if (utils.containsIgnoreCase(o.model_id, q) or utils.containsIgnoreCase(o.display_name, q) or utils.containsIgnoreCase(o.provider_id, q)) {
            try out.append(allocator, o);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn resolveGlobalModelPick(options: []const ModelOption, pick: []const u8) ?ModelOption {
    const n = std.fmt.parseInt(usize, pick, 10) catch null;
    if (n) |idx| {
        if (idx > 0 and idx <= options.len) return options[idx - 1];
    }

    for (options) |m| {
        if (std.mem.eql(u8, m.model_id, pick)) return m;
        if (std.mem.eql(u8, m.provider_id, pick)) return m;
        if (std.mem.eql(u8, m.display_name, pick)) return m;
    }

    for (options) |m| {
        if (std.mem.eql(u8, m.provider_id, pick)) return m;
        if (utils.containsIgnoreCase(m.model_id, pick)) return m;
        if (utils.containsIgnoreCase(m.display_name, pick)) return m;
    }
    return null;
}

pub fn autoPickSingleModel(options: []const ModelOption) ?ModelOption {
    return if (options.len == 1) options[0] else null;
}

pub fn resolveModelPick(models: []const pm.Model, pick: []const u8) ?pm.Model {
    const n = std.fmt.parseInt(usize, pick, 10) catch null;
    if (n) |idx| {
        if (idx > 0 and idx <= models.len) return models[idx - 1];
    }
    for (models) |m| {
        if (std.mem.eql(u8, m.id, pick)) return m;
    }
    return null;
}

pub fn pickBestCopilotModelFallback(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    current_model_id: []const u8,
) !?[]u8 {
    const ids = ai_bridge.fetchModelIDsDirect(allocator, api_key, "github-copilot") catch return null;
    defer ai_bridge.freeModelIDs(allocator, ids);

    const preferred = [_][]const u8{
        "gpt-5.2",
        "gpt-5.1",
        "gpt-5",
        "gpt-5-mini",
        "gpt-5.2-codex",
        "gpt-5.1-codex-max",
        "gpt-5.1-codex",
        "gpt-5.1-codex-mini",
        "gpt-5.3-codex",
    };

    const hasModelID = struct {
        fn check(in_ids: [][]u8, want: []const u8) bool {
            for (in_ids) |id| {
                if (std.mem.eql(u8, id, want)) return true;
            }
            return false;
        }
    }.check;

    for (preferred) |want| {
        if (!std.mem.eql(u8, want, current_model_id) and hasModelID(ids, want)) {
            return try allocator.dupe(u8, want);
        }
    }

    // Last resort: any different model from the live allowlist.
    for (ids) |id| {
        if (!std.mem.eql(u8, id, current_model_id)) {
            return try allocator.dupe(u8, id);
        }
    }

    return null;
}

pub fn chooseProvider(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
    promptLineFn: *const fn (std.mem.Allocator, anytype, anytype, []const u8) anyerror!?[]u8,
) !?pm.ProviderSpec {
    try stdout.print("Connect a provider:\n", .{});
    for (providers, 0..) |provider, idx| {
        const status = if (isConnected(provider.id, connected)) "connected" else "not connected";
        try stdout.print("  {d}) {s} [{s}]\n", .{ idx + 1, provider.display_name, status });
    }
    const choice_opt = try promptLineFn(allocator, stdin, stdout, "Provider number or id: ");
    if (choice_opt == null) return null;
    defer allocator.free(choice_opt.?);
    const choice = std.mem.trim(u8, choice_opt.?, " \t\r\n");
    if (choice.len == 0) return null;

    const parsed_num = std.fmt.parseInt(usize, choice, 10) catch null;
    if (parsed_num) |n| {
        if (n > 0 and n <= providers.len) {
            return providers[n - 1];
        }
    }

    for (providers) |provider| {
        if (std.mem.eql(u8, provider.id, choice)) return provider;
    }

    try stdout.print("Unknown provider: {s}\n", .{choice});
    return null;
}
