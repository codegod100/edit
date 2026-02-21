const std = @import("std");
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const utils = @import("utils.zig");
const paths = @import("paths.zig");

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
    project_path: ?[]u8,
    max_chars: usize,
    keep_recent_turns: usize,

    pub fn init(max_chars: usize, keep_recent_turns: usize) ContextWindow {
        return .{
            .turns = .{},
            .summary = null,
            .title = null,
            .project_path = null,
            .max_chars = max_chars,
            .keep_recent_turns = keep_recent_turns,
        };
    }

    pub fn deinit(self: *ContextWindow, allocator: std.mem.Allocator) void {
        for (self.turns.items) |*turn| turn.deinit(allocator);
        self.turns.deinit(allocator);
        if (self.summary) |s| allocator.free(s);
        if (self.title) |t| allocator.free(t);
        if (self.project_path) |p| allocator.free(p);
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
        const normalized = normalizeHistoryLine(line);
        if (normalized.len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], normalized)) return;
        try self.items.append(allocator, try allocator.dupe(u8, normalized));
    }
};

pub fn normalizeHistoryLine(line: []const u8) []const u8 {
    var trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return trimmed;

    while (true) {
        // Strip leading ANSI escape sequences (e.g. "\x1b[38;5;111m").
        while (trimmed.len > 2 and trimmed[0] == 0x1b and trimmed[1] == '[') {
            var i: usize = 2;
            while (i < trimmed.len) : (i += 1) {
                const c = trimmed[i];
                if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                    i += 1;
                    break;
                }
            }
            if (i <= 2 or i > trimmed.len) break;
            trimmed = std.mem.trimLeft(u8, trimmed[i..], " \t");
        }

        if (std.mem.startsWith(u8, trimmed, ">")) {
            trimmed = std.mem.trimLeft(u8, trimmed[1..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "›")) {
            trimmed = std.mem.trimLeft(u8, trimmed["›".len..], " \t");
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "❯")) {
            trimmed = std.mem.trimLeft(u8, trimmed["❯".len..], " \t");
            continue;
        }
        break;
    }

    // Strip trailing ANSI escape sequences (e.g. "\x1b[0m").
    while (trimmed.len > 2) {
        const esc_idx = std.mem.lastIndexOf(u8, trimmed, "\x1b[") orelse break;
        var i: usize = esc_idx + 2;
        while (i < trimmed.len) : (i += 1) {
            const c = trimmed[i];
            if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                i += 1;
                break;
            }
        }
        if (i == trimmed.len) {
            trimmed = std.mem.trimRight(u8, trimmed[0..esc_idx], " \t");
            continue;
        }
        break;
    }

    return trimmed;
}

pub const ActiveModel = struct {
    provider_id: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
    reasoning_effort: ?[]const u8 = null,
};

pub const HistoryNav = enum { up, down };

fn stripRunMetadataSuffix(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    const idx = std.mem.lastIndexOf(u8, trimmed, " [tools=") orelse return trimmed;
    const tail = trimmed[idx..];
    if (std.mem.indexOf(u8, tail, " errors=") == null) return trimmed;
    if (std.mem.indexOf(u8, tail, " files=") == null) return trimmed;
    if (trimmed[trimmed.len - 1] != ']') return trimmed;
    return std.mem.trimRight(u8, trimmed[0..idx], " \t\r\n");
}

pub fn historyNextIndex(entries: []const []const u8, current: ?usize, nav: HistoryNav) ?usize {
    if (entries.len == 0) return null;
    return switch (nav) {
        .up => if (current) |idx| if (idx > 0) idx - 1 else 0 else entries.len - 1,
        .down => if (current) |idx| if (idx + 1 < entries.len) idx + 1 else null else null,
    };
}

// --- History persistence ---

