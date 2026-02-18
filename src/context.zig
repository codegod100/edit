const std = @import("std");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const utils = @import("utils.zig");

pub const Role = enum {
    user,
    assistant,
};

pub const ContextTurn = struct {
    role: Role,
    content: []u8,
    reasoning: ?[]u8,
    tool_calls: usize,
    error_count: usize,
    files_touched: ?[]u8,

    pub fn deinit(self: *ContextTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |r| allocator.free(r);
        if (self.files_touched) |f| allocator.free(f);
    }
};

pub const TurnMeta = struct {
    reasoning: ?[]const u8 = null,
    tool_calls: usize = 0,
    error_count: usize = 0,
    files_touched: ?[]const u8 = null,
};

pub const RunTurnResult = struct {
    response: []u8,
    reasoning: []u8,
    tool_calls: usize,
    error_count: usize,
    files_touched: ?[]u8,

    pub fn deinit(self: *RunTurnResult, allocator: std.mem.Allocator) void {
        allocator.free(self.response);
        allocator.free(self.reasoning);
        if (self.files_touched) |f| allocator.free(f);
    }
};

pub const ContextWindow = struct {
    turns: std.ArrayListUnmanaged(ContextTurn),
    summary: ?[]u8,
    title: ?[]u8,
    max_chars: usize,
    keep_recent_turns: usize,

    pub fn init(max_chars: usize, keep_recent_turns: usize) ContextWindow {
        return .{
            .turns = .{},
            .summary = null,
            .title = null,
            .max_chars = max_chars,
            .keep_recent_turns = keep_recent_turns,
        };
    }

    pub fn deinit(self: *ContextWindow, allocator: std.mem.Allocator) void {
        for (self.turns.items) |*turn| turn.deinit(allocator);
        self.turns.deinit(allocator);
        if (self.summary) |s| allocator.free(s);
        if (self.title) |t| allocator.free(t);
    }

    pub fn append(self: *ContextWindow, allocator: std.mem.Allocator, role: Role, content: []const u8, meta: TurnMeta) !void {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) return;
        try self.turns.append(allocator, .{
            .role = role,
            .content = try allocator.dupe(u8, trimmed),
            .reasoning = if (meta.reasoning) |r| try allocator.dupe(u8, r) else null,
            .tool_calls = meta.tool_calls,
            .error_count = meta.error_count,
            .files_touched = if (meta.files_touched) |f| try allocator.dupe(u8, f) else null,
        });
    }
};

pub const CommandHistory = struct {
    items: std.ArrayListUnmanaged([]u8),

    pub fn init() CommandHistory {
        return .{ .items = .{} };
    }

    pub fn deinit(self: *CommandHistory, allocator: std.mem.Allocator) void {
        for (self.items.items) |entry| allocator.free(entry);
        self.items.deinit(allocator);
    }

    pub fn append(self: *CommandHistory, allocator: std.mem.Allocator, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], trimmed)) return;
        try self.items.append(allocator, try allocator.dupe(u8, trimmed));
    }
};

pub const ActiveModel = struct {
    provider_id: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
    reasoning_effort: ?[]const u8 = null,
};

pub const HistoryNav = enum { up, down };

pub fn historyNextIndex(entries: []const []const u8, current: ?usize, nav: HistoryNav) ?usize {
    if (entries.len == 0) return null;
    return switch (nav) {
        .up => if (current) |idx| if (idx > 0) idx - 1 else 0 else entries.len - 1,
        .down => if (current) |idx| if (idx + 1 < entries.len) idx + 1 else null else null,
    };
}

// --- History persistence ---

pub fn historyPathAlloc(allocator: std.mem.Allocator, base_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_path, "history" });
}

pub fn loadHistory(allocator: std.mem.Allocator, base_path: []const u8, history: *CommandHistory) !void {
    const path = try historyPathAlloc(allocator, base_path);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const text = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try history.append(allocator, line);
    }
}

pub fn appendHistoryLine(allocator: std.mem.Allocator, base_path: []const u8, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return;

    const path = try historyPathAlloc(allocator, base_path);
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.createFileAbsolute(path, .{}),
        else => return err,
    };
    defer file.close();

    try file.seekFromEnd(0);
    try file.writeAll(trimmed);
    try file.writeAll("\n");
}

