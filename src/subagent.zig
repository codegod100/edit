const std = @import("std");

/// Subagent status
pub const SubagentStatus = enum {
    pending,
    running,
    completed,
    failed,
    cancelled,
};

/// Subagent type - determines the specialized behavior
pub const SubagentType = enum {
    /// General purpose agent for coding tasks
    coder,
    /// Specialized in searching and reading files
    researcher,
    /// Specialized in writing and editing files
    editor,
    /// Specialized in running tests and builds
    tester,
    /// Specialized in git operations
    git,
};

/// A subagent task
pub const SubagentTask = struct {
    id: []const u8,
    task_type: SubagentType,
    description: []const u8,
    status: SubagentStatus,
    result: ?[]const u8,
    error_msg: ?[]const u8,
    created_at: i64,
    completed_at: ?i64,
    tool_calls: usize,
    parent_context: ?[]const u8, // Context from parent agent

    pub fn deinit(self: *SubagentTask, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        if (self.result) |r| allocator.free(r);
        if (self.error_msg) |e| allocator.free(e);
        if (self.parent_context) |c| allocator.free(c);
    }
};

/// Subagent manager - handles creation, tracking, and execution of subagents
pub const SubagentManager = struct {
    allocator: std.mem.Allocator,
    tasks: std.ArrayList(SubagentTask),
    next_id: usize,
    max_concurrent: usize,
    total_tool_calls: usize,

    const Self = @This();

    /// Initialize a new subagent manager
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(SubagentTask).empty,
            .next_id = 1,
            .max_concurrent = 3,
            .total_tool_calls = 0,
        };
    }

    /// Clean up all tasks
    pub fn deinit(self: *Self) void {
        for (self.tasks.items) |*task| {
            task.deinit(self.allocator);
        }
        self.tasks.deinit(self.allocator);
    }

    /// Create a new subagent task
    pub fn createTask(
        self: *Self,
        task_type: SubagentType,
        description: []const u8,
        parent_context: ?[]const u8,
    ) ![]const u8 {
        // Generate ID
        const id = try std.fmt.allocPrint(self.allocator, "sub_{d}", .{self.next_id});
        self.next_id += 1;

        const desc_owned = try self.allocator.dupe(u8, description);
        errdefer self.allocator.free(desc_owned);

        const ctx_owned = if (parent_context) |ctx| try self.allocator.dupe(u8, ctx) else null;
        errdefer if (ctx_owned) |c| self.allocator.free(c);

        // Create task
        const task = SubagentTask{
            .id = id,
            .task_type = task_type,
            .description = desc_owned,
            .status = .pending,
            .result = null,
            .error_msg = null,
            .created_at = std.time.timestamp(),
            .completed_at = null,
            .tool_calls = 0,
            .parent_context = ctx_owned,
        };
        errdefer {
            var tmp = task;
            tmp.deinit(self.allocator);
        }

        try self.tasks.append(self.allocator, task);
        return task.id;
    }

    /// Update task status
    pub fn updateStatus(self: *Self, id: []const u8, status: SubagentStatus) bool {
        for (self.tasks.items) |*task| {
            if (std.mem.eql(u8, task.id, id)) {
                task.status = status;
                if (status == .completed or status == .failed or status == .cancelled) {
                    task.completed_at = std.time.timestamp();
                }
                return true;
            }
        }
        return false;
    }

    /// Set task result
    pub fn setResult(self: *Self, id: []const u8, result: []const u8, tool_calls: usize) !bool {
        for (self.tasks.items) |*task| {
            if (std.mem.eql(u8, task.id, id)) {
                if (task.result) |r| self.allocator.free(r);
                task.result = try self.allocator.dupe(u8, result);
                task.status = .completed;
                task.completed_at = std.time.timestamp();
                task.tool_calls = tool_calls;
                self.total_tool_calls += tool_calls;
                return true;
            }
        }
        return false;
    }

    /// Set task error
    pub fn setError(self: *Self, id: []const u8, error_msg: []const u8) !bool {
        for (self.tasks.items) |*task| {
            if (std.mem.eql(u8, task.id, id)) {
                if (task.error_msg) |e| self.allocator.free(e);
                task.error_msg = try self.allocator.dupe(u8, error_msg);
                task.status = .failed;
                task.completed_at = std.time.timestamp();
                return true;
            }
        }
        return false;
    }

    /// Get task by ID
    pub fn getTask(self: *Self, id: []const u8) ?SubagentTask {
        for (self.tasks.items) |task| {
            if (std.mem.eql(u8, task.id, id)) {
                return task;
            }
        }
        return null;
    }

    /// List all tasks
    pub fn listTasks(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);
        const w = result.writer(allocator);

        if (self.tasks.items.len == 0) {
            try w.print("No subagent tasks.\n", .{});
        } else {
            try w.print("Subagent tasks ({d} total):\n", .{self.tasks.items.len});
            for (self.tasks.items) |task| {
                const type_str = switch (task.task_type) {
                    .coder => "coder",
                    .researcher => "researcher",
                    .editor => "editor",
                    .tester => "tester",
                    .git => "git",
                };
                const status_str = switch (task.status) {
                    .pending => "pending",
                    .running => "running",
                    .completed => "completed",
                    .failed => "failed",
                    .cancelled => "cancelled",
                };
                const status_icon = switch (task.status) {
                    .pending => "○",
                    .running => "◐",
                    .completed => "●",
                    .failed => "✗",
                    .cancelled => "⊘",
                };
                try w.print("  {s} [{s}] {s}: {s}\n", .{ status_icon, type_str, task.id, task.description });
                if (task.result != null or task.error_msg != null) {
                    try w.print("      status={s}, tool_calls={d}\n", .{ status_str, task.tool_calls });
                }
                if (task.error_msg) |err| {
                    try w.print("      error: {s}\n", .{err});
                }
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Get summary of current subagent state
    pub fn summary(self: *Self) []const u8 {
        if (self.tasks.items.len == 0) {
            return "no subagents";
        }

        var pending: usize = 0;
        var running: usize = 0;
        var completed: usize = 0;
        var failed: usize = 0;

        for (self.tasks.items) |task| {
            switch (task.status) {
                .pending => pending += 1,
                .running => running += 1,
                .completed => completed += 1,
                .failed => failed += 1,
                .cancelled => {},
            }
        }

        if (failed > 0) {
            if (running > 0) {
                return "some subagents failed, others running";
            }
            return "some subagents failed";
        }

        if (running > 0) {
            if (pending > 0) {
                return "subagents running";
            }
            return "subagents active";
        }

        if (completed == self.tasks.items.len) {
            return "all subagents completed";
        }

        if (pending > 0) {
            return "subagents pending";
        }

        return "subagents idle";
    }

    /// Clear completed/failed tasks
    pub fn clearDone(self: *Self) usize {
        var i: usize = 0;
        var cleared: usize = 0;
        while (i < self.tasks.items.len) {
            const task = &self.tasks.items[i];
            if (task.status == .completed or task.status == .failed or task.status == .cancelled) {
                task.deinit(self.allocator);
                _ = self.tasks.orderedRemove(i);
                cleared += 1;
            } else {
                i += 1;
            }
        }
        return cleared;
    }

    /// Generate specialized system prompt for a subagent type
    pub fn getSystemPrompt(task_type: SubagentType) []const u8 {
        return switch (task_type) {
            .coder => 
                \\You are a specialized coding subagent. Focus on:
                \\- Reading and understanding code structure
                \\- Implementing requested changes
                \\- Following existing code patterns
                \\- Writing clean, idiomatic code
                \\- Running tests to verify changes
                \\Provide concise summaries of what you changed and why.
            ,
            .researcher => 
                \\You are a specialized research subagent. Focus on:
                \\- Searching for relevant files and code
                \\- Reading and summarizing code sections
                \\- Finding patterns and relationships
                \\- Gathering information efficiently
                \\Provide clear, structured summaries of findings.
            ,
            .editor => 
                \\You are a specialized editing subagent. Focus on:
                \\- Making precise, targeted edits
                \\- Preserving existing code style
                \\- Minimal, focused changes
                \\- Verifying edits don't break things
                \\Report exactly what was changed in each file.
            ,
            .tester => 
                \\You are a specialized testing subagent. Focus on:
                \\- Running existing tests
                \\- Identifying test failures
                \\- Suggesting fixes for failures
                \\- Verifying code correctness
                \\Report test results clearly with pass/fail status.
            ,
            .git => 
                \\You are a specialized git subagent. Focus on:
                \\- Checking repository status
                \\- Staging and committing changes
                \\- Reviewing diffs
                \\- Branch management
                \\Report git operations clearly with status updates.
            ,
        };
    }

    /// Count active subagents
    pub fn activeCount(self: *Self) usize {
        var count: usize = 0;
        for (self.tasks.items) |task| {
            if (task.status == .pending or task.status == .running) {
                count += 1;
            }
        }
        return count;
    }

    /// Check if can spawn more subagents
    pub fn canSpawn(self: *Self) bool {
        return self.activeCount() < self.max_concurrent;
    }
};

/// Parse subagent type from string
pub fn parseSubagentType(str: []const u8) ?SubagentType {
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, str) catch return null;
    defer std.heap.page_allocator.free(lower);
    
    if (std.mem.eql(u8, lower, "coder") or std.mem.eql(u8, lower, "code") or std.mem.eql(u8, lower, "c")) {
        return .coder;
    }
    if (std.mem.eql(u8, lower, "researcher") or std.mem.eql(u8, lower, "research") or std.mem.eql(u8, lower, "r")) {
        return .researcher;
    }
    if (std.mem.eql(u8, lower, "editor") or std.mem.eql(u8, lower, "edit") or std.mem.eql(u8, lower, "e")) {
        return .editor;
    }
    if (std.mem.eql(u8, lower, "tester") or std.mem.eql(u8, lower, "test") or std.mem.eql(u8, lower, "t")) {
        return .tester;
    }
    if (std.mem.eql(u8, lower, "git") or std.mem.eql(u8, lower, "g")) {
        return .git;
    }
    return null;
}

