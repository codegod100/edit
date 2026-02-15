const types = @import("types.zig");

pub fn getProviderConfig(provider_id: []const u8) types.ProviderConfig {
    if (std.mem.eql(u8, provider_id, "openai")) {
        return .{
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .referer = null,
            .title = null,
            .user_agent = null,
        };
    } else if (std.mem.eql(u8, provider_id, "opencode")) {
        return .{
            .endpoint = "https://opencode.ai/zen/v1/chat/completions",
            .referer = "https://opencode.ai/",
            .title = "opencode",
            .user_agent = "opencode/0.1.0 (linux; x86_64)",
        };
    } else if (std.mem.eql(u8, provider_id, "openrouter")) {
        return .{
            .endpoint = "https://openrouter.ai/api/v1/chat/completions",
            .referer = "https://zagent.local/",
            .title = "zagent",
            .user_agent = null,
        };
    } else if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return .{
            .endpoint = "https://api.githubcopilot.com/chat/completions",
            .referer = null,
            .title = null,
            .user_agent = "zagent/0.1",
        };
    } else {
        return .{
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .referer = null,
            .title = null,
            .user_agent = null,
        };
    }
}

pub fn getModelsEndpoint(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) {
        return "https://api.openai.com/v1/models";
    } else if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return "https://api.githubcopilot.com/models";
    } else if (std.mem.eql(u8, provider_id, "opencode")) {
        return "https://opencode.ai/zen/v1/models";
    } else if (std.mem.eql(u8, provider_id, "openrouter")) {
        return "https://openrouter.ai/api/v1/models";
    } else {
        return null;
    }
}

const std = @import("std");
