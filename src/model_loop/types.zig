const std = @import("std");
const active_module = @import("../context.zig");
const subagent = @import("../subagent.zig");
const todo = @import("../todo.zig");

pub const SubagentThreadArgs = struct {
    manager: *subagent.SubagentManager,
    id: []u8,
    task_type: subagent.SubagentType,
    description: []u8,
    parent_context: ?[]u8,
    active: active_module.ActiveModel,

    pub fn deinit(self: *SubagentThreadArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        if (self.parent_context) |c| allocator.free(c);
        allocator.free(self.active.provider_id);
        allocator.free(self.active.model_id);
        if (self.active.api_key) |k| allocator.free(k);
        if (self.active.reasoning_effort) |e| allocator.free(e);
    }
};