// --- Context window persistence ---

pub fn hashProjectPath(cwd: []const u8) u64 {
    return std.hash.Crc32.hash(cwd);
}

// Session info for listing available sessions
pub const SessionInfo = struct {
    id: []u8,
    path: []u8,
    title: ?[]u8,
    modified_time: i128,
    turn_count: usize,
    file_size: usize,
    size_str: []u8,

    pub fn deinit(self: *SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        allocator.free(self.size_str);
        if (self.title) |t| allocator.free(t);
    }
};

// List available context sessions
pub fn listContextSessions(allocator: std.mem.Allocator, base_path: []const u8) !std.ArrayListUnmanaged(SessionInfo) {
    var sessions: std.ArrayListUnmanaged(SessionInfo) = .empty;
    errdefer {
        for (sessions.items) |*s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return sessions,
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        
        // Match context-{hex}.json pattern
        if (!std.mem.startsWith(u8, entry.name, "context-")) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        
        const hash_part = entry.name["context-".len .. entry.name.len - ".json".len];
        
        // Validate it's a hex string
        var valid_hex = true;
        for (hash_part) |c| {
            if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                valid_hex = false;
                break;
            }
        }
        if (!valid_hex) continue;

        // Get file stats
        const stat = dir.statFile(entry.name) catch continue;

        // Build full path
        const full_path = try std.fs.path.join(allocator, &.{ base_path, entry.name });
        errdefer allocator.free(full_path);

        // Peek for title or first prompt snippet
        var title: ?[]u8 = null;
        const file = std.fs.openFileAbsolute(full_path, .{}) catch null;
        if (file) |f| {
            defer f.close();
            var peek_buf: [4096]u8 = undefined;
            const peek_len = f.readAll(&peek_buf) catch 0;
            const peek_data = peek_buf[0..peek_len];

            // 1. Try explicit title
            if (std.mem.indexOf(u8, peek_data, "\"title\":\"")) |idx| {
                const start = idx + 9;
                if (std.mem.indexOfScalarPos(u8, peek_data, start, '"')) |end| {
                    title = try allocator.dupe(u8, peek_data[start..end]);
                }
            }

            // 2. Fallback to first user prompt snippet
            if (title == null) {
                if (std.mem.indexOf(u8, peek_data, "\"role\":\"user\",\"content\":\"")) |idx| {
                    const start = idx + 25;
                    if (std.mem.indexOfScalarPos(u8, peek_data, start, '"')) |end| {
                        const snippet = peek_data[start..end];
                        const cap = @min(snippet.len, 60);
                        var clean = try allocator.alloc(u8, cap);
                        for (snippet[0..cap], 0..) |c, j| {
                            clean[j] = if (c == '\n' or c == '\r' or c == '\t') ' ' else c;
                        }
                        title = clean;
                        if (snippet.len > 60) {
                            const old = title.?;
                            title = try std.fmt.allocPrint(allocator, "{s}...", .{old});
                            allocator.free(old);
                        }
                    }
                }
            }
        }

        try sessions.append(allocator, .{
            .id = try allocator.dupe(u8, hash_part),
            .path = full_path,
            .title = title,
            .modified_time = stat.mtime,
            .turn_count = 0, // Disabled for performance
            .file_size = @intCast(stat.size),
            .size_str = try formatSize(allocator, stat.size),
        });
    }

    // Sort by modified time (newest first)
    std.mem.sort(SessionInfo, sessions.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return a.modified_time > b.modified_time;
        }
    }.lessThan);

    return sessions;
}

fn formatSize(allocator: std.mem.Allocator, size: usize) ![]u8 {
    if (size < 1024) {
        return std.fmt.allocPrint(allocator, "{d}B", .{size});
    } else if (size < 1024 * 1024) {
        return std.fmt.allocPrint(allocator, "{d:.1}KB", .{@as(f64, @floatFromInt(size)) / 1024});
    } else {
        return std.fmt.allocPrint(allocator, "{d:.1}MB", .{@as(f64, @floatFromInt(size)) / (1024 * 1024)});
    }
}

