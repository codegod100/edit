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
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);
        const w = result.writer(allocator);

        if (self.items.items.len == 0) {
            try w.print("No tasks in the todo list.\n", .{});
            return result.toOwnedSlice(allocator);
        }

        const C_CYAN = "\x1b[36m";
        const C_GREEN = "\x1b[32m";
        const C_GREY = "\x1b[90m";
        const C_YELLOW = "\x1b[33m";
        const C_RESET = "\x1b[0m";
        const C_DIM = "\x1b[2m";
        const C_BOLD = "\x1b[1m";

        // Borders using hex escapes for consistency (50 width)
        const top_edge = "\xe2\x95\xad" ++ ("\xe2\x94\x80" ** 50) ++ "\xe2\x95\xae";
        const mid_edge = "\xe2\x94\x9c" ++ ("\xe2\x94\x80" ** 50) ++ "\xe2\x94\xa4";
        const bot_edge = "\xe2\x95\xb0" ++ ("\xe2\x94\x80" ** 50) ++ "\xe2\x95\xaf";
        const v_line = "\xe2\x94\x82";

        try w.print(C_DIM ++ "{s}\n" ++ C_RESET, .{top_edge});
        try w.print(C_DIM ++ "{s}" ++ C_RESET ++ "  " ++ C_BOLD ++ C_CYAN ++ "Plan & Progress" ++ C_RESET ++ " " ** 33 ++ C_DIM ++ "{s}\n" ++ C_RESET, .{ v_line, v_line });
        try w.print(C_DIM ++ "{s}\n" ++ C_RESET, .{mid_edge});

        for (self.items.items) |item| {
            const icon = switch (item.status) {
                .pending => C_GREY ++ "\xe2\x97\x8b" ++ C_RESET, // ○
                .in_progress => C_YELLOW ++ "\xe2\x97\x8f" ++ C_RESET, // ●
                .done => C_GREEN ++ "\xe2\x9c\x93" ++ C_RESET, // ✓
            };
            
            const desc_color = if (item.status == .done) C_GREY else if (item.status == .in_progress) C_BOLD else "";

            const max_desc = 44;
            const display_desc = if (item.description.len > max_desc) item.description[0..max_desc] else item.description;
            const padding = 50 - 4 - display_desc.len;

            try w.print(C_DIM ++ "{s}" ++ C_RESET ++ " {s}  {s}{s}" ++ C_RESET, .{ 
                v_line,
                icon, 
                desc_color, 
                display_desc,
            });

            var p: usize = 0;
            while (p < padding) : (p += 1) try w.writeByte(' ');

            try w.print(C_DIM ++ "{s}\n" ++ C_RESET, .{v_line});
        }

        try w.print(C_DIM ++ "{s}\n" ++ C_RESET, .{bot_edge});

        return result.toOwnedSlice(allocator);
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
