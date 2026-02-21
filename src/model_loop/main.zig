// model_loop/main.zig - Model execution loop module
//
// This module handles the main model execution loop including:
// - runModelTurnWithTools: Tool-based model execution with routing
// - runModel: Bridge-based model execution using Bun AI SDK
// - executeInlineToolCalls: Parse and execute inline TOOL_CALL format
// - SubagentThreadArgs: Types for subagent execution

const std = @import("std");

// Types
pub const SubagentThreadArgs = @import("types.zig").SubagentThreadArgs;

// Core execution functions
pub const runModelTurnWithTools = @import("turn.zig").runModelTurnWithTools;
pub const runModel = @import("orchestrator.zig").runModel;
pub const executeInlineToolCalls = @import("tools.zig").executeInlineToolCalls;

// Helper functions
pub const toolDefsToLlm = @import("turn.zig").toolDefsToLlm;
pub const isCancelled = @import("turn.zig").isCancelled;
pub const setToolOutputCallback = @import("orchestrator.zig").setToolOutputCallback;
pub const ToolOutputCallback = @import("orchestrator.zig").ToolOutputCallback;
pub const initToolOutputArena = @import("orchestrator.zig").initToolOutputArena;
pub const deinitToolOutputArena = @import("orchestrator.zig").deinitToolOutputArena;

// Subagent handling
pub const subagentThreadMain = @import("subagent.zig").subagentThreadMain;

// Convenience wrapper for direct model calls
pub fn callModelDirect(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    provider_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const @import("../llm.zig").ToolRouteDef,
    reasoning_effort: ?[]const u8,
) !@import("../llm.zig").ChatResponse {
    return @import("../llm.zig").chat(allocator, api_key, model_id, provider_id, messages_json, tool_defs, reasoning_effort);
}
