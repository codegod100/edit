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
    items: std.ArrayListUnmanaged(TodoItem),
    allocator: std.mem.Allocator,
    next_seq: usize,

    pub fn init(allocator: std.mem.Allocator) TodoList {
        return .{
            .items = std.ArrayListUnmanaged(TodoItem).empty,
            .allocator = allocator,
            .next_seq = 0,
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
        const id = try std.fmt.allocPrint(self.allocator, "{d}_{d}", .{ timestamp, self.next_seq });
        self.next_seq += 1;

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
        self.items.clearRetainingCapacity();
    }

    pub fn list(self: *const TodoList, allocator: std.mem.Allocator) ![]u8 {
        const display = @import("display.zig");
        if (self.items.items.len == 0) {
            return allocator.dupe(u8, "No tasks in the todo list.\n");
        }

        var lines: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (lines.items) |l| allocator.free(l);
            lines.deinit(allocator);
        }

        const C_GREEN = "\x1b[32m";
        const C_GREY = "\x1b[90m";
        const C_YELLOW = "\x1b[33m";
        const C_RESET = "\x1b[0m";
        const C_BOLD = "\x1b[1m";

        for (self.items.items) |item| {
            const icon = switch (item.status) {
                .pending => "○",
                .in_progress => C_YELLOW ++ "●" ++ C_RESET,
                .done => C_GREEN ++ "✓" ++ C_RESET,
            };
            const desc_prefix = if (item.status == .done) C_GREY else if (item.status == .in_progress) C_BOLD else "";
            const line = try std.fmt.allocPrint(allocator, "{s} {s} {s}{s}", .{ icon, item.id, desc_prefix, item.description });
            try lines.append(allocator, line);
        }

        var max_width: usize = "Plan & Progress".len + 10;
        for (self.items.items) |item| {
            const line_len = item.description.len + item.id.len + 7; // icon + id + space + padding
            if (line_len > max_width) max_width = line_len;
        }
        max_width = @min(max_width, 100);

        return display.renderBox(allocator, "Plan & Progress", lines.items, max_width);
    }

    pub fn totalCount(self: *const TodoList) usize {
        return self.items.items.len;
    }

    pub fn completedCount(self: *const TodoList) usize {
        var count: usize = 0;
        for (self.items.items) |item| {
            if (item.status == .done) count += 1;
        }
        return count;
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

    pub fn hasPendingOrInProgress(self: *const TodoList) bool {
        for (self.items.items) |item| {
            if (item.status != .done) return true;
        }
        return false;
    }

    pub fn hasInProgressOnly(self: *const TodoList) bool {
        // Returns true if there are in_progress todos but no pending ones
        var has_in_progress = false;
        for (self.items.items) |item| {
            if (item.status == .pending) return false; // Has pending, not in_progress only
            if (item.status == .in_progress) has_in_progress = true;
        }
        return has_in_progress;
    }

    pub fn markTodosForPath(self: *TodoList, path: ?[]const u8) void {
        const p = path orelse return;
        for (self.items.items) |*item| {
            // Check if todo description contains the path
            if (std.mem.indexOf(u8, item.description, p) != null) {
                if (item.status != .done) {
                    item.status = .done;
                    item.completed_at = std.time.milliTimestamp();
                }
            }
        }
    }

    // Persistence - save todos to JSON file
    pub fn saveToFile(self: *const TodoList, allocator: std.mem.Allocator, file_path: []const u8) !void {
        var json: std.ArrayListUnmanaged(u8) = .empty;
        defer json.deinit(allocator);
        const w = json.writer(allocator);

        try w.print("[\n", .{});
        for (self.items.items, 0..) |item, i| {
            if (i > 0) try w.print(",\n", .{});
            const status_str = switch (item.status) {
                .pending => "pending",
                .in_progress => "in_progress",
                .done => "done",
            };
            try w.print("  {{\"id\":\"{s}\",\"description\":\"{s}\",\"status\":\"{s}\",\"created_at\":{d}}}", .{ item.id, item.description, status_str, item.created_at });
        }
        try w.print("\n]", .{});

        // Ensure directory exists
        const dir = std.fs.path.dirname(file_path) orelse return;
        try std.fs.cwd().makePath(dir);

        // Write to temp file then rename for atomicity
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{file_path});
        defer allocator.free(tmp_path);

        try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = json.items });
        try std.fs.cwd().rename(tmp_path, file_path);
    }

    // Persistence - load todos from JSON file
    pub fn loadFromFile(self: *TodoList, allocator: std.mem.Allocator, file_path: []const u8) !void {
        // Clear existing items first
        self.clearAll();

        const data = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return; // No existing file is OK
            return err;
        };
        defer allocator.free(data);

        const ItemJson = struct {
            id: []const u8,
            description: []const u8,
            status: []const u8,
            created_at: i64,
        };

        var parsed = std.json.parseFromSlice([]ItemJson, allocator, data, .{}) catch return;
        defer parsed.deinit();

        for (parsed.value) |item_json| {
            const status = std.meta.stringToEnum(TodoStatus, item_json.status) orelse .pending;
            const id = try self.allocator.dupe(u8, item_json.id);
            const desc = try self.allocator.dupe(u8, item_json.description);

            // Try to recover next_seq from loaded IDs
            if (std.mem.lastIndexOfScalar(u8, item_json.id, '_')) |idx| {
                const seq = std.fmt.parseInt(usize, item_json.id[idx + 1 ..], 10) catch 0;
                if (seq >= self.next_seq) self.next_seq = seq + 1;
            }

            const item = TodoItem{
                .id = id,
                .description = desc,
                .status = status,
                .created_at = item_json.created_at,
                .completed_at = if (status == .done) std.time.milliTimestamp() else null,
            };
            try self.items.append(self.allocator, item);
        }
    }
};
