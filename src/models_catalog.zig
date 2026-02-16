const std = @import("std");
const pm = @import("provider_manager.zig");

pub fn loadProviderSpecs(allocator: std.mem.Allocator, base_path: []const u8) ![]pm.ProviderSpec {
    _ = base_path; // Config path not used for hardcoded providers

    // Hardcode 3 providers: OpenRouter, GitHub Copilot, Z.AI
    var specs = try std.ArrayListUnmanaged(pm.ProviderSpec).initCapacity(allocator, 3);

    // OpenRouter
    {
        const id = try allocator.dupe(u8, "openrouter");
        const display_name = try allocator.dupe(u8, "OpenRouter");
        const env_vars = try allocator.alloc([]const u8, 1);
        env_vars[0] = try allocator.dupe(u8, "OPENROUTER_API_KEY");
        const models = try allocator.alloc(pm.Model, 2);
        models[0] = .{
            .id = try allocator.dupe(u8, "openrouter/anthropic/claude-3.5-sonnet"),
            .display_name = try allocator.dupe(u8, "Claude 3.5 Sonnet"),
        };
        models[1] = .{
            .id = try allocator.dupe(u8, "openrouter/anthropic/claude-3.7-sonnet"),
            .display_name = try allocator.dupe(u8, "Claude 3.7 Sonnet"),
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
        const models = try allocator.alloc(pm.Model, 2);
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
        const models = try allocator.alloc(pm.Model, 1);
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