test "SubagentManager basic operations" {
    const allocator = std.testing.allocator;
    var manager = SubagentManager.init(allocator);
    defer manager.deinit();

    // Create a task
    const id = try manager.createTask(.coder, "Implement feature X", null);

    try std.testing.expectEqualStrings("sub_1", id);
    try std.testing.expectEqual(@as(usize, 1), manager.tasks.items.len);

    // Get the task
    const task = manager.getTask(id);
    try std.testing.expect(task != null);
    try std.testing.expectEqual(SubagentStatus.pending, task.?.status);

    // Update status
    try std.testing.expect(manager.updateStatus(id, .running));
    const updated = manager.getTask(id);
    try std.testing.expectEqual(SubagentStatus.running, updated.?.status);

    // Set result
    try std.testing.expect(try manager.setResult(id, "Feature implemented", 5));
    const completed = manager.getTask(id);
    try std.testing.expectEqual(SubagentStatus.completed, completed.?.status);
    try std.testing.expectEqual(@as(usize, 5), completed.?.tool_calls);
}

test "parseSubagentType" {
    try std.testing.expectEqual(SubagentType.coder, parseSubagentType("coder"));
    try std.testing.expectEqual(SubagentType.coder, parseSubagentType("CODE"));
    try std.testing.expectEqual(SubagentType.researcher, parseSubagentType("research"));
    try std.testing.expectEqual(SubagentType.editor, parseSubagentType("edit"));
    try std.testing.expectEqual(SubagentType.tester, parseSubagentType("test"));
    try std.testing.expectEqual(SubagentType.git, parseSubagentType("git"));
    try std.testing.expect(parseSubagentType("unknown") == null);
}

test "SubagentManager summary" {
    const allocator = std.testing.allocator;
    var manager = SubagentManager.init(allocator);
    defer manager.deinit();

    try std.testing.expectEqualStrings("no subagents", manager.summary());

    const id1 = try manager.createTask(.coder, "Task 1", null);
    try std.testing.expectEqualStrings("subagents pending", manager.summary());

    _ = manager.updateStatus(id1, .running);
    try std.testing.expectEqualStrings("subagents active", manager.summary());

    _ = try manager.createTask(.researcher, "Task 2", null);
    try std.testing.expectEqualStrings("subagents running", manager.summary());

    _ = try manager.setError(id1, "Something went wrong");
    try std.testing.expectEqualStrings("some subagents failed, others running", manager.summary());
}