pub fn historyPathAlloc(allocator: std.mem.Allocator, base_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_path, paths.HISTORY_FILENAME });
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
    const normalized = normalizeHistoryLine(line);
    if (normalized.len == 0) return;

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
    try file.writeAll(normalized);
    try file.writeAll("\n");
}

test "normalizeHistoryLine strips repeated prompt markers" {
    try std.testing.expectEqualStrings("hello", normalizeHistoryLine("> > hello"));
    try std.testing.expectEqualStrings("hello", normalizeHistoryLine("> >hello"));
    try std.testing.expectEqualStrings("hello", normalizeHistoryLine(">hello"));
    try std.testing.expectEqualStrings("run tests", normalizeHistoryLine("› ❯ run tests"));
}

test "normalizeHistoryLine strips ansi then prompt marker" {
    try std.testing.expectEqualStrings("/usage", normalizeHistoryLine("\x1b[38;5;111m> /usage\x1b[0m"));
}

test "normalizeHistoryLine keeps normal input" {
    try std.testing.expectEqualStrings("/model openai/gpt-5", normalizeHistoryLine("/model openai/gpt-5"));
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

fn isValidHexId(id: []const u8) bool {
    if (id.len == 0) return false;
    for (id) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
            return false;
        }
    }
    return true;
}

fn contextProjectIdAlloc(allocator: std.mem.Allocator, project_hash: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{x}", .{project_hash});
}

fn contextProjectDirAlloc(allocator: std.mem.Allocator, base_path: []const u8, project_hash: u64) ![]u8 {
    const project_id = try contextProjectIdAlloc(allocator, project_hash);
    defer allocator.free(project_id);
    return std.fs.path.join(allocator, &.{ base_path, paths.CONTEXTS_V2_DIR_NAME, project_id });
}

fn contextMetaPathAlloc(allocator: std.mem.Allocator, base_path: []const u8, project_hash: u64) ![]u8 {
    const dir = try contextProjectDirAlloc(allocator, base_path, project_hash);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "meta.json" });
}

fn contextSnapshotPathAlloc(allocator: std.mem.Allocator, base_path: []const u8, project_hash: u64) ![]u8 {
    const dir = try contextProjectDirAlloc(allocator, base_path, project_hash);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "snapshot.json" });
}

fn contextEventsPathAlloc(allocator: std.mem.Allocator, base_path: []const u8, project_hash: u64) ![]u8 {
    const dir = try contextProjectDirAlloc(allocator, base_path, project_hash);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "events.ndjson" });
}

