const types = @import("types.zig");

pub fn getProviderConfig(provider_id: []const u8) types.ProviderConfig {
    if (std.mem.eql(u8, provider_id, "openai")) {
        return .{
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .models_endpoint = "https://api.openai.com/v1/models",
            .referer = null,
            .title = null,
            .user_agent = null,
        };
    } else if (std.mem.eql(u8, provider_id, "opencode")) {
        return .{
            .endpoint = "https://opencode.ai/zen/v1/chat/completions",
            .models_endpoint = "https://opencode.ai/zen/v1/models",
            .referer = "https://opencode.ai/",
            .title = "opencode",
            .user_agent = "opencode/0.1.0 (linux; x86_64)",
        };
    } else if (std.mem.eql(u8, provider_id, "openrouter")) {
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
    } else {
        return .{
            .endpoint = "https://api.openai.com/v1/chat/completions",
            .models_endpoint = "https://api.openai.com/v1/models",
            .referer = null,
            .title = null,
            .user_agent = null,
        };
    }
}

const std = @import("std");
