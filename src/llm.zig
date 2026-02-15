const std = @import("std");

pub const client = @import("llm/client.zig");
pub const types = @import("llm/types.zig");
pub const chat_module = @import("llm/chat.zig");
pub const models_module = @import("llm/models.zig");
pub const providers = @import("llm/providers.zig");

// Re-export types
pub const ToolRouteDef = types.ToolRouteDef;
pub const ToolCall = types.ToolCall;
pub const ChatResponse = types.ChatResponse;
pub const ToolRouteCall = types.ToolRouteCall;
pub const ToolRouteResult = types.ToolRouteResult;
pub const QueryError = types.QueryError;

// Re-export functions
pub const chat = chat_module.chat;
pub const query = chat_module.query;
pub const inferToolCall = chat_module.inferToolCall;
pub const inferToolCallWithThinking = chat_module.inferToolCallWithThinking;
pub const getLastProviderError = chat_module.getLastProviderError;
pub const fetchModelIDs = models_module.fetchModelIDs;
pub const freeModelIDs = models_module.freeModelIDs;
pub const getProviderConfig = providers.getProviderConfig;