// List available context sessions
pub fn listContextSessions(allocator: std.mem.Allocator, base_path: []const u8) !std.ArrayListUnmanaged(SessionInfo) {
    var sessions: std.ArrayListUnmanaged(SessionInfo) = .empty;
    errdefer {
        for (sessions.items) |*s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    const contexts_dir_path = try std.fs.path.join(allocator, &.{ base_path, paths.CONTEXTS_V2_DIR_NAME });
    defer allocator.free(contexts_dir_path);

    var dir = std.fs.openDirAbsolute(contexts_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return sessions,
        else => return err,
    };
    defer dir.close();

    const SnapshotPreview = struct {
        title: ?[]const u8 = null,
        turns: []const struct { role: []const u8, content: []const u8 } = &.{},
    };

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!isValidHexId(entry.name)) continue;

        const snapshot_path = try std.fs.path.join(allocator, &.{ contexts_dir_path, entry.name, "snapshot.json" });
        defer allocator.free(snapshot_path);

        var title: ?[]u8 = null;
        const file = std.fs.openFileAbsolute(snapshot_path, .{}) catch continue;
        defer file.close();
        const stat = file.stat() catch continue;
        const text = file.readToEndAlloc(allocator, 128 * 1024) catch null;
        if (text) |t| {
            defer allocator.free(t);
            if (std.json.parseFromSlice(SnapshotPreview, allocator, t, .{ .ignore_unknown_fields = true })) |parsed| {
                defer parsed.deinit();
                if (parsed.value.title) |session_title| {
                    const cleaned = std.mem.trim(u8, session_title, " \t\r\n");
                    if (cleaned.len > 0 and !std.fs.path.isAbsolute(cleaned)) {
                        title = allocator.dupe(u8, cleaned) catch null;
                    }
                }
                if (title == null) {
                    for (parsed.value.turns) |turn| {
                        if (!std.mem.eql(u8, turn.role, "user")) continue;
                        const clean = std.mem.trim(u8, turn.content, " \t\r\n");
                        if (clean.len == 0) continue;
                        const cap = @min(clean.len, 60);
                        title = allocator.dupe(u8, clean[0..cap]) catch null;
                        if (title != null and clean.len > 60) {
                            const old = title.?;
                            title = std.fmt.allocPrint(allocator, "{s}...", .{old}) catch old;
                            if (!std.mem.eql(u8, title.?, old)) allocator.free(old);
                        }
                        break;
                    }
                }
            } else |_| {}
        }

        const full_path = try std.fs.path.join(allocator, &.{ contexts_dir_path, entry.name });
        errdefer allocator.free(full_path);

        try sessions.append(allocator, .{
            .id = try allocator.dupe(u8, entry.name),
            .path = full_path,
            .title = title,
            .modified_time = stat.mtime,
            .turn_count = 0,
            .file_size = @intCast(stat.size),
            .size_str = try formatSize(allocator, stat.size),
        });
    }

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
    // Compatibility shim for call sites that only check path existence.
    return contextSnapshotPathAlloc(allocator, base_path, project_hash);
}