pub fn contextPathAlloc(allocator: std.mem.Allocator, base_path: []const u8, project_hash: u64) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "context-{x}.json", .{project_hash});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ base_path, filename });
}

pub fn loadContextWindow(allocator: std.mem.Allocator, base_path: []const u8, window: *ContextWindow, project_hash: u64) !void {
    const path = try contextPathAlloc(allocator, base_path, project_hash);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const text = try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(text);

    const TurnJson = struct {
        role: []const u8,
        content: []const u8,
        reasoning: ?[]const u8 = null,
        tool_calls: ?usize = null,
        error_count: ?usize = null,
        files_touched: ?[]const u8 = null,
    };
    const ContextJson = struct {
        summary: ?[]const u8 = null,
        title: ?[]const u8 = null,
        turns: []const TurnJson = &.{},
    };

    var parsed = std.json.parseFromSlice(ContextJson, allocator, text, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    if (parsed.value.summary) |s| {
        if (window.summary) |existing| allocator.free(existing);
        window.summary = try allocator.dupe(u8, s);
    }

    if (parsed.value.title) |t| {
        if (window.title) |existing| allocator.free(existing);
        window.title = try allocator.dupe(u8, t);
    }

    for (parsed.value.turns) |turn| {
        const role: Role = if (std.mem.eql(u8, turn.role, "assistant")) .assistant else .user;
        try window.append(allocator, role, turn.content, .{
            .reasoning = turn.reasoning,
            .tool_calls = turn.tool_calls orelse 0,
            .error_count = turn.error_count orelse 0,
            .files_touched = turn.files_touched,
        });
    }
}

// Load context by hash ID string (hex)
pub fn loadContextWindowById(allocator: std.mem.Allocator, base_path: []const u8, window: *ContextWindow, hash_id: []const u8) !bool {
    const hash = std.fmt.parseInt(u64, hash_id, 16) catch return false;
    loadContextWindow(allocator, base_path, window, hash) catch return false;
    return window.turns.items.len > 0;
}

// Load context by hash ID string and return the hash value
pub fn loadContextWindowWithHash(allocator: std.mem.Allocator, base_path: []const u8, window: *ContextWindow, hash_id: []const u8) !?u64 {
    const hash = std.fmt.parseInt(u64, hash_id, 16) catch return null;
    loadContextWindow(allocator, base_path, window, hash) catch return null;
    if (window.turns.items.len == 0) return null;
    return hash;
}


pub fn saveContextWindow(allocator: std.mem.Allocator, base_path: []const u8, window: *const ContextWindow, project_hash: u64) !void {
    const logger = @import("logger.zig");
    const path = try contextPathAlloc(allocator, base_path, project_hash);
    defer allocator.free(path);

    logger.info("Saving context to {s}...", .{path});
    const dir_path = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const TurnJson = struct {
        role: []const u8,
        content: []const u8,
        reasoning: ?[]const u8,
        tool_calls: usize,
        error_count: usize,
        files_touched: ?[]const u8,
    };
    const ContextJson = struct {
        summary: ?[]const u8,
        title: ?[]const u8,
        turns: []TurnJson,
    };

    var turns: std.ArrayListUnmanaged(TurnJson) = .empty;
    defer turns.deinit(allocator);
    for (window.turns.items) |turn| {
        try turns.append(allocator, .{
            .role = if (turn.role == .assistant) "assistant" else "user",
            .content = turn.content,
            .reasoning = turn.reasoning,
            .tool_calls = turn.tool_calls,
            .error_count = turn.error_count,
            .files_touched = turn.files_touched,
        });
    }

    const payload = ContextJson{ .summary = window.summary, .title = window.title, .turns = turns.items };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.writer(allocator).print("{f}\n", .{std.json.fmt(payload, .{})});

    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(out.items);
    logger.info("Saved context ({d} turns, {d} bytes)", .{ window.turns.items.len, out.items.len });
}

// --- Context compaction and summarization ---

pub fn estimateContextChars(window: *const ContextWindow) usize {
    var total: usize = if (window.summary) |s| s.len else 0;
    for (window.turns.items) |turn| total += turn.content.len + 20;
    return total;
}

pub fn compactContextWindow(allocator: std.mem.Allocator, window: *ContextWindow, active: ?ActiveModel) !void {
    if (window.turns.items.len <= window.keep_recent_turns) return;
    if (estimateContextChars(window) <= window.max_chars) return;

    const compact_count = window.turns.items.len - window.keep_recent_turns;
    const new_summary = if (active) |a|
        (summarizeTurnsWithModel(allocator, window, compact_count, a) catch null)
    else
        null;

    const fallback_summary = if (new_summary == null)
        try buildHeuristicSummary(allocator, window, compact_count)
    else
        null;
    const final_summary = if (new_summary) |s| s else fallback_summary.?;

    if (window.summary) |old| allocator.free(old);
    window.summary = final_summary;

    var idx: usize = 0;
    while (idx < compact_count) : (idx += 1) {
        var first = window.turns.orderedRemove(0);
        first.deinit(allocator);
    }
}

pub fn buildHeuristicSummary(allocator: std.mem.Allocator, window: *const ContextWindow, compact_count: usize) ![]u8 {
    var summary_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer summary_buf.deinit(allocator);

    if (window.summary) |existing| {
        try summary_buf.writer(allocator).print("{s}\n", .{existing});
    }
    try summary_buf.appendSlice(allocator, "Compacted context notes:\n");

    var idx: usize = 0;
    while (idx < compact_count) : (idx += 1) {
        const turn = window.turns.items[idx];
        const prefix = if (turn.role == .assistant) "A" else "U";
        const cap_len = @min(turn.content.len, 220);
        if (turn.role == .assistant and (turn.tool_calls > 0 or turn.files_touched != null)) {
            try summary_buf.writer(allocator).print(
                "- {s}: {s} [tools={d} errors={d}{s}]\n",
                .{ prefix, turn.content[0..cap_len], turn.tool_calls, turn.error_count, if (turn.files_touched) |f| f else "" },
            );
        } else {
            try summary_buf.writer(allocator).print("- {s}: {s}\n", .{ prefix, turn.content[0..cap_len] });
        }
    }
    return summary_buf.toOwnedSlice(allocator);
}

fn summarizeTurnsWithModel(allocator: std.mem.Allocator, window: *const ContextWindow, compact_count: usize, active: ActiveModel) !?[]u8 {
    var turns_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer turns_buf.deinit(allocator);
    const w = turns_buf.writer(allocator);
    var idx: usize = 0;
    while (idx < compact_count) : (idx += 1) {
        const turn = window.turns.items[idx];
        const role = if (turn.role == .assistant) "assistant" else "user";
        try w.print("- {s}: {s}", .{ role, turn.content });
        if (turn.role == .assistant and (turn.tool_calls > 0 or turn.files_touched != null or turn.error_count > 0)) {
            try w.print(" [tools={d} errors={d}", .{ turn.tool_calls, turn.error_count });
            if (turn.files_touched) |f| try w.print(" files={s}", .{f});
            try w.print("]", .{});
        }
        try w.print("\n", .{});
    }

    const prompt = try std.fmt.allocPrint(
        allocator,
        "Summarize these prior chat turns for future coding assistance. Keep it concise (6-10 bullets), include decisions, files touched, errors/fixes, and unresolved tasks.\n\nExisting summary:\n{s}\n\nTurns to compact:\n{s}",
        .{ if (window.summary) |s| s else "(none)", turns_buf.items },
    );
    defer allocator.free(prompt);

    const text = llm.query(allocator, active.provider_id, active.api_key, active.model_id, prompt, utils.toolDefsToLlm(tools.definitions[0..])) catch return null;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        allocator.free(text);
        return null;
    }
    return text;
}

