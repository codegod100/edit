const std = @import("std");

pub const QueryError = error{
    MissingApiKey,
    UnsupportedProvider,
    EmptyModelResponse,
    Cancelled,
    ModelResponseParseError,
    ModelResponseMissingChoices,
    ModelProviderError,
    OutOfMemory,
    ThreadPanic,
    InvalidUri,
};

pub const ToolRouteDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

// Legacy type for router
pub const ToolRouteCall = struct {
    tool: []u8,
    arguments_json: []u8,

    pub fn deinit(self: ToolRouteCall, allocator: std.mem.Allocator) void {
        allocator.free(self.tool);
        allocator.free(self.arguments_json);
    }
};

pub const ToolRouteResult = struct {
    call: ToolRouteCall,
    thinking: ?[]const u8,

    pub fn deinit(self: ToolRouteResult, allocator: std.mem.Allocator) void {
        self.call.deinit(allocator);
        if (self.thinking) |t| allocator.free(t);
    }
};

// Types for chat
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
