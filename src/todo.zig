const std = @import("std");

pub const TodoStatus = enum {
    pending,
    in_progress,
    done,
};

pub const TodoItem = struct {
    id: []u8,
    description: []u8,
    status: TodoStatus,
    created_at: i64,
    completed_at: ?i64,
};

pub const TodoList = struct {
    items: std.ArrayList(TodoItem),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TodoList {
        return .{
            .items = std.ArrayList(TodoItem).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TodoList) void {
        for (self.items.items) |*item| {
            self.allocator.free(item.id);
            self.allocator.free(item.description);
        }
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *TodoList, description: []const u8) ![]const u8 {
        const timestamp = std.time.milliTimestamp();
        const id = try std.fmt.allocPrint(self.allocator, "{d}", .{timestamp});

        const desc = try self.allocator.dupe(u8, description);

        const item = TodoItem{
            .id = id,
            .description = desc,
            .status = .pending,
            .created_at = timestamp,
            .completed_at = null,
        };

        try self.items.append(self.allocator, item);
        return id;
    }

    pub fn update(self: *TodoList, id: []const u8, status: TodoStatus) !bool {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.id, id)) {
                item.status = status;
                if (status == .done) {
                    item.completed_at = std.time.milliTimestamp();
                }
                return true;
            }
        }
        return false;
    }

    pub fn remove(self: *TodoList, id: []const u8) !bool {
        for (self.items.items, 0..) |item, idx| {
            if (std.mem.eql(u8, item.id, id)) {
                self.allocator.free(item.id);
                self.allocator.free(item.description);
                _ = self.items.orderedRemove(idx);
                return true;
            }
        }
        return false;
    }

    pub fn clearDone(self: *TodoList) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].status == .done) {
                self.allocator.free(self.items.items[i].id);
                self.allocator.free(self.items.items[i].description);
                _ = self.items.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn clearAll(self: *TodoList) void {
        for (self.items.items) |*item| {
            self.allocator.free(item.id);
            self.allocator.free(item.description);
        }
        self.items.clearRetainingCapacity(self.allocator);
    }

    pub fn list(self: *const TodoList, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);
        const w = result.writer(allocator);

        if (self.items.items.len == 0) {
            try w.print("No todos.\n", .{});
            return result.toOwnedSlice(allocator);
        }

        try w.print("Todos ({d} total):\n", .{self.items.items.len});

        for (self.items.items) |item| {
            const status_icon = switch (item.status) {
                .pending => "[ ]",
                .in_progress => "[→]",
                .done => "[✓]",
            };
            try w.print("  {s} {s}: {s}\n", .{ status_icon, item.id, item.description });
        }

        return result.toOwnedSlice(allocator);
    }

    pub fn summary(self: *const TodoList) []const u8 {
        var pending: usize = 0;
        var in_progress: usize = 0;
        var done: usize = 0;

        for (self.items.items) |item| {
            switch (item.status) {
                .pending => pending += 1,
                .in_progress => in_progress += 1,
                .done => done += 1,
            }
        }

        // Return a static string describing progress
        if (self.items.items.len == 0) {
            return "no todos";
        } else if (done == self.items.items.len) {
            return "all done";
        } else {
            return "in progress";
        }
    }
};