pub fn buildRelevantTurnIndices(allocator: std.mem.Allocator, window: *const ContextWindow, user_input: []const u8, max_turns: usize) ![]usize {
    const ScoredTurn = struct { idx: usize, score: usize };
    var scored: std.ArrayListUnmanaged(ScoredTurn) = .empty;
    defer scored.deinit(allocator);

    for (window.turns.items, 0..) |turn, idx| {
        var score: usize = 0;
        if (utils.containsIgnoreCase(turn.content, user_input)) score += 4;
        if (utils.containsIgnoreCase(user_input, "file") and turn.files_touched != null) score += 2;
        if (turn.role == .assistant and turn.tool_calls > 0) score += 1;
        const recency = window.turns.items.len - idx;
        if (recency <= 4) score += 3;
        if (score > 0) try scored.append(allocator, .{ .idx = idx, .score = score });
    }

    std.mem.sort(ScoredTurn, scored.items, {}, struct {
        fn lessThan(_: void, a: ScoredTurn, b: ScoredTurn) bool {
            if (a.score == b.score) return a.idx > b.idx;
            return a.score > b.score;
        }
    }.lessThan);

    const take = @min(max_turns, scored.items.len);
    var selected: std.ArrayListUnmanaged(usize) = .empty;
    defer selected.deinit(allocator);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        try selected.append(allocator, scored.items[i].idx);
    }

    std.mem.sort(usize, selected.items, {}, std.sort.asc(usize));
    return selected.toOwnedSlice(allocator);
}

