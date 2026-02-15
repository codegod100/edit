const std = @import("std");

// Public types
pub const types = @import("types.zig");
pub const ToolCall = types.ToolCall;
pub const ChatResponse = types.ChatResponse;
pub const ProviderConfig = types.ProviderConfig;
pub const Constants = types.Constants;

// Public functions
pub const chat = @import("chat.zig");
pub const models = @import("models.zig");
pub const auth = @import("auth.zig");
pub const errors = @import("errors.zig");
pub const json = @import("json.zig");

// Re-export main functions
pub const chatDirect = chat.chatDirect;
pub const listModelsDirect = models.listModelsDirect;
pub const fetchModelIDsDirect = models.fetchModelIDsDirect;
pub const freeModelIDs = models.freeModelIDs;
pub const getLastProviderError = errors.getLastProviderError;
pub const effectiveCopilotBearerToken = auth.effectiveCopilotBearerToken;

// Re-export error types
pub const ProviderError = errors.ProviderError;
