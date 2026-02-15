// ai_bridge.zig - Re-export from ai_bridge module
// This file is now a thin wrapper for backward compatibility.
// The actual implementation has been split into the ai_bridge/ directory.

const main = @import("ai_bridge/main.zig");

// Public types
pub const ToolCall = main.ToolCall;
pub const ChatResponse = main.ChatResponse;
pub const ProviderConfig = main.ProviderConfig;
pub const Constants = main.Constants;

// Public functions
pub const chatDirect = main.chatDirect;
pub const listModelsDirect = main.listModelsDirect;
pub const fetchModelIDsDirect = main.fetchModelIDsDirect;
pub const freeModelIDs = main.freeModelIDs;
pub const getLastProviderError = main.getLastProviderError;
pub const effectiveCopilotBearerToken = main.effectiveCopilotBearerToken;

// Error types
pub const ProviderError = main.ProviderError;
