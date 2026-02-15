const std = @import("std");
const pm = @import("../provider_manager.zig");
const context = @import("../context.zig");
const todo = @import("../todo.zig");
const subagent = @import("../subagent.zig");
const config_store = @import("../config_store.zig");

pub const ReplState = struct {
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    provider_states: []pm.ProviderState,
    selected_model: ?config_store.SelectedModel,
    context_window: context.ContextWindow,
    todo_list: todo.TodoList,
    subagent_manager: subagent.SubagentManager,
    reasoning_effort: ?[]const u8,
    project_hash: u64,
    config_dir: []const u8,

    pub fn deinit(self: *ReplState) void {
        self.context_window.deinit(self.allocator);
        self.todo_list.deinit();
        self.subagent_manager.deinit();
        for (self.provider_states) |*s| s.deinit(self.allocator);
        self.allocator.free(self.provider_states);
        if (self.selected_model) |*s| s.deinit(self.allocator);
        if (self.reasoning_effort) |e| self.allocator.free(e);
        // providers is usually static or owned elsewhere, check main.zig
    }
};
