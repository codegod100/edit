const std = @import("std");

pub const ToolCall = struct {
    id: []const u8,
    tool: []const u8,
    args: []const u8,
};

pub const ChatResponse = struct {
    text: []const u8,
    reasoning: []const u8 = "",
    tool_calls: []ToolCall,
    finish_reason: []const u8,

    pub fn deinit(self: ChatResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.reasoning);
        allocator.free(self.finish_reason);
        for (self.tool_calls) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.tool);
            allocator.free(tc.args);
        }
        allocator.free(self.tool_calls);
    }
};

pub const ProviderConfig = struct {
    endpoint: []const u8,
    referer: ?[]const u8,
    title: ?[]const u8,
    user_agent: ?[]const u8,
};

pub const ToolCallIn = struct {
    id: []const u8,
    type: []const u8,
    function: struct {
        name: []const u8,
        arguments: std.json.Value,
    },
};

pub const MessageIn = struct {
    role: []const u8,
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCallIn = null,
    tool_call_id: ?[]const u8 = null,
};

pub const ResponseChoice = struct {
    message: struct {
        content: ?[]const u8 = null,
        reasoning_content: ?[]const u8 = null,
        thinking: ?[]const u8 = null,
        tool_calls: ?[]ToolCallIn = null,
    },
    finish_reason: ?[]const u8 = null,
};

pub const ChatResponseRaw = struct {
    choices: ?[]ResponseChoice = null,
};

pub const ErrorCode = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
};

pub const ErrorEnvelope = struct {
    @"error": ?struct {
        message: ?[]const u8 = null,
        code: ?ErrorCode = null,
        type: ?[]const u8 = null,
        metadata: ?struct {
            provider_name: ?[]const u8 = null,
        } = null,
    } = null,
};

pub const SSEEvent = struct {
    type: ?[]const u8 = null,
    delta: ?[]const u8 = null,
    text: ?[]const u8 = null,
    output_text: ?[]const u8 = null,
    item: ?OutputItem = null,
};

pub const OutputItem = struct {
    type: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

pub const Constants = struct {
    pub const OPENAI_CODEX_RESPONSES_ENDPOINT: []const u8 = "https://chatgpt.com/backend-api/codex/responses";
    pub const COPILOT_RESPONSES_ENDPOINT: []const u8 = "https://api.githubcopilot.com/v1/responses";
    pub const COPILOT_GITHUB_TOKEN_EXCHANGE_ENDPOINT: []const u8 = "https://api.github.com/copilot_internal/v2/token";
    pub const COPILOT_EDITOR_VERSION: []const u8 = "vscode/1.85.0";
    pub const COPILOT_EDITOR_PLUGIN_VERSION: []const u8 = "github-copilot-chat/0.23.0";
    pub const OPENAI_CODEX_MODELS_ENDPOINT: []const u8 = "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0";
};
