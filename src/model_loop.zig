// model_loop.zig - Backward-compatible wrapper
//
// This file re-exports from the model_loop/ module for backward compatibility.
// All new code should import from model_loop/main.zig directly.

const main = @import("model_loop/main.zig");

// Re-export all public functions
pub const runModelTurnWithTools = main.runModelTurnWithTools;
pub const runModel = main.runModel;
pub const executeInlineToolCalls = main.executeInlineToolCalls;
pub const callModelDirect = main.callModelDirect;
pub const toolDefsToLlm = main.toolDefsToLlm;
pub const isCancelled = main.isCancelled;

// Re-export types
pub const SubagentThreadArgs = main.SubagentThreadArgs;

// Subagent handling (for internal use)
pub const subagentThreadMain = main.subagentThreadMain;