pub fn loadContextWindow(allocator: std.mem.Allocator, base_path: []const u8, window: *ContextWindow, project_hash: u64) !void {
    const path = try contextSnapshotPathAlloc(allocator, base_path, project_hash);
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
    const SnapshotJson = struct {
        schema_version: u32 = 2,
        summary: ?[]const u8 = null,
        title: ?[]const u8 = null,
        project_path: ?[]const u8 = null,
        last_event_seq: usize = 0,
        turns: []const TurnJson = &.{},
    };

    var parsed = std.json.parseFromSlice(SnapshotJson, allocator, text, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    if (parsed.value.schema_version != 2) return;

    if (window.summary) |existing| allocator.free(existing);
    window.summary = null;
    if (window.title) |existing| allocator.free(existing);
    window.title = null;
    if (window.project_path) |existing| allocator.free(existing);
    window.project_path = null;

    while (window.turns.items.len > 0) {
        var turn = window.turns.pop().?;
        turn.deinit(allocator);
    }

    if (parsed.value.summary) |s| window.summary = try allocator.dupe(u8, s);
    if (parsed.value.title) |t| window.title = try allocator.dupe(u8, t);
    if (parsed.value.project_path) |p| window.project_path = try allocator.dupe(u8, p);

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

    const contexts_root = try std.fs.path.join(allocator, &.{ base_path, paths.CONTEXTS_V2_DIR_NAME });
    defer allocator.free(contexts_root);
    std.fs.makeDirAbsolute(contexts_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const project_dir = try contextProjectDirAlloc(allocator, base_path, project_hash);
    defer allocator.free(project_dir);

    std.fs.makeDirAbsolute(project_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const meta_path = try contextMetaPathAlloc(allocator, base_path, project_hash);
    defer allocator.free(meta_path);
    const snapshot_path = try contextSnapshotPathAlloc(allocator, base_path, project_hash);
    defer allocator.free(snapshot_path);
    const events_path = try contextEventsPathAlloc(allocator, base_path, project_hash);
    defer allocator.free(events_path);

    logger.info("Saving context to {s}...", .{snapshot_path});

    const TurnJson = struct {
        role: []const u8,
        content: []const u8,
        reasoning: ?[]const u8,
        tool_calls: usize,
        error_count: usize,
        files_touched: ?[]const u8,
    };
    const SnapshotJson = struct {
        schema_version: u32,
        summary: ?[]const u8,
        title: ?[]const u8,
        project_path: ?[]const u8,
        last_event_seq: usize,
        turns: []TurnJson,
    };
    const MetaJson = struct {
        schema_version: u32,
        project_id: []const u8,
        project_root: ?[]const u8,
        turn_count: usize,
    };
    const EventJson = struct {
        schema_version: u32,
        event_seq: usize,
        event_type: []const u8,
        role: []const u8,
        content: []const u8,
    };

    var turns: std.ArrayListUnmanaged(TurnJson) = .empty;
    defer turns.deinit(allocator);
    var events: std.ArrayListUnmanaged(EventJson) = .empty;
    defer events.deinit(allocator);

    for (window.turns.items, 0..) |turn, idx| {
        const role = if (turn.role == .assistant) "assistant" else "user";
        try turns.append(allocator, .{
            .role = role,
            .content = turn.content,
            .reasoning = turn.reasoning,
            .tool_calls = turn.tool_calls,
            .error_count = turn.error_count,
            .files_touched = turn.files_touched,
        });
        try events.append(allocator, .{
            .schema_version = 2,
            .event_seq = idx + 1,
            .event_type = "turn",
            .role = role,
            .content = turn.content,
        });
    }

    const project_id = try contextProjectIdAlloc(allocator, project_hash);
    defer allocator.free(project_id);

    const meta_payload = MetaJson{
        .schema_version = 2,
        .project_id = project_id,
        .project_root = window.project_path,
        .turn_count = window.turns.items.len,
    };

    var meta_out: std.ArrayListUnmanaged(u8) = .empty;
    defer meta_out.deinit(allocator);
    try meta_out.writer(allocator).print("{f}\n", .{std.json.fmt(meta_payload, .{})});

    var meta_file = try std.fs.createFileAbsolute(meta_path, .{});
    defer meta_file.close();
    try meta_file.writeAll(meta_out.items);

    const snapshot_payload = SnapshotJson{
        .schema_version = 2,
        .summary = window.summary,
        .title = window.title,
        .project_path = window.project_path,
        .last_event_seq = window.turns.items.len,
        .turns = turns.items,
    };

    var snapshot_out: std.ArrayListUnmanaged(u8) = .empty;
    defer snapshot_out.deinit(allocator);
    try snapshot_out.writer(allocator).print("{f}\n", .{std.json.fmt(snapshot_payload, .{})});

    var snapshot_file = try std.fs.createFileAbsolute(snapshot_path, .{});
    defer snapshot_file.close();
    try snapshot_file.writeAll(snapshot_out.items);

    var events_file = try std.fs.createFileAbsolute(events_path, .{});
    defer events_file.close();
    for (events.items) |ev| {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        defer line.deinit(allocator);
        try line.writer(allocator).print("{f}\n", .{std.json.fmt(ev, .{})});
        try events_file.writeAll(line.items);
    }

    logger.info("Saved context ({d} turns, {d} bytes)", .{ window.turns.items.len, snapshot_out.items.len });
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
        const content = if (turn.role == .assistant) stripRunMetadataSuffix(turn.content) else turn.content;
        const cap_len = @min(content.len, 220);
        try summary_buf.writer(allocator).print("- {s}: {s}\n", .{ prefix, content[0..cap_len] });
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
        const content = if (turn.role == .assistant) stripRunMetadataSuffix(turn.content) else turn.content;
        try w.print("- {s}: {s}\n", .{ role, content });
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
            const content = if (turn.role == .assistant) stripRunMetadataSuffix(turn.content) else turn.content;
            try w.print("{s}: {s}\n", .{ tag, content });
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
    try w.writeAll("{\"role\":\"system\",\"content\":");
    var sys_content: std.ArrayListUnmanaged(u8) = .empty;
    defer sys_content.deinit(allocator);
    const sw = sys_content.writer(allocator);
    try sw.writeAll("You are continuing an existing coding conversation. Use prior context when relevant, but prioritize correctness and current repository state.");
    if (window.summary) |s| {
        try sw.writeAll("\n\nConversation summary:\n");
        try sw.writeAll(s);
    }
    try w.print("{f}", .{std.json.fmt(sys_content.items, .{})});
    try w.writeAll("},");

    // 2. Prior turns (full loaded context window, chronological)
    for (window.turns.items) |turn| {
        // Avoid duplicating the current user request in relevant turns.
        // The current request is appended explicitly below, so any matching
        // user turn here is redundant and can cause duplicated prompts.
        if (turn.role == .user and std.mem.eql(u8, turn.content, user_input)) {
            continue;
        }
        try w.writeAll("{\"role\":");
        try w.print("{f}", .{std.json.fmt(if (turn.role == .user) "user" else "assistant", .{})});
        try w.writeAll(",\"content\":");
        const content = if (turn.role == .assistant) stripRunMetadataSuffix(turn.content) else turn.content;
        try w.print("{f}", .{std.json.fmt(content, .{})});
        try w.writeAll("},");
    }

    // 3. Current request
    try w.writeAll("{\"role\":\"user\",\"content\":");
    try w.print("{f}", .{std.json.fmt(user_input, .{})});
    try w.writeAll("}]");

    return out.toOwnedSlice(allocator);
}

test "saveContextWindow writes v2 context layout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    var window = ContextWindow.init(32000, 20);
    defer window.deinit(allocator);

    try window.append(allocator, .user, "hello", .{});
    try window.append(allocator, .assistant, "world", .{});

    const hash: u64 = 0x1a2b3c;
    try saveContextWindow(allocator, base, &window, hash);

    const project_id = try std.fmt.allocPrint(allocator, "{x}", .{hash});
    defer allocator.free(project_id);

    const meta_path = try std.fs.path.join(allocator, &.{ base, paths.CONTEXTS_V2_DIR_NAME, project_id, "meta.json" });
    defer allocator.free(meta_path);
    const snapshot_path = try std.fs.path.join(allocator, &.{ base, paths.CONTEXTS_V2_DIR_NAME, project_id, "snapshot.json" });
    defer allocator.free(snapshot_path);
    const events_path = try std.fs.path.join(allocator, &.{ base, paths.CONTEXTS_V2_DIR_NAME, project_id, "events.ndjson" });
    defer allocator.free(events_path);

    var meta_file = try std.fs.openFileAbsolute(meta_path, .{});
    defer meta_file.close();
    var snapshot_file = try std.fs.openFileAbsolute(snapshot_path, .{});
    defer snapshot_file.close();
    var events_file = try std.fs.openFileAbsolute(events_path, .{});
    defer events_file.close();
}

test "loadContextWindow ignores legacy v1 context files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);

    const hash: u64 = 0x55aa;
    const legacy_filename = try std.fmt.allocPrint(allocator, "context-{x}.json", .{hash});
    defer allocator.free(legacy_filename);

    const legacy_dir = try std.fs.path.join(allocator, &.{ base, paths.CONTEXTS_DIR_NAME });
    defer allocator.free(legacy_dir);
    try std.fs.makeDirAbsolute(legacy_dir);

    const legacy_path = try std.fs.path.join(allocator, &.{ legacy_dir, legacy_filename });
    defer allocator.free(legacy_path);

    var f = try std.fs.createFileAbsolute(legacy_path, .{});
    defer f.close();
    try f.writeAll("{\"summary\":null,\"turns\":[{\"role\":\"user\",\"content\":\"legacy\"}]}");

    var window = ContextWindow.init(32000, 20);
    defer window.deinit(allocator);

    try loadContextWindow(allocator, base, &window, hash);
    try std.testing.expectEqual(@as(usize, 0), window.turns.items.len);
}