pub fn buildContextPrompt(allocator: std.mem.Allocator, window: *const ContextWindow, user_input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("You are continuing an existing coding conversation. Use prior context when relevant, but prioritize correctness and current repository state.\n", .{});
    if (window.summary) |s| {
        try w.print("\nConversation summary:\n{s}\n", .{s});
    }

    if (window.turns.items.len > 0) {
        try w.print("\nRelevant turns:\n", .{});
        const indices = try buildRelevantTurnIndices(allocator, window, user_input, 8);
        defer allocator.free(indices);
        for (indices) |idx| {
            const turn = window.turns.items[idx];
            const tag = if (turn.role == .assistant) "Assistant" else "User";
            if (turn.role == .assistant and (turn.tool_calls > 0 or turn.files_touched != null or turn.error_count > 0)) {
                try w.print(
                    "{s}: {s} [tools={d} errors={d}{s}]\n",
                    .{ tag, turn.content, turn.tool_calls, turn.error_count, if (turn.files_touched) |f| f else "" },
                );
            } else {
                try w.print("{s}: {s}\n", .{ tag, turn.content });
            }
        }
    }

    try w.print("\nCurrent user request:\n{s}", .{user_input});
    return out.toOwnedSlice(allocator);
}

pub fn buildContextMessagesJson(allocator: std.mem.Allocator, window: *const ContextWindow, user_input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.writeAll("[");

    // 1. System Prompt (as a system message)
    try w.writeAll("{\"role\":\"system\",\"content\":\"You are continuing an existing coding conversation. Use prior context when relevant, but prioritize correctness and current repository state.");
    if (window.summary) |s| {
        try w.writeAll("\\n\\nConversation summary:\\n");
        try utils.writeJsonString(w, s);
    }
    try w.writeAll("\"},");

    // 2. Relevant Turns
    const indices = try buildRelevantTurnIndices(allocator, window, user_input, 10);
    defer allocator.free(indices);

    for (indices) |idx| {
        const turn = window.turns.items[idx];
        // Avoid duplicating the current user request in relevant turns.
        // The current request is appended explicitly below, so any matching
        // user turn here is redundant and can cause duplicated prompts.
        if (turn.role == .user and std.mem.eql(u8, turn.content, user_input)) {
            continue;
        }
        try w.writeAll("{\"role\":");
        try w.print("{f}", .{std.json.fmt(if (turn.role == .user) "user" else "assistant", .{})});
        try w.writeAll(",\"content\":");
        
        var content_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer content_buf.deinit(allocator);
        const cw = content_buf.writer(allocator);
        
        if (turn.role == .assistant and (turn.tool_calls > 0 or turn.files_touched != null or turn.error_count > 0)) {
            try cw.print("{s} [tools={d} errors={d}", .{ turn.content, turn.tool_calls, turn.error_count });
            if (turn.files_touched) |f| try cw.print(" files={s}", .{f});
            try cw.print("]", .{});
        } else {
            try cw.writeAll(turn.content);
        }
        
        try w.print("{f}", .{std.json.fmt(content_buf.items, .{})});
        try w.writeAll("},");
    }

    // 3. Current request
    try w.writeAll("{\"role\":\"user\",\"content\":");
    try w.print("{f}", .{std.json.fmt(user_input, .{})});
    try w.writeAll("}]");

    return out.toOwnedSlice(allocator);
}
