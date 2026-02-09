const std = @import("std");
const skills = @import("skills.zig");
const tools = @import("tools.zig");
const pm = @import("provider_manager.zig");
const store = @import("provider_store.zig");
const config_store = @import("config_store.zig");
const llm = @import("llm.zig");
const catalog = @import("models_catalog.zig");
const logger = @import("logger.zig");
const todo = @import("todo.zig");
const ai_bridge = @import("ai_bridge.zig");

// Global cancellation flag for interrupting work
var g_cancel_requested: bool = false;

// Helper to convert tools.ToolDef slice to llm.ToolRouteDef slice
fn toolDefsToLlm(defs: []const tools.ToolDef) []const llm.ToolRouteDef {
    // Safety: ToolDef and ToolRouteDef have identical layout
    return @ptrCast(defs);
}

fn isCancelled() bool {
    return g_cancel_requested;
}

fn setCancelled() void {
    g_cancel_requested = true;
}

fn resetCancelled() void {
    g_cancel_requested = false;
}

pub const CommandTag = enum {
    none,
    quit,
    list_skills,
    load_skill,
    list_tools,
    run_tool,
    list_providers,
    default_model,
    connect_provider,
    set_model,
};

pub const Command = struct {
    tag: CommandTag,
    arg: []const u8,
};

pub fn parseCommand(line: []const u8) Command {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .{ .tag = .none, .arg = "" };

    if (std.mem.eql(u8, trimmed, "/quit")) {
        return .{ .tag = .quit, .arg = "" };
    }
    if (std.mem.eql(u8, trimmed, "/skills")) {
        return .{ .tag = .list_skills, .arg = "" };
    }
    if (std.mem.eql(u8, trimmed, "/tools")) {
        return .{ .tag = .list_tools, .arg = "" };
    }
    if (std.mem.startsWith(u8, trimmed, "/skill")) {
        var rest = trimmed[6..];
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len > 0) {
            return .{ .tag = .load_skill, .arg = rest };
        }
    }
    if (std.mem.startsWith(u8, trimmed, "/tool")) {
        var rest = trimmed[5..];
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len > 0) {
            return .{ .tag = .run_tool, .arg = rest };
        }
    }
    if (std.mem.eql(u8, trimmed, "/providers")) {
        return .{ .tag = .list_providers, .arg = "" };
    }
    if (std.mem.startsWith(u8, trimmed, "/default-model")) {
        var rest = trimmed[14..];
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len > 0) {
            return .{ .tag = .default_model, .arg = rest };
        }
    }
    if (std.mem.startsWith(u8, trimmed, "/connect")) {
        var rest = trimmed[8..];
        rest = std.mem.trim(u8, rest, " \t");
        return .{ .tag = .connect_provider, .arg = rest };
    }
    if (std.mem.startsWith(u8, trimmed, "/model")) {
        var rest = trimmed[6..];
        rest = std.mem.trim(u8, rest, " \t");
        return .{ .tag = .set_model, .arg = rest };
    }

    return .{ .tag = .none, .arg = "" };
}

fn autocompleteCommand(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) return trimmed;

    const commands = commandNames();
    var matches: usize = 0;
    var winner: []const u8 = trimmed;

    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd, trimmed)) return trimmed;
        if (std.mem.startsWith(u8, cmd, trimmed)) {
            matches += 1;
            winner = cmd;
        }
    }

    return if (matches == 1) winner else trimmed;
}

const EditKey = enum {
    tab,
    backspace,
    enter,
    character,
    left,
    right,
    home,
    end,
    delete,
};

const AuthMethod = enum {
    api,
    subscription,
};

const OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENAI_ISSUER = "https://auth.openai.com";

const HistoryNav = enum {
    up,
    down,
};

const Role = enum {
    user,
    assistant,
};

const ContextTurn = struct {
    role: Role,
    content: []u8,
    tool_calls: usize,
    error_count: usize,
    files_touched: ?[]u8,

    fn deinit(self: *ContextTurn, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.files_touched) |f| allocator.free(f);
    }
};

const TurnMeta = struct {
    tool_calls: usize = 0,
    error_count: usize = 0,
    files_touched: ?[]const u8 = null,
};

const RunTurnResult = struct {
    response: []u8,
    tool_calls: usize,
    error_count: usize,
    files_touched: ?[]u8,

    fn deinit(self: *RunTurnResult, allocator: std.mem.Allocator) void {
        allocator.free(self.response);
        if (self.files_touched) |f| allocator.free(f);
    }
};

const ContextWindow = struct {
    turns: std.ArrayList(ContextTurn),
    summary: ?[]u8,
    max_chars: usize,
    keep_recent_turns: usize,

    fn init(max_chars: usize, keep_recent_turns: usize) ContextWindow {
        return .{
            .turns = .{},
            .summary = null,
            .max_chars = max_chars,
            .keep_recent_turns = keep_recent_turns,
        };
    }

    fn deinit(self: *ContextWindow, allocator: std.mem.Allocator) void {
        for (self.turns.items) |*turn| turn.deinit(allocator);
        self.turns.deinit(allocator);
        if (self.summary) |s| allocator.free(s);
    }

    fn append(self: *ContextWindow, allocator: std.mem.Allocator, role: Role, content: []const u8, meta: TurnMeta) !void {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len == 0) return;
        try self.turns.append(allocator, .{
            .role = role,
            .content = try allocator.dupe(u8, trimmed),
            .tool_calls = meta.tool_calls,
            .error_count = meta.error_count,
            .files_touched = if (meta.files_touched) |f| try allocator.dupe(u8, f) else null,
        });
    }
};

const CommandHistory = struct {
    items: std.ArrayList([]u8),

    fn init() CommandHistory {
        return .{ .items = .{} };
    }

    fn deinit(self: *CommandHistory, allocator: std.mem.Allocator) void {
        for (self.items.items) |entry| allocator.free(entry);
        self.items.deinit(allocator);
    }

    fn append(self: *CommandHistory, allocator: std.mem.Allocator, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], trimmed)) return;
        try self.items.append(allocator, try allocator.dupe(u8, trimmed));
    }
};

fn historyPathAlloc(allocator: std.mem.Allocator, base_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_path, "history" });
}

fn loadHistory(allocator: std.mem.Allocator, base_path: []const u8, history: *CommandHistory) !void {
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

fn appendHistoryLine(allocator: std.mem.Allocator, base_path: []const u8, line: []const u8) !void {
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

fn hashProjectPath(cwd: []const u8) u64 {
    // Simple hash of project path for filename
    return std.hash.Crc32.hash(cwd);
}

fn contextPathAlloc(allocator: std.mem.Allocator, base_path: []const u8, project_hash: u64) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "context-{x}.json", .{project_hash});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ base_path, filename });
}

fn loadContextWindow(allocator: std.mem.Allocator, base_path: []const u8, window: *ContextWindow, project_hash: u64) !void {
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
        tool_calls: ?usize = null,
        error_count: ?usize = null,
        files_touched: ?[]const u8 = null,
    };
    const ContextJson = struct {
        summary: ?[]const u8 = null,
        turns: []const TurnJson = &.{},
    };

    var parsed = std.json.parseFromSlice(ContextJson, allocator, text, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();

    if (parsed.value.summary) |s| {
        if (window.summary) |existing| allocator.free(existing);
        window.summary = try allocator.dupe(u8, s);
    }

    for (parsed.value.turns) |turn| {
        const role: Role = if (std.mem.eql(u8, turn.role, "assistant")) .assistant else .user;
        try window.append(allocator, role, turn.content, .{
            .tool_calls = turn.tool_calls orelse 0,
            .error_count = turn.error_count orelse 0,
            .files_touched = turn.files_touched,
        });
    }
}

fn saveContextWindow(allocator: std.mem.Allocator, base_path: []const u8, window: *const ContextWindow, project_hash: u64) !void {
    const path = try contextPathAlloc(allocator, base_path, project_hash);
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const TurnJson = struct {
        role: []const u8,
        content: []const u8,
        tool_calls: usize,
        error_count: usize,
        files_touched: ?[]const u8,
    };
    const ContextJson = struct {
        summary: ?[]const u8,
        turns: []TurnJson,
    };

    var turns = try std.ArrayList(TurnJson).initCapacity(allocator, window.turns.items.len);
    defer turns.deinit(allocator);
    for (window.turns.items) |turn| {
        try turns.append(allocator, .{
            .role = if (turn.role == .assistant) "assistant" else "user",
            .content = turn.content,
            .tool_calls = turn.tool_calls,
            .error_count = turn.error_count,
            .files_touched = turn.files_touched,
        });
    }

    const payload = ContextJson{ .summary = window.summary, .turns = turns.items };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.writer(allocator).print("{f}\n", .{std.json.fmt(payload, .{})});

    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

fn estimateContextChars(window: *const ContextWindow) usize {
    var total: usize = if (window.summary) |s| s.len else 0;
    for (window.turns.items) |turn| total += turn.content.len + 20;
    return total;
}

fn compactContextWindow(allocator: std.mem.Allocator, window: *ContextWindow, active: ?ActiveModel) !void {
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

fn buildHeuristicSummary(allocator: std.mem.Allocator, window: *const ContextWindow, compact_count: usize) ![]u8 {
    var summary_buf = std.ArrayList(u8).empty;
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
    var turns_buf = std.ArrayList(u8).empty;
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

    const text = llm.query(allocator, active.provider_id, active.api_key, active.model_id, prompt, toolDefsToLlm(tools.definitions[0..])) catch return null;
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
        allocator.free(text);
        return null;
    }
    return text;
}

fn buildRelevantTurnIndices(allocator: std.mem.Allocator, window: *const ContextWindow, user_input: []const u8, max_turns: usize) ![]usize {
    const ScoredTurn = struct { idx: usize, score: usize };
    var scored = std.ArrayList(ScoredTurn).empty;
    defer scored.deinit(allocator);

    for (window.turns.items, 0..) |turn, idx| {
        var score: usize = 0;
        if (containsIgnoreCase(turn.content, user_input)) score += 4;
        if (containsIgnoreCase(user_input, "file") and turn.files_touched != null) score += 2;
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
    var selected = std.ArrayList(usize).empty;
    defer selected.deinit(allocator);
    var i: usize = 0;
    while (i < take) : (i += 1) {
        try selected.append(allocator, scored.items[i].idx);
    }

    std.mem.sort(usize, selected.items, {}, std.sort.asc(usize));
    return selected.toOwnedSlice(allocator);
}

fn buildContextPrompt(allocator: std.mem.Allocator, window: *const ContextWindow, user_input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
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

fn historyNextIndex(entries: []const []const u8, current: ?usize, nav: HistoryNav) ?usize {
    if (entries.len == 0) return null;
    return switch (nav) {
        .up => if (current) |idx| if (idx > 0) idx - 1 else 0 else entries.len - 1,
        .down => if (current) |idx| if (idx + 1 < entries.len) idx + 1 else null else null,
    };
}

const ActiveModel = struct {
    provider_id: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
};

const ModelOption = struct {
    provider_id: []const u8,
    model_id: []const u8,
    display_name: []const u8,
};

const ModelSelection = struct {
    provider_id: []const u8,
    model_id: []const u8,
};

fn stdInFile() std.fs.File {
    if (@hasDecl(std.fs.File, "stdin")) {
        return std.fs.File.stdin();
    }
    if (@hasDecl(std.io, "getStdIn")) {
        return std.io.getStdIn();
    }
    @compileError("No supported stdin API in this Zig version");
}

fn stdOutFile() std.fs.File {
    if (@hasDecl(std.fs.File, "stdout")) {
        return std.fs.File.stdout();
    }
    if (@hasDecl(std.io, "getStdOut")) {
        return std.io.getStdOut();
    }
    @compileError("No supported stdout API in this Zig version");
}

fn parseModelSelection(input: []const u8) ?ModelSelection {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return null;
    if (slash == 0 or slash + 1 >= trimmed.len) return null;
    return .{
        .provider_id = trimmed[0..slash],
        .model_id = trimmed[slash + 1 ..],
    };
}

fn buildPrompt(allocator: std.mem.Allocator, cwd: []const u8, selected_model: ?OwnedModelSelection) ![]u8 {
    if (selected_model) |model| {
        // Shorten model name if it's long
        const max_model_len = 20;
        const display_model = if (model.model_id.len > max_model_len)
            model.model_id[0..max_model_len]
        else
            model.model_id;
        return std.fmt.allocPrint(allocator, "{s} [{s}/{s}]> ", .{ cwd, model.provider_id, display_model });
    } else {
        return std.fmt.allocPrint(allocator, "{s}> ", .{cwd});
    }
}

const OwnedModelSelection = struct {
    provider_id: []u8,
    model_id: []u8,

    fn deinit(self: *OwnedModelSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model_id);
    }
};

fn applyEditKey(
    allocator: std.mem.Allocator,
    current: []const u8,
    key: EditKey,
    character: u8,
) ![]u8 {
    return switch (key) {
        .tab => allocator.dupe(u8, autocompleteCommand(current)),
        .backspace => {
            if (current.len == 0) return allocator.dupe(u8, current);
            return allocator.dupe(u8, current[0 .. current.len - 1]);
        },
        .character => {
            if (character < 32 or character == 127) return allocator.dupe(u8, current);
            var out = try allocator.alloc(u8, current.len + 1);
            @memcpy(out[0..current.len], current);
            out[current.len] = character;
            return out;
        },
        .enter => allocator.dupe(u8, current),
        else => allocator.dupe(u8, current), // Cursor movement keys don't change text
    };
}

const LineEditResult = struct {
    text: []u8,
    cursor_pos: usize,
};

fn applyEditKeyAtCursor(
    allocator: std.mem.Allocator,
    current: []const u8,
    key: EditKey,
    character: u8,
    cursor_pos: usize,
) !LineEditResult {
    const pos = @min(cursor_pos, current.len);

    return switch (key) {
        .tab => {
            const text = try allocator.dupe(u8, autocompleteCommand(current));
            return .{ .text = text, .cursor_pos = text.len };
        },
        .backspace => {
            if (pos == 0) {
                const text = try allocator.dupe(u8, current);
                return .{ .text = text, .cursor_pos = 0 };
            }
            const new_len = current.len - 1;
            const text = try allocator.alloc(u8, new_len);
            @memcpy(text[0 .. pos - 1], current[0 .. pos - 1]);
            @memcpy(text[pos - 1 ..], current[pos..]);
            return .{ .text = text, .cursor_pos = pos - 1 };
        },
        .delete => {
            if (pos >= current.len) {
                const text = try allocator.dupe(u8, current);
                return .{ .text = text, .cursor_pos = pos };
            }
            const new_len = current.len - 1;
            const text = try allocator.alloc(u8, new_len);
            @memcpy(text[0..pos], current[0..pos]);
            @memcpy(text[pos..], current[pos + 1 ..]);
            return .{ .text = text, .cursor_pos = pos };
        },
        .character => {
            if (character < 32 or character == 127) {
                const text = try allocator.dupe(u8, current);
                return .{ .text = text, .cursor_pos = pos };
            }
            const text = try allocator.alloc(u8, current.len + 1);
            @memcpy(text[0..pos], current[0..pos]);
            text[pos] = character;
            @memcpy(text[pos + 1 ..], current[pos..]);
            return .{ .text = text, .cursor_pos = pos + 1 };
        },
        .left => {
            const text = try allocator.dupe(u8, current);
            return .{ .text = text, .cursor_pos = if (pos > 0) pos - 1 else 0 };
        },
        .right => {
            const text = try allocator.dupe(u8, current);
            return .{ .text = text, .cursor_pos = if (pos < current.len) pos + 1 else current.len };
        },
        .home => {
            const text = try allocator.dupe(u8, current);
            return .{ .text = text, .cursor_pos = 0 };
        },
        .end => {
            const text = try allocator.dupe(u8, current);
            return .{ .text = text, .cursor_pos = current.len };
        },
        .enter => {
            const text = try allocator.dupe(u8, current);
            return .{ .text = text, .cursor_pos = pos };
        },
    };
}

fn renderLine(stdout: anytype, prompt: []const u8, line: []const u8, cursor_pos: usize) !void {
    // Clear current line and all lines below (handles wrapping)
    try stdout.print("\r\x1b[2K\x1b[J", .{});

    // Redraw prompt and line
    try stdout.print("{s}{s}", .{ prompt, line });

    // Move cursor to correct position
    if (cursor_pos < line.len) {
        const move_back = line.len - cursor_pos;
        try stdout.print("\x1b[{d}D", .{move_back});
    }
}

pub fn run(allocator: std.mem.Allocator) !void {
    const stdin_file = stdInFile();
    const stdin = if (@hasDecl(std.fs.File, "deprecatedReader"))
        stdin_file.deprecatedReader()
    else
        stdin_file.reader();
    const stdout_file = stdOutFile();
    const stdout = if (@hasDecl(std.fs.File, "deprecatedWriter"))
        stdout_file.deprecatedWriter()
    else
        stdout_file.writer();
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    // Compute project hash for project-aware storage
    const project_hash = hashProjectPath(cwd);

    const home = std.posix.getenv("HOME") orelse "";
    const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "zagent" });
    defer allocator.free(config_dir);
    try std.fs.cwd().makePath(config_dir);

    const skill_list = try skills.discover(allocator, cwd, home);
    defer skills.freeList(allocator, skill_list);

    const providers = defaultProviderSpecs();
    var stored_pairs = try store.load(allocator, config_dir);
    defer store.free(allocator, stored_pairs);

    var provider_states = try resolveProviderStates(allocator, providers, stored_pairs);
    defer pm.ProviderManager.freeResolved(allocator, provider_states);

    var history = CommandHistory.init();
    defer history.deinit(allocator);
    try loadHistory(allocator, config_dir, &history);

    var context_window = ContextWindow.init(24 * 1024, 8);
    defer context_window.deinit(allocator);
    try loadContextWindow(allocator, config_dir, &context_window, project_hash);
    try compactContextWindow(allocator, &context_window, null);

    // Initialize todo list for tracking progress
    var todo_list = todo.TodoList.init(allocator);
    defer todo_list.deinit();

    // Load persisted todos (project-aware)
    const todos_filename = try std.fmt.allocPrint(allocator, "todos-{x}.json", .{project_hash});
    defer allocator.free(todos_filename);
    const todos_file = try std.fs.path.join(allocator, &.{ config_dir, todos_filename });
    defer allocator.free(todos_file);
    try todo_list.loadFromFile(allocator, todos_file);

    // Helper to save todos (called after modifications)
    const saveTodos = struct {
        fn call(tl: *todo.TodoList, alloc: std.mem.Allocator, path: []const u8) void {
            tl.saveToFile(alloc, path) catch |e| {
                logger.info("Failed to save todos: {s}\n", .{@errorName(e)});
            };
        }
    }.call;

    var selected_model: ?OwnedModelSelection = null;
    defer if (selected_model) |*sel| sel.deinit(allocator);

    const persisted_model = try config_store.loadSelectedModel(allocator, config_dir);
    if (persisted_model) |persisted| {
        selected_model = .{
            .provider_id = persisted.provider_id,
            .model_id = persisted.model_id,
        };
    }

    try stdout.print(
        "zagent MVP. Commands: /skills, /skill <name>, /tools, /tool <spec>, /providers, /default-model <provider>, /model <provider/model>, /connect, /quit\n",
        .{},
    );
    while (true) {
        // Reset cancellation flag at start of each iteration
        resetCancelled();

        // Build prompt dynamically with current model info
        const prompt_text = try buildPrompt(allocator, cwd, selected_model);
        defer allocator.free(prompt_text);

        const line_opt = try readPromptLine(allocator, stdin_file, stdin, stdout, prompt_text, &history);
        if (line_opt == null) {
            try stdout.print("\n", .{});
            break;
        }

        const line = line_opt.?;
        defer allocator.free(line);

        // Check if user cancelled with ESC
        if (line.len == 0 and isCancelled()) {
            continue; // Skip processing if cancelled
        }

        const prev_history_len = history.items.items.len;
        try history.append(allocator, line);
        if (history.items.items.len > prev_history_len) {
            try appendHistoryLine(allocator, config_dir, line);
        }

        const normalized = autocompleteCommand(line);
        if (!std.mem.eql(u8, normalized, std.mem.trim(u8, line, " \t\r\n"))) {
            try stdout.print("autocompleted: {s}\n", .{normalized});
        }

        const command = parseCommand(normalized);
        switch (command.tag) {
            .quit => break,
            .list_skills => {
                if (skill_list.len == 0) {
                    try stdout.print("No skills found.\n", .{});
                    continue;
                }
                for (skill_list) |skill| {
                    try stdout.print("- {s} ({s})\n", .{ skill.name, skill.path });
                }
            },
            .load_skill => {
                const skill = skills.findByName(skill_list, command.arg);
                if (skill) |s| {
                    try stdout.print("Loaded skill: {s}\n\n{s}\n", .{ s.name, s.body });
                } else {
                    try stdout.print("Skill not found: {s}\n", .{command.arg});
                }
            },
            .list_tools => {
                for (tools.list()) |tool_name| {
                    try stdout.print("- {s}\n", .{tool_name});
                }
            },
            .run_tool => {
                logger.info("Executing tool: {s}", .{command.arg});
                const output = tools.execute(allocator, command.arg) catch |err| {
                    logger.logErrorWithContext(@src(), err, "Tool execution failed", command.arg);
                    try stdout.print("Tool failed: {s}\n", .{@errorName(err)});
                    continue;
                };
                defer allocator.free(output);

                logger.info("Tool succeeded: {s}", .{command.arg});
                try stdout.print("{s}\n", .{output});
            },
            .list_providers => {
                const view = try formatProvidersOutput(allocator, providers, provider_states);
                defer allocator.free(view);
                try stdout.print("{s}", .{view});
            },
            .default_model => {
                var found: ?pm.ProviderState = null;
                for (provider_states) |p| {
                    if (std.mem.eql(u8, p.id, command.arg)) {
                        found = p;
                        break;
                    }
                }
                if (found == null) {
                    try stdout.print("Provider not connected: {s}\n", .{command.arg});
                    continue;
                }

                const model_id = pm.ProviderManager.defaultModelIDForProvider(found.?.id, found.?.models);
                if (model_id) |id| {
                    try stdout.print("Default model for {s}: {s}\n", .{ found.?.id, id });
                } else {
                    try stdout.print("No models configured for {s}\n", .{found.?.id});
                }
            },
            .connect_provider => {
                const chosen = if (command.arg.len > 0)
                    findProviderSpecByID(providers, command.arg)
                else
                    try chooseProvider(allocator, stdin, stdout, providers, provider_states);
                if (chosen == null) {
                    if (command.arg.len > 0) {
                        try stdout.print("Unknown provider: {s}\n", .{command.arg});
                    }
                    continue;
                }

                const provider = chosen.?;
                if (provider.env_vars.len == 0) {
                    try stdout.print("Provider {s} has no API key env mapping.\n", .{provider.id});
                    continue;
                }

                var method: AuthMethod = .api;
                if (supportsSubscription(provider.id)) {
                    const method_opt = try promptLine(allocator, stdin, stdout, "Auth method [api/subscription] (default api): ");
                    if (method_opt) |raw| {
                        defer allocator.free(raw);
                        method = chooseAuthMethod(std.mem.trim(u8, raw, " \t\r\n"), true);
                    }
                }

                const env_name = provider.env_vars[0];
                var key_slice: []const u8 = "";
                var owned_key: ?[]u8 = null;
                defer if (owned_key) |k| allocator.free(k);

                if (method == .subscription) {
                    const sub_key = try connectSubscription(allocator, stdin, stdout, provider.id);
                    if (sub_key == null) continue;
                    owned_key = sub_key.?;
                    key_slice = owned_key.?;
                } else {
                    const key_opt = try promptRawLine(allocator, stdin, stdout, "API key: ");
                    if (key_opt == null) continue;
                    const key = std.mem.trim(u8, key_opt.?, " \t\r\n");
                    if (key.len == 0) {
                        allocator.free(key_opt.?);
                        try stdout.print("Cancelled: empty key.\n", .{});
                        continue;
                    }
                    // Copy the key before freeing key_opt
                    owned_key = try allocator.dupe(u8, key);
                    allocator.free(key_opt.?);
                    key_slice = owned_key.?;
                }

                logger.info("Storing API key for provider: {s}", .{provider.id});
                store.upsertFile(allocator, config_dir, env_name, key_slice) catch |err| {
                    logger.logErrorWithContext(@src(), err, "Failed to store API key", provider.id);
                    try stdout.print("Failed to store API key: {s}\n", .{@errorName(err)});
                    continue;
                };
                logger.info("Successfully stored API key for: {s}", .{provider.id});
                try stdout.print("Stored {s} in {s}/providers.env\n", .{ env_name, config_dir });

                store.free(allocator, stored_pairs);
                stored_pairs = try store.load(allocator, config_dir);

                pm.ProviderManager.freeResolved(allocator, provider_states);
                provider_states = try resolveProviderStates(allocator, providers, stored_pairs);
            },
            .set_model => {
                if (command.arg.len == 0) {
                    if (selected_model) |sel| {
                        try stdout.print("Current model: {s}/{s}\n", .{ sel.provider_id, sel.model_id });
                    } else {
                        try stdout.print("No model currently set.\n", .{});
                    }

                    const picked = try interactiveModelSelect(allocator, stdin, stdout, stdin_file, providers, provider_states);
                    if (picked == null) {
                        try stdout.print("No explicit model set. Using default connected provider model.\n", .{});
                        continue;
                    }
                    if (selected_model) |*old| old.deinit(allocator);
                    selected_model = .{
                        .provider_id = try allocator.dupe(u8, picked.?.provider_id),
                        .model_id = try allocator.dupe(u8, picked.?.model_id),
                    };
                    try config_store.saveSelectedModel(allocator, config_dir, .{
                        .provider_id = picked.?.provider_id,
                        .model_id = picked.?.model_id,
                    });
                    try stdout.print("Active model set to {s}/{s}\n", .{ picked.?.provider_id, picked.?.model_id });
                    continue;
                }
                const parsed = parseModelSelection(command.arg);
                if (parsed == null) {
                    try stdout.print("Model must be in format provider/model\n", .{});
                    continue;
                }
                const p = parsed.?;
                if (findConnectedProvider(provider_states, p.provider_id) == null) {
                    try stdout.print("Provider not connected: {s}\n", .{p.provider_id});
                    continue;
                }
                if (!providerHasModel(providers, p.provider_id, p.model_id)) {
                    try stdout.print("Unknown model: {s}/{s}\n", .{ p.provider_id, p.model_id });
                    continue;
                }

                if (selected_model) |*old| old.deinit(allocator);
                selected_model = .{
                    .provider_id = try allocator.dupe(u8, p.provider_id),
                    .model_id = try allocator.dupe(u8, p.model_id),
                };
                try config_store.saveSelectedModel(allocator, config_dir, .{
                    .provider_id = p.provider_id,
                    .model_id = p.model_id,
                });
                try stdout.print("Active model set to {s}/{s}\n", .{ p.provider_id, p.model_id });
            },
            .none => {
                const trimmed = std.mem.trim(u8, normalized, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (trimmed[0] == '/') {
                    try stdout.print("Unknown command: {s}\n", .{trimmed});
                    continue;
                }

                const active = chooseActiveModel(providers, provider_states, selected_model);

                if (active == null) {
                    try stdout.print("No connected providers. Run /providers then /connect <provider-id>.\n", .{});
                    continue;
                }

                const model_input = try buildContextPrompt(allocator, &context_window, trimmed);
                defer allocator.free(model_input);

                var turn = runWithBridge(allocator, stdout, active.?, trimmed, model_input, &todo_list) catch |err| {
                    try stdout.print("Model query failed: {s}\n", .{@errorName(err)});
                    continue;
                };
                defer turn.deinit(allocator);

                // Save todos after model turn completes
                saveTodos(&todo_list, allocator, todos_file);

                try context_window.append(allocator, .user, trimmed, .{});
                try context_window.append(allocator, .assistant, turn.response, .{
                    .tool_calls = turn.tool_calls,
                    .error_count = turn.error_count,
                    .files_touched = turn.files_touched,
                });
                try compactContextWindow(allocator, &context_window, active.?);
                try saveContextWindow(allocator, config_dir, &context_window, project_hash);

                // Only print response if it's not a tool call instruction
                if (!std.mem.startsWith(u8, turn.response, "TOOL_CALL ")) {
                    try stdout.print("{s}{s}{s}\n", .{ C_BRIGHT_WHITE, turn.response, C_RESET });
                }
            },
        }
    }
}

fn readPromptLine(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdin_reader: anytype,
    stdout: anytype,
    prompt: []const u8,
    history: *CommandHistory,
) !?[]u8 {
    if (!stdin_file.isTty()) {
        try stdout.print("{s}", .{prompt});
        return stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    }

    return readPromptLineFallback(allocator, stdin_file, stdin_reader, stdout, prompt, history);
}

fn readPromptLineFallback(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdin_reader: anytype,
    stdout: anytype,
    prompt: []const u8,
    history: *CommandHistory,
) !?[]u8 {
    const original = std.posix.tcgetattr(stdin_file.handle) catch {
        try stdout.print("{s}", .{prompt});
        return stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    };
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    try std.posix.tcsetattr(stdin_file.handle, .NOW, raw);
    defer std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};

    var line = try allocator.alloc(u8, 0);
    defer allocator.free(line);
    var cursor_pos: usize = 0;
    var history_index: ?usize = null;

    try stdout.print("{s}", .{prompt});

    var byte_buf: [4]u8 = undefined;
    while (true) {
        const n = try stdin_file.read(byte_buf[0..1]);
        if (n == 0) {
            if (line.len == 0) return null;
            return try allocator.dupe(u8, line);
        }

        const ch = byte_buf[0];

        // Escape sequences (arrow keys, etc.) or bare ESC for cancellation
        if (ch == 27) {
            const n1 = try stdin_file.read(byte_buf[1..2]);
            if (n1 == 0) {
                // Bare ESC key pressed - signal cancellation
                setCancelled();
                try stdout.print("\n^C (cancelled)\n", .{});
                return try allocator.dupe(u8, ""); // Return empty line to indicate cancellation
            }

            if (byte_buf[1] == '[') {
                const n2 = try stdin_file.read(byte_buf[2..3]);
                if (n2 == 0) continue;

                // Handle arrow keys and navigation
                switch (byte_buf[2]) {
                    'A' => { // Up arrow - history
                        const next_index = historyNextIndex(history.items.items, history_index, .up);
                        history_index = next_index;
                        const entry = if (history_index) |idx| history.items.items[idx] else "";
                        allocator.free(line);
                        line = try allocator.dupe(u8, entry);
                        cursor_pos = line.len;
                        try renderLine(stdout, prompt, line, cursor_pos);
                        continue;
                    },
                    'B' => { // Down arrow - history
                        const next_index = historyNextIndex(history.items.items, history_index, .down);
                        history_index = next_index;
                        const entry = if (history_index) |idx| history.items.items[idx] else "";
                        allocator.free(line);
                        line = try allocator.dupe(u8, entry);
                        cursor_pos = line.len;
                        try renderLine(stdout, prompt, line, cursor_pos);
                        continue;
                    },
                    'C' => { // Right arrow
                        history_index = null;
                        const next = try applyEditKeyAtCursor(allocator, line, .right, 0, cursor_pos);
                        defer allocator.free(next.text);
                        line = try allocator.dupe(u8, next.text);
                        cursor_pos = next.cursor_pos;
                        try renderLine(stdout, prompt, line, cursor_pos);
                        continue;
                    },
                    'D' => { // Left arrow
                        history_index = null;
                        const next = try applyEditKeyAtCursor(allocator, line, .left, 0, cursor_pos);
                        defer allocator.free(next.text);
                        line = try allocator.dupe(u8, next.text);
                        cursor_pos = next.cursor_pos;
                        try renderLine(stdout, prompt, line, cursor_pos);
                        continue;
                    },
                    'H' => { // Home
                        history_index = null;
                        const next = try applyEditKeyAtCursor(allocator, line, .home, 0, cursor_pos);
                        defer allocator.free(next.text);
                        line = try allocator.dupe(u8, next.text);
                        cursor_pos = next.cursor_pos;
                        try renderLine(stdout, prompt, line, cursor_pos);
                        continue;
                    },
                    'F' => { // End
                        history_index = null;
                        const next = try applyEditKeyAtCursor(allocator, line, .end, 0, cursor_pos);
                        defer allocator.free(next.text);
                        line = try allocator.dupe(u8, next.text);
                        cursor_pos = next.cursor_pos;
                        try renderLine(stdout, prompt, line, cursor_pos);
                        continue;
                    },
                    '3' => { // Delete key (ESC[3~)
                        const n3 = try stdin_file.read(byte_buf[3..4]);
                        if (n3 > 0 and byte_buf[3] == '~') {
                            history_index = null;
                            const next = try applyEditKeyAtCursor(allocator, line, .delete, 0, cursor_pos);
                            defer allocator.free(next.text);
                            line = try allocator.dupe(u8, next.text);
                            cursor_pos = next.cursor_pos;
                            try renderLine(stdout, prompt, line, cursor_pos);
                        }
                        continue;
                    },
                    else => continue,
                }
            }
            continue;
        }

        // Enter key
        if (ch == '\n' or ch == '\r') {
            try stdout.print("\n", .{});
            return try allocator.dupe(u8, line);
        }

        // Ctrl+C
        if (ch == 3) {
            return null;
        }

        history_index = null;

        // Handle special keys
        const key: EditKey = switch (ch) {
            9 => .tab, // Tab
            127, 8 => .backspace, // Backspace
            else => .character,
        };

        const next = try applyEditKeyAtCursor(allocator, line, key, ch, cursor_pos);
        defer allocator.free(next.text);
        line = try allocator.dupe(u8, next.text);
        cursor_pos = next.cursor_pos;
        try renderLine(stdout, prompt, line, cursor_pos);
    }
}

test "parse command recognizes slash commands" {
    const list = parseCommand("/skills");
    try std.testing.expectEqual(CommandTag.list_skills, list.tag);

    const load = parseCommand("/skill brainstorming");
    try std.testing.expectEqual(CommandTag.load_skill, load.tag);
    try std.testing.expectEqualStrings("brainstorming", load.arg);

    const quit = parseCommand("/quit");
    try std.testing.expectEqual(CommandTag.quit, quit.tag);

    const tools_cmd = parseCommand("/tools");
    try std.testing.expectEqual(CommandTag.list_tools, tools_cmd.tag);

    const tool = parseCommand("/tool read ./README.md");
    try std.testing.expectEqual(CommandTag.run_tool, tool.tag);
    try std.testing.expectEqualStrings("read ./README.md", tool.arg);

    const providers = parseCommand("/providers");
    try std.testing.expectEqual(CommandTag.list_providers, providers.tag);

    const default_model = parseCommand("/default-model openai");
    try std.testing.expectEqual(CommandTag.default_model, default_model.tag);
    try std.testing.expectEqualStrings("openai", default_model.arg);

    const connect = parseCommand("/connect");
    try std.testing.expectEqual(CommandTag.connect_provider, connect.tag);

    const connect_with_arg = parseCommand("/connect openai");
    try std.testing.expectEqual(CommandTag.connect_provider, connect_with_arg.tag);
    try std.testing.expectEqualStrings("openai", connect_with_arg.arg);

    const model = parseCommand("/model openai/gpt-5");
    try std.testing.expectEqual(CommandTag.set_model, model.tag);
    try std.testing.expectEqualStrings("openai/gpt-5", model.arg);
}

test "parse command trims /skill argument" {
    const load = parseCommand("/skill   systematic-debugging   ");
    try std.testing.expectEqual(CommandTag.load_skill, load.tag);
    try std.testing.expectEqualStrings("systematic-debugging", load.arg);
}

test "autocomplete expands unique command prefixes" {
    try std.testing.expectEqualStrings("/providers", autocompleteCommand("/pro"));
    try std.testing.expectEqualStrings("/connect", autocompleteCommand("/con"));
}

test "autocomplete keeps ambiguous and exact commands" {
    try std.testing.expectEqualStrings("/s", autocompleteCommand("/s"));
    try std.testing.expectEqualStrings("/skills", autocompleteCommand("/skills"));
}

test "apply edit key tab completes command" {
    const allocator = std.testing.allocator;
    const next = try applyEditKey(allocator, "/pro", .tab, 0);
    defer allocator.free(next);
    try std.testing.expectEqualStrings("/providers", next);
}

test "apply edit key backspace removes last character" {
    const allocator = std.testing.allocator;
    const next = try applyEditKey(allocator, "/tool", .backspace, 0);
    defer allocator.free(next);
    try std.testing.expectEqualStrings("/too", next);
}

test "providers output includes available providers when none connected" {
    const allocator = std.testing.allocator;
    const providers = defaultProviderSpecs();
    const text = try formatProvidersOutput(allocator, providers, &.{});
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Available providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "openai") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/connect") != null);
}

test "choose auth method parses subscription and defaults to api" {
    try std.testing.expectEqual(AuthMethod.subscription, chooseAuthMethod("subscription", true));
    try std.testing.expectEqual(AuthMethod.subscription, chooseAuthMethod("sub", true));
    try std.testing.expectEqual(AuthMethod.api, chooseAuthMethod("", true));
    try std.testing.expectEqual(AuthMethod.api, chooseAuthMethod("api", true));
    try std.testing.expectEqual(AuthMethod.api, chooseAuthMethod("subscription", false));
}

test "parse model selection supports provider/model format" {
    const selection = parseModelSelection("openai/gpt-5");
    try std.testing.expect(selection != null);
    try std.testing.expectEqualStrings("openai", selection.?.provider_id);
    try std.testing.expectEqualStrings("gpt-5", selection.?.model_id);
}

test "default model prefers non-nano for openai oauth tokens" {
    const providers = defaultProviderSpecs();
    const connected = [_]pm.ProviderState{.{
        .id = "openai",
        .display_name = "OpenAI",
        .key = "a.b.c",
        .connected = true,
        .models = providers[1].models,
    }};

    const active = chooseActiveModel(providers, &connected, null);
    try std.testing.expect(active != null);
    try std.testing.expectEqualStrings("gpt-5", active.?.model_id);
}

test "resolve model pick accepts index and id" {
    const options = [_]pm.Model{
        .{ .id = "gpt-5", .display_name = "GPT-5" },
        .{ .id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
    };

    const by_index = resolveModelPick(options[0..], "2");
    try std.testing.expect(by_index != null);
    try std.testing.expectEqualStrings("gpt-5-nano", by_index.?.id);

    const by_id = resolveModelPick(options[0..], "gpt-5");
    try std.testing.expect(by_id != null);
    try std.testing.expectEqualStrings("gpt-5", by_id.?.id);
}

test "filter model options matches model and provider text" {
    const options = [_]ModelOption{
        .{ .provider_id = "openai", .model_id = "gpt-5", .display_name = "GPT-5" },
        .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4", .display_name = "Claude Sonnet 4" },
        .{ .provider_id = "openai", .model_id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
    };

    const by_provider = try filterModelOptions(std.testing.allocator, options[0..], "anth");
    defer std.testing.allocator.free(by_provider);
    try std.testing.expectEqual(@as(usize, 1), by_provider.len);
    try std.testing.expectEqualStrings("claude-sonnet-4", by_provider[0].model_id);

    const by_model = try filterModelOptions(std.testing.allocator, options[0..], "nano");
    defer std.testing.allocator.free(by_model);
    try std.testing.expectEqual(@as(usize, 1), by_model.len);
    try std.testing.expectEqualStrings("gpt-5-nano", by_model[0].model_id);
}

test "filter preview line includes matching model names" {
    const options = [_]ModelOption{
        .{ .provider_id = "openai", .model_id = "gpt-5", .display_name = "GPT-5" },
        .{ .provider_id = "openai", .model_id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
    };

    const line = try buildFilterPreviewLine(std.testing.allocator, options[0..], "nano");
    defer std.testing.allocator.free(line);
    try std.testing.expect(containsIgnoreCase(line, "gpt-5-nano"));
}

test "filter preview block includes multiple match rows" {
    const options = [_]ModelOption{
        .{ .provider_id = "openai", .model_id = "gpt-5", .display_name = "GPT-5" },
        .{ .provider_id = "openai", .model_id = "gpt-5.3-codex", .display_name = "GPT-5.3 Codex" },
        .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4", .display_name = "Claude Sonnet 4" },
    };

    const block = try buildFilterPreviewBlock(std.testing.allocator, options[0..], "5");
    defer std.testing.allocator.free(block);
    try std.testing.expect(containsIgnoreCase(block, "openai/gpt-5"));
    try std.testing.expect(containsIgnoreCase(block, "openai/gpt-5.3-codex"));
}

test "auto pick single model when only one match" {
    const options = [_]ModelOption{
        .{ .provider_id = "openai", .model_id = "gpt-5.3-codex", .display_name = "GPT-5.3 Codex" },
    };
    const picked = autoPickSingleModel(options[0..]);
    try std.testing.expect(picked != null);
    try std.testing.expectEqualStrings("gpt-5.3-codex", picked.?.model_id);
}

test "context prompt includes summary and turns" {
    const allocator = std.testing.allocator;
    var window = ContextWindow.init(1024, 4);
    defer window.deinit(allocator);

    window.summary = try allocator.dupe(u8, "Earlier summary.");
    try window.append(allocator, .user, "first question", .{});
    try window.append(allocator, .assistant, "first answer", .{ .tool_calls = 1, .files_touched = "src/repl.zig" });

    const prompt = try buildContextPrompt(allocator, &window, "new request");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Conversation summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "first question") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Current user request") != null);
}

test "context compaction summarizes and keeps recent turns" {
    const allocator = std.testing.allocator;
    var window = ContextWindow.init(120, 2);
    defer window.deinit(allocator);

    try window.append(allocator, .user, "u1 long enough to push limit", .{});
    try window.append(allocator, .assistant, "a1 long enough to push limit", .{ .tool_calls = 2 });
    try window.append(allocator, .user, "u2 keep", .{});
    try window.append(allocator, .assistant, "a2 keep", .{});

    try compactContextWindow(allocator, &window, null);

    try std.testing.expect(window.summary != null);
    try std.testing.expect(std.mem.indexOf(u8, window.summary.?, "Compacted context notes") != null);
    try std.testing.expectEqual(@as(usize, 2), window.turns.items.len);
    try std.testing.expectEqualStrings("u2 keep", window.turns.items[0].content);
    try std.testing.expectEqualStrings("a2 keep", window.turns.items[1].content);
}

test "context window persists across save and load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    var out = ContextWindow.init(1024, 4);
    defer out.deinit(allocator);
    try out.append(allocator, .user, "hello", .{});
    try out.append(allocator, .assistant, "world", .{ .tool_calls = 1, .files_touched = "src/main.zig" });
    out.summary = try allocator.dupe(u8, "sum");
    try saveContextWindow(allocator, root, &out, 0x12345678);

    var loaded = ContextWindow.init(1024, 4);
    defer loaded.deinit(allocator);
    try loadContextWindow(allocator, root, &loaded, 0x12345678);

    try std.testing.expect(loaded.summary != null);
    try std.testing.expectEqualStrings("sum", loaded.summary.?);
    try std.testing.expectEqual(@as(usize, 2), loaded.turns.items.len);
    try std.testing.expectEqualStrings("hello", loaded.turns.items[0].content);
}

test "known tool name accepts supported tools" {
    try std.testing.expect(isKnownToolName("bash"));
    try std.testing.expect(isKnownToolName("read_file"));
    try std.testing.expect(isKnownToolName("replace_in_file"));
}

test "known tool name rejects unknown tools" {
    try std.testing.expect(!isKnownToolName("invalid"));
    try std.testing.expect(!isKnownToolName("definitely_not_a_tool"));
}

test "mutating tool detector recognizes write tools" {
    try std.testing.expect(isMutatingToolName("write_file"));
    try std.testing.expect(isMutatingToolName("apply_patch"));
    try std.testing.expect(!isMutatingToolName("read_file"));
}

test "tool routing prompt includes codebase analysis guidance" {
    const allocator = std.testing.allocator;
    const prompt = try buildToolRoutingPrompt(allocator, "how does the new file edit harness work?");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Use local tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "list_files") != null);
}

test "tool routing prompt preserves original user request" {
    const allocator = std.testing.allocator;
    const prompt = try buildToolRoutingPrompt(allocator, "explain src/repl.zig flow");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "explain src/repl.zig flow") != null);
}

test "strict routing prompt allows modification tools" {
    const allocator = std.testing.allocator;
    const prompt = try buildStrictToolRoutingPrompt(allocator, "create a file");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "edit") != null);
}

test "strict routing prompt requires at least one read or list" {
    const allocator = std.testing.allocator;
    const prompt = try buildStrictToolRoutingPrompt(allocator, "how does the harness work?");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "must call") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "list_files") != null);
}

test "repo specific detector catches codebase questions" {
    try std.testing.expect(isLikelyRepoSpecificQuestion("how does the new file edit harness work?"));
    try std.testing.expect(isLikelyRepoSpecificQuestion("explain src/repl.zig"));
    try std.testing.expect(isLikelyRepoSpecificQuestion("what does function runModelTurnWithTools do"));
}

test "repo specific detector ignores generic questions" {
    try std.testing.expect(!isLikelyRepoSpecificQuestion("what is a monad"));
    try std.testing.expect(!isLikelyRepoSpecificQuestion("write a haiku"));
}

test "mutation detector catches file edit requests" {
    try std.testing.expect(isLikelyFileMutationRequest("create and edit sample file"));
    try std.testing.expect(isLikelyFileMutationRequest("update src/repl.zig to add a command"));
}

test "mutation detector ignores non-edit prompts" {
    try std.testing.expect(!isLikelyFileMutationRequest("explain how this works"));
    try std.testing.expect(!isLikelyFileMutationRequest("what is zig"));
}

test "strict mutation routing prompt requires write tools" {
    const allocator = std.testing.allocator;
    const prompt = try buildStrictMutationToolRoutingPrompt(allocator, "create and edit sample file");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "must call") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "write_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "replace_in_file") != null);
}

test "required edit detector catches missing named target" {
    const touched = [_][]const u8{"examples/.gitkeep"};
    try std.testing.expect(hasUnmetRequiredEdits("create a folder named examples then update gitignore to add this file", touched[0..]));
}

test "required edit detector passes when all named targets touched" {
    const touched = [_][]const u8{ "examples/.gitkeep", ".gitignore" };
    try std.testing.expect(!hasUnmetRequiredEdits("create a folder named examples then update gitignore to add this file", touched[0..]));
}

test "fallback tool call parser extracts name and json" {
    const allocator = std.testing.allocator;
    const parsed = try parseFallbackToolCallFromText(allocator, "TOOL_CALL write_file {\"path\":\"sample.txt\",\"content\":\"hello\"}");
    try std.testing.expect(parsed != null);
    defer {
        var p = parsed.?;
        p.deinit(allocator);
    }

    try std.testing.expectEqualStrings("write_file", parsed.?.tool);
    try std.testing.expect(std.mem.indexOf(u8, parsed.?.arguments_json, "sample.txt") != null);
}

test "fallback tool call parser returns null for plain text" {
    const allocator = std.testing.allocator;
    const parsed = try parseFallbackToolCallFromText(allocator, "I cannot do that");
    try std.testing.expect(parsed == null);
}

test "tool call id is stable per step" {
    const allocator = std.testing.allocator;
    const id = try buildToolCallId(allocator, 3);
    defer allocator.free(id);
    try std.testing.expectEqualStrings("toolcall-3", id);
}

test "tool result event line includes status and bytes" {
    const allocator = std.testing.allocator;
    const line = try buildToolResultEventLine(allocator, 2, "toolcall-2", "read_file", "ok", 42, 12, "src/main.zig");
    defer allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "tool-result") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "status=ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "bytes=42") != null);
}

test "infer tool call spec for system time prompt" {
    const sample = "{\"output\":[{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"input\\\":\\\"date +%T\\\"}\"}]}";
    const parsed = try llm.parseOpenAIFunctionCall(std.testing.allocator, sample);
    try std.testing.expect(parsed != null);
    defer if (parsed) |p| p.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bash", parsed.?.tool);
}

test "infer tool call spec for time not date followup" {
    const parsed = try llm.parseOpenAIFunctionCall(std.testing.allocator, "hello");
    try std.testing.expect(parsed == null);
}

test "history navigation moves through entries with up and down" {
    const entries = [_][]const u8{ "/providers", "/connect openai", "/tools" };

    const first_up = historyNextIndex(&entries, null, .up);
    try std.testing.expectEqual(@as(?usize, 2), first_up);

    const second_up = historyNextIndex(&entries, first_up, .up);
    try std.testing.expectEqual(@as(?usize, 1), second_up);

    const down = historyNextIndex(&entries, second_up, .down);
    try std.testing.expectEqual(@as(?usize, 2), down);

    const to_current = historyNextIndex(&entries, down, .down);
    try std.testing.expectEqual(@as(?usize, null), to_current);
}

test "sanitize line input strips non-ascii" {
    const allocator = std.testing.allocator;
    const buf = try allocator.dupe(u8, "sk-abc\x00\x7F\xC2\xA9\n");
    const cleaned = try sanitizeLineInput(allocator, buf);
    try std.testing.expect(cleaned != null);
    defer allocator.free(cleaned.?);
    try std.testing.expectEqualStrings("sk-abc", cleaned.?);
}

test "history persistence loads prior session entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try appendHistoryLine(allocator, root, "/providers");
    try appendHistoryLine(allocator, root, "/tools");

    var history = CommandHistory.init();
    defer history.deinit(allocator);
    try loadHistory(allocator, root, &history);

    try std.testing.expectEqual(@as(usize, 2), history.items.items.len);
    try std.testing.expectEqualStrings("/providers", history.items.items[0]);
    try std.testing.expectEqualStrings("/tools", history.items.items[1]);
}

test "history append ignores empty lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try appendHistoryLine(allocator, root, "   \n");

    var history = CommandHistory.init();
    defer history.deinit(allocator);
    try loadHistory(allocator, root, &history);
    try std.testing.expectEqual(@as(usize, 0), history.items.items.len);
}

fn commandNames() []const []const u8 {
    return &.{
        "/quit",
        "/skills",
        "/skill",
        "/tools",
        "/tool",
        "/providers",
        "/default-model",
        "/connect",
        "/model",
    };
}

fn defaultProviderSpecs() []const pm.ProviderSpec {
    return &.{
        .{
            .id = "anthropic",
            .display_name = "Anthropic",
            .env_vars = &.{"ANTHROPIC_API_KEY"},
            .models = &.{
                .{ .id = "claude-sonnet-4", .display_name = "Claude Sonnet 4" },
                .{ .id = "claude-haiku-4.5", .display_name = "Claude Haiku 4.5" },
            },
        },
        .{
            .id = "openai",
            .display_name = "OpenAI",
            .env_vars = &.{"OPENAI_API_KEY"},
            .models = &.{
                .{ .id = "gpt-5", .display_name = "GPT-5" },
                .{ .id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
            },
        },
        .{
            .id = "google",
            .display_name = "Google",
            .env_vars = &.{"GOOGLE_GENERATIVE_AI_API_KEY"},
            .models = &.{
                .{ .id = "gemini-2.5-pro", .display_name = "Gemini 2.5 Pro" },
                .{ .id = "gemini-2.5-flash", .display_name = "Gemini 2.5 Flash" },
            },
        },
        .{
            .id = "openrouter",
            .display_name = "OpenRouter",
            .env_vars = &.{"OPENROUTER_API_KEY"},
            .models = &.{
                .{ .id = "anthropic/claude-3.5-sonnet", .display_name = "Claude 3.5 Sonnet" },
                .{ .id = "google/gemini-2.0-flash-001", .display_name = "Gemini 2.0 Flash" },
            },
        },
        .{
            .id = "opencode",
            .display_name = "OpenCode",
            .env_vars = &.{"OPENCODE_API_KEY"},
            .models = &.{
                .{ .id = "kimi-k2.5", .display_name = "Kimi K2.5" },
            },
        },
    };
}

fn envPairsForProviders(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    stored: []const store.StoredPair,
) ![]pm.EnvPair {
    var out = try std.ArrayList(pm.EnvPair).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (providers) |provider| {
        // Always include opencode even without API key (free tier uses "public")
        const is_opencode = std.mem.eql(u8, provider.id, "opencode");
        var found_any = false;

        for (provider.env_vars) |name| {
            for (stored) |pair| {
                if (std.mem.eql(u8, pair.name, name)) {
                    try out.append(allocator, .{ .name = pair.name, .value = pair.value });
                    found_any = true;
                }
            }
            const value = std.posix.getenv(name) orelse continue;
            try out.append(allocator, .{ .name = name, .value = value });
            found_any = true;
        }

        // For opencode, add a placeholder if no key found so it passes through
        if (is_opencode and !found_any and provider.env_vars.len > 0) {
            try out.append(allocator, .{ .name = provider.env_vars[0], .value = "" });
        }
    }

    return out.toOwnedSlice(allocator);
}

fn resolveProviderStates(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    stored: []const store.StoredPair,
) ![]pm.ProviderState {
    const env_pairs = try envPairsForProviders(allocator, providers, stored);
    defer allocator.free(env_pairs);
    return pm.ProviderManager.resolve(allocator, providers, env_pairs, .{});
}

fn promptLine(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    prompt: []const u8,
) !?[]u8 {
    try stdout.print("{s}", .{prompt});
    const raw = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    return sanitizeLineInput(allocator, raw);
}

fn promptRawLine(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    prompt: []const u8,
) !?[]u8 {
    try stdout.print("{s}", .{prompt});
    const raw = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    if (raw == null) return null;
    const slice = raw.?;
    defer allocator.free(slice);

    // Just trim whitespace/newlines, keep all other bytes
    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    if (trimmed.len == 0) return null;

    const value = try allocator.dupe(u8, trimmed);
    return @as(?[]u8, value);
}

fn sanitizeLineInput(allocator: std.mem.Allocator, raw: ?[]u8) !?[]u8 {
    if (raw == null) return null;
    const slice = raw.?;
    defer allocator.free(slice);

    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    if (trimmed.len == 0) return null;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (trimmed) |ch| {
        if (ch >= 32 and ch <= 126) {
            try out.append(allocator, ch);
        }
    }
    if (out.items.len == 0) return null;
    const value = try out.toOwnedSlice(allocator);
    return @as(?[]u8, value);
}

fn chooseProvider(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
) !?pm.ProviderSpec {
    try stdout.print("Connect a provider:\n", .{});
    for (providers, 0..) |provider, idx| {
        const status = if (isConnected(provider.id, connected)) "connected" else "not connected";
        try stdout.print("  {d}) {s} [{s}]\n", .{ idx + 1, provider.display_name, status });
    }
    const choice_opt = try promptLine(allocator, stdin, stdout, "Provider number or id: ");
    if (choice_opt == null) return null;
    defer allocator.free(choice_opt.?);
    const choice = std.mem.trim(u8, choice_opt.?, " \t\r\n");
    if (choice.len == 0) return null;

    const parsed_num = std.fmt.parseInt(usize, choice, 10) catch null;
    if (parsed_num) |n| {
        if (n > 0 and n <= providers.len) {
            return providers[n - 1];
        }
    }

    for (providers) |provider| {
        if (std.mem.eql(u8, provider.id, choice)) return provider;
    }

    try stdout.print("Unknown provider: {s}\n", .{choice});
    return null;
}

fn isConnected(provider_id: []const u8, connected: []const pm.ProviderState) bool {
    for (connected) |item| {
        if (std.mem.eql(u8, item.id, provider_id)) return true;
    }
    return false;
}

fn findProviderSpecByID(providers: []const pm.ProviderSpec, provider_id: []const u8) ?pm.ProviderSpec {
    for (providers) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

fn findConnectedProvider(connected: []const pm.ProviderState, provider_id: []const u8) ?pm.ProviderState {
    for (connected) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

fn providerHasModel(providers: []const pm.ProviderSpec, provider_id: []const u8, model_id: []const u8) bool {
    const provider = findProviderSpecByID(providers, provider_id) orelse return false;
    for (provider.models) |model| {
        if (std.mem.eql(u8, model.id, model_id)) return true;
    }
    return false;
}

fn chooseActiveModel(
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
    selected: ?OwnedModelSelection,
) ?ActiveModel {
    if (selected) |sel| {
        const provider = findConnectedProvider(connected, sel.provider_id) orelse return null;
        if (!providerHasModel(providers, sel.provider_id, sel.model_id)) return null;
        return .{ .provider_id = sel.provider_id, .model_id = sel.model_id, .api_key = provider.key };
    }

    if (connected.len == 0) return null;
    const provider = connected[0];
    const default_model = chooseDefaultModelForConnected(provider) orelse return null;
    return .{ .provider_id = provider.id, .model_id = default_model, .api_key = provider.key };
}

fn chooseDefaultModelForConnected(provider: pm.ProviderState) ?[]const u8 {
    if (std.mem.eql(u8, provider.id, "openai") and provider.key != null and isLikelyOAuthToken(provider.key.?)) {
        for (provider.models) |m| {
            if (std.mem.indexOf(u8, m.id, "nano") == null and std.mem.indexOf(u8, m.id, "mini") == null) {
                return m.id;
            }
        }
    }
    return pm.ProviderManager.defaultModelIDForProvider(provider.id, provider.models);
}

fn isLikelyOAuthToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "sk-")) return false;
    return std.mem.count(u8, token, ".") >= 2;
}

fn interactiveModelSelect(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    stdin_file: std.fs.File,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
) !?ModelSelection {
    if (connected.len == 0) {
        try stdout.print("No connected providers. Run /connect first.\n", .{});
        return null;
    }

    const options = try collectModelOptions(allocator, providers, connected);
    defer allocator.free(options);

    const query_opt = if (stdin_file.isTty())
        try readFilterQueryRealtime(allocator, stdin_file, stdout, options)
    else
        try promptLine(allocator, stdin, stdout, "Filter models (empty = all): ");
    if (query_opt == null) return null;
    defer allocator.free(query_opt.?);
    const query = std.mem.trim(u8, query_opt.?, " \t\r\n");

    const filtered = try filterModelOptions(allocator, options, query);
    defer allocator.free(filtered);
    if (filtered.len == 0) {
        try stdout.print("No models matched filter: {s}\n", .{query});
        return null;
    }

    if (autoPickSingleModel(filtered)) |model| {
        try stdout.print("Auto-selected: {s}/{s}\n", .{ model.provider_id, model.model_id });
        return .{ .provider_id = model.provider_id, .model_id = model.model_id };
    }

    try stdout.print("Select model:\n", .{});
    for (filtered, 0..) |m, i| {
        try stdout.print("  {d}) {s}/{s} ({s})\n", .{ i + 1, m.provider_id, m.model_id, m.display_name });
    }

    const model_pick_opt = try promptLine(allocator, stdin, stdout, "Model number or id: ");
    if (model_pick_opt == null) return null;
    defer allocator.free(model_pick_opt.?);
    const model_pick = std.mem.trim(u8, model_pick_opt.?, " \t\r\n");
    if (model_pick.len == 0) return null;

    const model = resolveGlobalModelPick(filtered, model_pick) orelse {
        try stdout.print("Unknown model: {s}\n", .{model_pick});
        return null;
    };

    return .{ .provider_id = model.provider_id, .model_id = model.model_id };
}

fn resolveModelPick(models: []const pm.Model, pick: []const u8) ?pm.Model {
    const n = std.fmt.parseInt(usize, pick, 10) catch null;
    if (n) |idx| {
        if (idx > 0 and idx <= models.len) return models[idx - 1];
    }
    for (models) |m| {
        if (std.mem.eql(u8, m.id, pick)) return m;
    }
    return null;
}

fn collectModelOptions(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
) ![]ModelOption {
    var out = try std.ArrayList(ModelOption).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (connected) |cp| {
        const spec = findProviderSpecByID(providers, cp.id) orelse continue;
        for (spec.models) |m| {
            try out.append(allocator, .{ .provider_id = cp.id, .model_id = m.id, .display_name = m.display_name });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn filterModelOptions(allocator: std.mem.Allocator, options: []const ModelOption, query: []const u8) ![]ModelOption {
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return allocator.dupe(ModelOption, options);

    var out = try std.ArrayList(ModelOption).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (options) |o| {
        if (containsIgnoreCase(o.model_id, q) or containsIgnoreCase(o.display_name, q) or containsIgnoreCase(o.provider_id, q)) {
            try out.append(allocator, o);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        var ok = true;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn resolveGlobalModelPick(options: []const ModelOption, pick: []const u8) ?ModelOption {
    const n = std.fmt.parseInt(usize, pick, 10) catch null;
    if (n) |idx| {
        if (idx > 0 and idx <= options.len) return options[idx - 1];
    }

    for (options) |m| {
        if (std.mem.eql(u8, m.model_id, pick)) return m;
        if (std.mem.eql(u8, m.provider_id, pick)) return m;
        if (std.mem.eql(u8, m.display_name, pick)) return m;
    }

    for (options) |m| {
        if (std.mem.eql(u8, m.provider_id, pick)) return m;
        if (containsIgnoreCase(m.model_id, pick)) return m;
        if (containsIgnoreCase(m.display_name, pick)) return m;
    }
    return null;
}

fn autoPickSingleModel(options: []const ModelOption) ?ModelOption {
    return if (options.len == 1) options[0] else null;
}

fn inferToolCallWithModel(allocator: std.mem.Allocator, stdout: anytype, active: ActiveModel, input: []const u8, force: bool) !?llm.ToolRouteCall {
    var defs = try std.ArrayList(llm.ToolRouteDef).initCapacity(allocator, tools.definitions.len);
    defer defs.deinit(allocator);

    for (tools.definitions) |d| {
        try defs.append(allocator, .{ .name = d.name, .description = d.description, .parameters_json = d.parameters_json });
    }

    const result = try llm.inferToolCallWithThinking(allocator, active.provider_id, active.api_key, active.model_id, input, defs.items, force);
    if (result) |r| {
        // Print thinking content if available
        if (r.thinking) |thinking| {
            defer allocator.free(thinking);
            if (thinking.len > 0) {
                try stdout.print("\x1b[90m[thinking: {s}]\x1b[0m ", .{thinking});
            }
        }
        return r.call;
    }
    return null;
}

fn buildFallbackToolInferencePrompt(allocator: std.mem.Allocator, user_text: []const u8, require_mutation: bool) ![]u8 {
    var tools_list = std.ArrayList(u8).empty;
    defer tools_list.deinit(allocator);
    for (tools.definitions) |d| {
        try tools_list.writer(allocator).print("- {s}: {s}\n", .{ d.name, d.parameters_json });
    }

    return std.fmt.allocPrint(
        allocator,
        "Return exactly one line in this format and nothing else: TOOL_CALL <tool_name> <arguments_json>. Choose one tool from the list below. Arguments must be valid JSON object. {s}\n\nTools:\n{s}\nUser request:\n{s}",
        .{ if (require_mutation) "This request requires file mutation; prefer write_file, replace_in_file/edit, or apply_patch." else "", tools_list.items, user_text },
    );
}

fn parseFallbackToolCallFromText(allocator: std.mem.Allocator, text: []const u8) !?llm.ToolRouteCall {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "TOOL_CALL ")) return null;

    const rest = std.mem.trim(u8, trimmed[10..], " \t");
    const brace = std.mem.indexOfScalar(u8, rest, '{') orelse return null;
    const name = std.mem.trim(u8, rest[0..brace], " \t");
    const args = std.mem.trim(u8, rest[brace..], " \t");
    if (name.len == 0 or args.len < 2) return null;

    return .{
        .tool = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, args),
    };
}

fn inferToolCallWithTextFallback(allocator: std.mem.Allocator, active: ActiveModel, input: []const u8, require_mutation: bool) !?llm.ToolRouteCall {
    const prompt = try buildFallbackToolInferencePrompt(allocator, input, require_mutation);
    defer allocator.free(prompt);

    const raw = llm.query(allocator, active.provider_id, active.api_key, active.model_id, prompt, toolDefsToLlm(tools.definitions[0..])) catch return null;
    defer allocator.free(raw);
    return parseFallbackToolCallFromText(allocator, raw);
}

fn isKnownToolName(name: []const u8) bool {
    for (tools.definitions) |d| {
        if (std.mem.eql(u8, name, d.name)) return true;
    }
    return false;
}

fn isMutatingToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "write_file") or
        std.mem.eql(u8, name, "replace_in_file") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "apply_patch");
}

fn buildToolRoutingPrompt(allocator: std.mem.Allocator, user_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Use local tools when they improve correctness. For repository-specific questions, inspect files first with list_files and read_file. For code changes, you may use read_file, write_file, or replace_in_file/edit directly. Only skip tools when the answer is purely general knowledge.\n\nUser request:\n{s}",
        .{user_text},
    );
}

fn buildStrictToolRoutingPrompt(allocator: std.mem.Allocator, user_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "This is a repository-specific question. You must call at least one local tool before giving the final answer. First call list_files, read_file, write_file, or replace_in_file/edit, then answer using concrete file evidence or action results.\n\nUser request:\n{s}",
        .{user_text},
    );
}

fn isLikelyRepoSpecificQuestion(input: []const u8) bool {
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return false;

    if (std.mem.indexOf(u8, t, "/") != null) return true;
    if (containsIgnoreCase(t, "repo") or containsIgnoreCase(t, "codebase")) return true;
    if (containsIgnoreCase(t, "src/")) return true;
    if (containsIgnoreCase(t, ".zig")) return true;
    if (containsIgnoreCase(t, "function") or containsIgnoreCase(t, "file") or containsIgnoreCase(t, "harness")) return true;
    if (containsIgnoreCase(t, "how does") or containsIgnoreCase(t, "where is") or containsIgnoreCase(t, "explain")) return true;

    return false;
}

fn isLikelyFileMutationRequest(input: []const u8) bool {
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return false;

    const mentions_target = containsIgnoreCase(t, "file") or containsIgnoreCase(t, "src/") or containsIgnoreCase(t, ".zig");
    if (!mentions_target) return false;

    return containsIgnoreCase(t, "create") or
        containsIgnoreCase(t, "edit") or
        containsIgnoreCase(t, "write") or
        containsIgnoreCase(t, "modify") or
        containsIgnoreCase(t, "update") or
        containsIgnoreCase(t, "replace") or
        containsIgnoreCase(t, "refactor") or
        containsIgnoreCase(t, "add line");
}

fn buildStrictMutationToolRoutingPrompt(allocator: std.mem.Allocator, user_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "This request requires actual file mutation. You must call at least one write-capable tool before giving a final answer. Use write_file, replace_in_file/edit, or apply_patch. Do not claim success unless a tool has run successfully.\n\nUser request:\n{s}",
        .{user_text},
    );
}

fn isLikelyMultiStepMutationRequest(input: []const u8) bool {
    return isLikelyFileMutationRequest(input) and (containsIgnoreCase(input, " then ") or containsIgnoreCase(input, " and "));
}

fn trimTargetToken(token: []const u8) []const u8 {
    return std.mem.trim(u8, token, " \t\r\n`\"'.,:;!?()[]{}<>");
}

fn isMutationVerb(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "create") or
        std.ascii.eqlIgnoreCase(token, "edit") or
        std.ascii.eqlIgnoreCase(token, "write") or
        std.ascii.eqlIgnoreCase(token, "modify") or
        std.ascii.eqlIgnoreCase(token, "update") or
        std.ascii.eqlIgnoreCase(token, "replace") or
        std.ascii.eqlIgnoreCase(token, "add") or
        std.ascii.eqlIgnoreCase(token, "refactor");
}

fn isIgnoredTargetWord(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "file") or
        std.ascii.eqlIgnoreCase(token, "folder") or
        std.ascii.eqlIgnoreCase(token, "directory") or
        std.ascii.eqlIgnoreCase(token, "named") or
        std.ascii.eqlIgnoreCase(token, "name") or
        std.ascii.eqlIgnoreCase(token, "this") or
        std.ascii.eqlIgnoreCase(token, "that") or
        std.ascii.eqlIgnoreCase(token, "it") or
        std.ascii.eqlIgnoreCase(token, "the") or
        std.ascii.eqlIgnoreCase(token, "a") or
        std.ascii.eqlIgnoreCase(token, "an") or
        std.ascii.eqlIgnoreCase(token, "to") or
        std.ascii.eqlIgnoreCase(token, "then") or
        std.ascii.eqlIgnoreCase(token, "and") or
        std.ascii.eqlIgnoreCase(token, "with");
}

fn looksLikePathTarget(token: []const u8) bool {
    return std.mem.indexOfScalar(u8, token, '/') != null or std.mem.indexOfScalar(u8, token, '.') != null;
}

fn targetSatisfied(touched_paths: []const []const u8, target: []const u8) bool {
    for (touched_paths) |p| {
        if (containsIgnoreCase(p, target)) return true;
        const base = std.fs.path.basename(p);
        if (std.ascii.eqlIgnoreCase(base, target)) return true;

        if (std.mem.indexOfScalar(u8, target, '.') == null and std.mem.indexOfScalar(u8, target, '/') == null) {
            if (base.len == target.len + 1 and base[0] == '.') {
                if (std.ascii.eqlIgnoreCase(base[1..], target)) return true;
            }
        }
    }
    return false;
}

fn collectRequiredTargets(allocator: std.mem.Allocator, user_input: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    defer out.deinit(allocator);

    var words = std.mem.tokenizeAny(u8, user_input, " \t\r\n");
    var prev_was_verb = false;
    while (words.next()) |raw| {
        const token = trimTargetToken(raw);
        if (token.len == 0) continue;

        if (isMutationVerb(token)) {
            prev_was_verb = true;
            continue;
        }

        if (isIgnoredTargetWord(token)) {
            if (!std.ascii.eqlIgnoreCase(token, "named") and !std.ascii.eqlIgnoreCase(token, "name")) {
                prev_was_verb = false;
            }
            continue;
        }

        if (looksLikePathTarget(token) or prev_was_verb) {
            var exists = false;
            for (out.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, token)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try out.append(allocator, token);
        }
        prev_was_verb = false;
    }

    return out.toOwnedSlice(allocator);
}

fn hasUnmetRequiredEdits(user_input: []const u8, touched_paths: []const []const u8) bool {
    const required = collectRequiredTargets(std.heap.page_allocator, user_input) catch return false;
    defer std.heap.page_allocator.free(required);

    for (required) |target| {
        if (!targetSatisfied(touched_paths, target)) return true;
    }
    return false;
}

fn buildToolCallId(allocator: std.mem.Allocator, step: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "toolcall-{d}", .{step});
}

// ANSI color codes for tool debugging
const C_RESET = "\x1b[0m";
const C_BLUE = "\x1b[34m"; // event type
const C_YELLOW = "\x1b[33m"; // tool names
const C_GREEN = "\x1b[32m"; // success status
const C_RED = "\x1b[31m"; // error status
const C_CYAN = "\x1b[36m"; // metadata
const C_DIM = "\x1b[90m"; // low priority info
const C_BRIGHT_WHITE = "\x1b[97m"; // model response text

fn buildToolResultEventLine(
    allocator: std.mem.Allocator,
    step: usize,
    call_id: []const u8,
    tool_name: []const u8,
    status: []const u8,
    bytes: usize,
    duration_ms: i64,
    file_path: ?[]const u8,
) ![]u8 {
    // Colorize status
    const status_color = if (std.mem.eql(u8, status, "ok")) C_GREEN else C_RED;

    // Build colored output using ArrayList
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("{s}event=tool-result{s} ", .{ C_BLUE, C_RESET });
    try w.print("{s}step={d}{s} ", .{ C_CYAN, step, C_RESET });
    try w.print("{s}call_id={s}{s} ", .{ C_DIM, call_id, C_RESET });
    try w.print("{s}tool={s}{s} ", .{ C_YELLOW, tool_name, C_RESET });
    if (file_path) |fp| {
        try w.print("{s}file={s}{s} ", .{ C_CYAN, fp, C_RESET });
    }
    try w.print("{s}status={s}{s} ", .{ status_color, status, C_RESET });
    try w.print("{s}bytes={d}{s} ", .{ C_DIM, bytes, C_RESET });
    try w.print("{s}duration_ms={d}{s}", .{ C_DIM, duration_ms, C_RESET });

    return out.toOwnedSlice(allocator);
}

// Helper to print colored tool events
fn printColoredToolEvent(stdout: anytype, event_type: []const u8, step: ?usize, call_id: ?[]const u8, tool_name: ?[]const u8) !void {
    try stdout.print("{s}event={s}{s}{s}", .{ C_BLUE, C_RESET, event_type, C_RESET });
    if (step) |s| {
        try stdout.print(" {s}step={d}{s}", .{ C_CYAN, s, C_RESET });
    }
    if (call_id) |cid| {
        try stdout.print(" {s}call_id={s}{s}", .{ C_DIM, cid, C_RESET });
    }
    if (tool_name) |tname| {
        try stdout.print(" {s}tool={s}{s}", .{ C_YELLOW, tname, C_RESET });
    }
    try stdout.print("\n", .{});
}

// Execute tool calls embedded in model response (TOOL_CALL format)
fn executeInlineToolCalls(
    allocator: std.mem.Allocator,
    stdout: anytype,
    response: []const u8,
    paths: *std.ArrayList([]u8),
    tool_calls: *usize,
    todo_list: *todo.TodoList,
) !?[]u8 {
    var result_buf = std.ArrayList(u8).empty;
    defer result_buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "TOOL_CALL ")) continue;

        // Parse: TOOL_CALL name args
        const after_prefix = trimmed[10..]; // Skip "TOOL_CALL "
        const space_idx = std.mem.indexOfScalar(u8, after_prefix, ' ') orelse continue;
        const tool_name = after_prefix[0..space_idx];
        const args = std.mem.trim(u8, after_prefix[space_idx..], " \t");

        if (!isKnownToolName(tool_name)) continue;

        tool_calls.* += 1;

        // Track path
        if (parsePrimaryPathFromArgs(allocator, args)) |p| {
            var found = false;
            for (paths.items) |existing| {
                if (std.mem.eql(u8, existing, p)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try paths.append(allocator, p);
            } else {
                allocator.free(p);
            }
        }

        // Extract file path, bash command, or read params from args for display
        const file_path = parsePrimaryPathFromArgs(allocator, args);
        defer if (file_path) |fp| allocator.free(fp);
        const bash_cmd = if (std.mem.eql(u8, tool_name, "bash"))
            parseBashCommandFromArgs(allocator, args)
        else
            null;
        defer if (bash_cmd) |bc| allocator.free(bc);
        const read_params = if (std.mem.eql(u8, tool_name, "read") or std.mem.eql(u8, tool_name, "read_file"))
            try parseReadParamsFromArgs(allocator, args)
        else
            null;

        // Execute tool
        try printColoredToolEvent(stdout, "tool-inline", null, null, tool_name);
        if (file_path) |fp| {
            try stdout.print(" {s}file={s}{s}", .{ C_CYAN, fp, C_RESET });
        }
        if (bash_cmd) |bc| {
            // Truncate long commands
            const max_cmd_len = 60;
            const display_cmd = if (bc.len > max_cmd_len) bc[0..max_cmd_len] else bc;
            const suffix = if (bc.len > max_cmd_len) "..." else "";
            try stdout.print(" {s}cmd=\"{s}{s}\"{s}", .{ C_CYAN, display_cmd, suffix, C_RESET });
        }
        if (read_params) |rp| {
            if (rp.offset) |off| {
                try stdout.print(" {s}offset={d}{s}", .{ C_DIM, off, C_RESET });
            }
            if (rp.limit) |lim| {
                try stdout.print(" {s}limit={d}{s}", .{ C_DIM, lim, C_RESET });
            }
        }
        try stdout.print("\n", .{});

        const tool_out = tools.executeNamed(allocator, tool_name, args, todo_list) catch |err| {
            try result_buf.writer(allocator).print("Tool {s} failed: {s}\n", .{ tool_name, @errorName(err) });
            continue;
        };
        defer allocator.free(tool_out);

        // For mutating tools, print diff to stdout for user visibility
        if (isMutatingToolName(tool_name)) {
            try stdout.print("{s}\n", .{tool_out});
        }

        try result_buf.writer(allocator).print("Tool {s} result:\n{s}\n", .{ tool_name, tool_out });
    }

    if (result_buf.items.len == 0) return null;
    const value = try result_buf.toOwnedSlice(allocator);
    return @as(?[]u8, value);
}

fn parsePrimaryPathFromArgs(allocator: std.mem.Allocator, arguments_json: []const u8) ?[]u8 {
    const A = struct { path: ?[]const u8 = null, filePath: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const p = parsed.value.path orelse parsed.value.filePath orelse return null;
    return allocator.dupe(u8, p) catch null;
}

fn parseBashCommandFromArgs(allocator: std.mem.Allocator, arguments_json: []const u8) ?[]u8 {
    const A = struct { command: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const cmd = parsed.value.command orelse return null;
    return allocator.dupe(u8, cmd) catch null;
}

const ReadParams = struct {
    offset: ?usize = null,
    limit: ?usize = null,
};

fn parseReadParamsFromArgs(allocator: std.mem.Allocator, arguments_json: []const u8) !?ReadParams {
    const A = struct { offset: ?usize = null, limit: ?usize = null };
    var parsed = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const value = parsed.value;
    if (value.offset == null and value.limit == null) return null;

    return ReadParams{
        .offset = value.offset,
        .limit = value.limit,
    };
}

fn containsPath(paths: []const []u8, candidate: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, candidate)) return true;
    }
    return false;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '\"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 32) {
                    try w.print("\\u{x:0>4}", .{ch});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
}

fn joinPaths(allocator: std.mem.Allocator, paths: []const []u8) !?[]u8 {
    if (paths.len == 0) return null;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (paths, 0..) |p, idx| {
        if (idx > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, p);
    }
    const value = try out.toOwnedSlice(allocator);
    return @as(?[]u8, value);
}

fn runModelTurnWithTools(
    allocator: std.mem.Allocator,
    stdout: anytype,
    active: ActiveModel,
    raw_user_request: []const u8,
    user_input: []const u8,
    todo_list: *todo.TodoList,
) !RunTurnResult {
    var context_prompt = try allocator.dupe(u8, user_input);
    // We'll manually free context_prompt before each reassignment and at function exit
    var forced_repo_probe_done = false;
    var forced_mutation_probe_done = false;
    var forced_completion_probe_done = false;
    const repo_specific = isLikelyRepoSpecificQuestion(raw_user_request);
    const mutation_request = isLikelyFileMutationRequest(raw_user_request);
    const multi_step_mutation = isLikelyMultiStepMutationRequest(raw_user_request);
    var tool_calls: usize = 0;
    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var step: usize = 0;
    const soft_limit: usize = 6; // After this, check todos and ask model if we should continue
    var just_received_tool_call: bool = false; // Track if we got TOOL_CALL at soft limit

    while (true) : (step += 1) {
        // Reset flag at start of iteration
        just_received_tool_call = false;

        // Check for cancellation at start of each iteration
        if (isCancelled()) {
            allocator.free(context_prompt);
            return .{
                .response = try allocator.dupe(u8, "Operation cancelled by user."),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try joinPaths(allocator, paths.items),
            };
        }

        // On step 6+, check todos and ask model if we should continue
        // Skip this check if we just received a TOOL_CALL (model wants to continue)
        if (step >= soft_limit and !just_received_tool_call) {
            const todo_summary = todo_list.summary();
            try stdout.print("{s}[step {d}] Checking if more work needed... (todos: {s}){s}\n", .{ C_DIM, step, todo_summary, C_RESET });

            const continue_prompt = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n[SYSTEM] You have completed {d} tool steps. Todo status: {s}.\n\nDo you need more steps to complete the task? If yes, make another tool call. If no, provide the final answer.",
                .{ context_prompt, step, todo_summary },
            );
            defer allocator.free(continue_prompt);

            // Query model to see if it wants to continue
            const check_response = try llm.query(allocator, active.provider_id, active.api_key, active.model_id, continue_prompt, toolDefsToLlm(tools.definitions[0..]));

            // If model returns TOOL_CALL, continue the loop
            if (std.mem.startsWith(u8, check_response, "TOOL_CALL ")) {
                try stdout.print("{s}[step {d}] Model requests more steps{s}\n", .{ C_CYAN, step, C_RESET });
                allocator.free(context_prompt);
                context_prompt = try allocator.dupe(u8, check_response);
                allocator.free(check_response);
                just_received_tool_call = true; // Mark that we got a TOOL_CALL
                continue;
            }

            // Model gave final answer, return it
            try stdout.print("{s}[step {d}] Model provides final answer{s}\n", .{ C_GREEN, step, C_RESET });
            allocator.free(context_prompt);
            return .{
                .response = check_response,
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try joinPaths(allocator, paths.items),
            };
        }

        try stdout.print("{s}[step {d}]{s} ", .{ C_DIM, step, C_RESET });

        const route_prompt = try buildToolRoutingPrompt(allocator, context_prompt);
        defer allocator.free(route_prompt);

        try stdout.print("{s}thinking...{s} ", .{ C_DIM, C_RESET });
        var routed = try inferToolCallWithModel(allocator, stdout, active, route_prompt, false);
        if (routed == null and step == 0 and repo_specific and !forced_repo_probe_done) {
            forced_repo_probe_done = true;
            try stdout.print("{s}re-analyzing...{s} ", .{ C_DIM, C_RESET });
            const strict_prompt = try buildStrictToolRoutingPrompt(allocator, context_prompt);
            defer allocator.free(strict_prompt);
            routed = try inferToolCallWithModel(allocator, stdout, active, strict_prompt, true);
        }

        if (routed == null and step == 0 and mutation_request and !forced_mutation_probe_done) {
            forced_mutation_probe_done = true;
            try stdout.print("{s}checking edit requirements...{s} ", .{ C_DIM, C_RESET });
            const strict_mutation_prompt = try buildStrictMutationToolRoutingPrompt(allocator, context_prompt);
            defer allocator.free(strict_mutation_prompt);
            routed = try inferToolCallWithModel(allocator, stdout, active, strict_mutation_prompt, true);
        }

        if (routed == null and step == 0 and mutation_request) {
            try stdout.print("{s}fallback parsing...{s} ", .{ C_DIM, C_RESET });
            routed = try inferToolCallWithTextFallback(allocator, active, context_prompt, true);
        }

        if (routed == null and mutation_request and !forced_completion_probe_done and step < soft_limit) {
            var touched = std.ArrayList([]const u8).empty;
            defer touched.deinit(allocator);
            for (paths.items) |p| try touched.append(allocator, p);

            const missing_required = hasUnmetRequiredEdits(raw_user_request, touched.items);
            if ((multi_step_mutation and tool_calls < 2) or missing_required) {
                forced_completion_probe_done = true;
                const completion_prompt = try std.fmt.allocPrint(
                    allocator,
                    "The user requested multiple edits. Completed tool calls so far: {d}. Touched paths: {s}. You must continue with a real tool call to complete remaining requested edits, especially any missing required files like .gitignore when requested.\n\nCurrent request:\n{s}",
                    .{ tool_calls, if (try joinPaths(allocator, paths.items)) |jp| blk: {
                        defer allocator.free(jp);
                        break :blk jp;
                    } else "(none)", raw_user_request },
                );
                defer allocator.free(completion_prompt);
                routed = try inferToolCallWithModel(allocator, stdout, active, completion_prompt, true);
                if (routed == null) {
                    routed = try inferToolCallWithTextFallback(allocator, active, completion_prompt, true);
                }
            }
        }

        if (routed == null) {
            try stdout.print("{s}no tool selected{s}\n", .{ C_YELLOW, C_RESET });

            if (mutation_request and tool_calls == 0) {
                allocator.free(context_prompt);
                return .{
                    .response = try allocator.dupe(
                        u8,
                        "Your request looks like a file edit, but I couldn't determine what to write. Please be more specific—include a filename and the content or change you want.",
                    ),
                    .tool_calls = 0,
                    .error_count = 1,
                    .files_touched = null,
                };
            }

            if (mutation_request) {
                var touched = std.ArrayList([]const u8).empty;
                defer touched.deinit(allocator);
                for (paths.items) |p| try touched.append(allocator, p);
                if (hasUnmetRequiredEdits(raw_user_request, touched.items) or (multi_step_mutation and tool_calls < 2)) {
                    allocator.free(context_prompt);
                    return .{
                        .response = try allocator.dupe(
                            u8,
                            "I completed only part of the requested edits. Please specify which remaining file(s) to modify and what changes to make.",
                        ),
                        .tool_calls = tool_calls,
                        .error_count = 1,
                        .files_touched = try joinPaths(allocator, paths.items),
                    };
                }
            }

            const final = try llm.query(allocator, active.provider_id, active.api_key, active.model_id, context_prompt, toolDefsToLlm(tools.definitions[0..]));

            // Check if response contains inline tool calls (TOOL_CALL format)
            if (std.mem.startsWith(u8, final, "TOOL_CALL ")) {
                // Execute inline tool calls from model response
                const tool_result = try executeInlineToolCalls(allocator, stdout, final, &paths, &tool_calls, todo_list);
                allocator.free(final);

                if (tool_result) |result| {
                    // Append tool result to context and continue loop
                    const next_prompt = try std.fmt.allocPrint(
                        allocator,
                        "{s}\n\nTool execution result:\n{s}\n\nContinue with next action if needed.",
                        .{ context_prompt, result },
                    );
                    allocator.free(result);
                    context_prompt = next_prompt;
                    continue;
                }
            } else if (step < soft_limit) {
                // Model returned text but we haven't hit max steps yet
                // Add response to context and continue the loop
                try stdout.print("{s}...continuing{s}\n", .{ C_DIM, C_RESET });
                const next_prompt = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n\nAssistant response:\n{s}\n\nContinue with your task. Use tools if needed.",
                    .{ context_prompt, final },
                );
                allocator.free(final);
                context_prompt = next_prompt;
                continue;
            }

            allocator.free(context_prompt);
            return .{
                .response = final,
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try joinPaths(allocator, paths.items),
            };
        }
        defer {
            var r = routed.?;
            r.deinit(allocator);
        }

        if (!isKnownToolName(routed.?.tool)) {
            const final = try llm.query(allocator, active.provider_id, active.api_key, active.model_id, context_prompt, toolDefsToLlm(tools.definitions[0..]));

            // Check for inline tool calls
            if (std.mem.startsWith(u8, final, "TOOL_CALL ")) {
                const tool_result = try executeInlineToolCalls(allocator, stdout, final, &paths, &tool_calls, todo_list);
                allocator.free(final);
                if (tool_result) |result| {
                    allocator.free(result);
                    allocator.free(context_prompt);
                    return .{
                        .response = try allocator.dupe(u8, "Executed tool from model response."),
                        .tool_calls = tool_calls,
                        .error_count = 0,
                        .files_touched = try joinPaths(allocator, paths.items),
                    };
                }
            } else if (step < soft_limit) {
                // Model returned text but we haven't hit max steps yet
                // Add response to context and continue the loop
                try stdout.print("{s}...continuing{s}\n", .{ C_DIM, C_RESET });
                const next_prompt = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n\nAssistant response:\n{s}\n\nContinue with your task. Use tools if needed.",
                    .{ context_prompt, final },
                );
                allocator.free(final);
                context_prompt = next_prompt;
                continue;
            }

            allocator.free(context_prompt);
            return .{
                .response = final,
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try joinPaths(allocator, paths.items),
            };
        }

        // Check for cancellation before executing tool
        if (isCancelled()) {
            allocator.free(context_prompt);
            return .{
                .response = try allocator.dupe(u8, "Operation cancelled by user during tool execution."),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try joinPaths(allocator, paths.items),
            };
        }

        try stdout.print("{s}→ {s}{s}\n", .{ C_GREEN, routed.?.tool, C_RESET });
        tool_calls += 1;
        if (parsePrimaryPathFromArgs(allocator, routed.?.arguments_json)) |p| {
            if (!containsPath(paths.items, p)) {
                try paths.append(allocator, p);
            } else {
                allocator.free(p);
            }
        }

        const call_id = try buildToolCallId(allocator, step + 1);
        defer allocator.free(call_id);

        try printColoredToolEvent(stdout, "tool-input-start", step + 1, call_id, routed.?.tool);
        try printColoredToolEvent(stdout, "tool-call", step + 1, call_id, routed.?.tool);

        const started_ms = std.time.milliTimestamp();

        // Extract file path for file-related tools
        const file_path = parsePrimaryPathFromArgs(allocator, routed.?.arguments_json);

        const tool_out = tools.executeNamed(allocator, routed.?.tool, routed.?.arguments_json, todo_list) catch |err| {
            const failed_ms = std.time.milliTimestamp();
            const duration_ms = failed_ms - started_ms;
            const err_line = try buildToolResultEventLine(allocator, step + 1, call_id, routed.?.tool, "error", 0, duration_ms, file_path);
            defer allocator.free(err_line);
            if (file_path) |fp| allocator.free(fp);
            try stdout.print("{s}\n", .{err_line});
            allocator.free(context_prompt);
            return .{
                .response = try std.fmt.allocPrint(
                    allocator,
                    "Tool execution failed at step {d} ({s}): {s}",
                    .{ step + 1, routed.?.tool, @errorName(err) },
                ),
                .tool_calls = tool_calls,
                .error_count = 1,
                .files_touched = try joinPaths(allocator, paths.items),
            };
        };
        defer allocator.free(tool_out);

        const finished_ms = std.time.milliTimestamp();
        const duration_ms = finished_ms - started_ms;
        const ok_line = try buildToolResultEventLine(allocator, step + 1, call_id, routed.?.tool, "ok", tool_out.len, duration_ms, file_path);
        defer allocator.free(ok_line);
        if (file_path) |fp| allocator.free(fp);
        try stdout.print("{s}\n", .{ok_line});

        if (isMutatingToolName(routed.?.tool)) {
            // For mutating tools, show the full output including the colored diff
            try printColoredToolEvent(stdout, "tool-meta", step + 1, call_id, routed.?.tool);
            try stdout.print("{s}\n", .{tool_out});
        }

        const capped = if (tool_out.len > 4000) tool_out[0..4000] else tool_out;
        const next_prompt = try std.fmt.allocPrint(
            allocator,
            "{s}\n\nTool events:\n- event=tool-input-start step={d} call_id={s} tool={s}\n- event=tool-call step={d} call_id={s} tool={s}\n- {s}\nArguments JSON: {s}\nTool output:\n{s}\n\nYou may call another tool if needed. Otherwise return the final user-facing answer.",
            .{ context_prompt, step + 1, call_id, routed.?.tool, step + 1, call_id, routed.?.tool, ok_line, routed.?.arguments_json, capped },
        );
        allocator.free(context_prompt);
        context_prompt = next_prompt;
    }
}

// Simplified bridge-based tool loop - uses Bun AI SDK
fn runWithBridge(
    allocator: std.mem.Allocator,
    stdout: anytype,
    active: ActiveModel,
    raw_user_request: []const u8,
    user_input: []const u8,
    todo_list: *todo.TodoList,
) !RunTurnResult {
    _ = raw_user_request;

    // Check API key
    const api_key = active.api_key orelse {
        return .{
            .response = try allocator.dupe(u8, "No API key configured. Run /providers to connect."),
            .tool_calls = 0,
            .error_count = 1,
            .files_touched = null,
        };
    };

    // Spawn the Bun AI bridge
    var bridge = try ai_bridge.Bridge.spawn(allocator, api_key, active.model_id, active.provider_id);
    defer bridge.deinit();

    // Build initial messages
    var messages = std.ArrayList(u8).empty;
    defer messages.deinit(allocator);
    const w = messages.writer(allocator);
    try w.writeAll("[{\"role\":\"system\",\"content\":\"");
    try writeJsonString(w, "You are zagent. Use tools to help. Say DONE when finished.");
    try w.writeAll("\"},{\"role\":\"user\",\"content\":\"");
    try writeJsonString(w, user_input);
    try w.writeAll("\"}");

    var tool_calls: usize = 0;
    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    const max_iterations: usize = 15;
    var iteration: usize = 0;

    while (iteration < max_iterations) : (iteration += 1) {
        // Check for cancellation
        if (isCancelled()) {
            return .{
                .response = try allocator.dupe(u8, "Operation cancelled by user."),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try joinPaths(allocator, paths.items),
            };
        }

        try stdout.print("{s}[step {d}]{s} ", .{ C_DIM, iteration, C_RESET });

        // Send current messages (add closing bracket)
        const messages_json = try std.fmt.allocPrint(allocator, "{s}]", .{messages.items});
        defer allocator.free(messages_json);

        // Call the bridge
        const response = try bridge.chat(messages_json, max_iterations - iteration);
        defer {
            allocator.free(response.text);
            allocator.free(response.finish_reason);
            for (response.tool_calls) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.tool);
                allocator.free(tc.args);
            }
            allocator.free(response.tool_calls);
        }

        // Show model text
        if (response.text.len > 0) {
            try stdout.print("{s}\n", .{response.text});
        }

        // Add assistant message to history
        try w.writeAll(",{\"role\":\"assistant\",\"content\":\"");
        try writeJsonString(w, response.text);
        try w.writeAll("\"");

        if (response.tool_calls.len > 0) {
            try w.writeAll(",\"tool_calls\":[");
            for (response.tool_calls, 0..) |tc, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":", .{ tc.id, tc.tool });
                try w.writeAll(tc.args);
                try w.writeAll("}}}");
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");

        // Execute all tool calls
        if (response.tool_calls.len == 0) {
            // No tools - we're done
            return .{
                .response = try allocator.dupe(u8, response.text),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try joinPaths(allocator, paths.items),
            };
        }

        for (response.tool_calls) |tc| {
            tool_calls += 1;
            try stdout.print("{s}→ {s}{s}", .{ C_GREEN, tc.tool, C_RESET });

            const result = tools.executeNamed(allocator, tc.tool, tc.args, todo_list) catch |err| {
                try stdout.print(" error: {s}\n", .{@errorName(err)});
                const err_msg = try std.fmt.allocPrint(allocator, "Tool {s} failed: {s}", .{ tc.tool, @errorName(err) });
                defer allocator.free(err_msg);
                
                try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":\"");
                try w.writeAll(tc.id);
                try w.writeAll("\",\"content\":\"");
                try writeJsonString(w, err_msg);
                try w.writeAll("\"}");
                continue;
            };
            defer allocator.free(result);

            try stdout.print("\n{s}\n", .{result});

            // Add tool result to history
            try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":\"");
            try w.writeAll(tc.id);
            try w.writeAll("\",\"content\":\"");
            try writeJsonString(w, result);
            try w.writeAll("\"}");

            // Track paths
            if (parsePrimaryPathFromArgs(allocator, tc.args)) |p| {
                if (!containsPath(paths.items, p)) {
                    try paths.append(allocator, p);
                } else {
                    allocator.free(p);
                }
            }
        }
    }

    return .{
        .response = try allocator.dupe(u8, "Reached maximum iterations. Task may be incomplete."),
        .tool_calls = tool_calls,
        .error_count = 0,
        .files_touched = try joinPaths(allocator, paths.items),
    };
}

fn shellQuoteSingle(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn readFilterQueryRealtime(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdout: anytype,
    options: []const ModelOption,
) !?[]u8 {
    const original = std.posix.tcgetattr(stdin_file.handle) catch return try allocator.dupe(u8, "");
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    try std.posix.tcsetattr(stdin_file.handle, .NOW, raw);
    defer std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};

    var query = try allocator.alloc(u8, 0);
    defer allocator.free(query);

    var rendered_lines: usize = 0;
    try renderFilterPreview(allocator, stdout, options, query, &rendered_lines);

    var byte_buf: [1]u8 = undefined;
    while (true) {
        const n = try stdin_file.read(&byte_buf);
        if (n == 0) return null;
        const ch = byte_buf[0];
        if (ch == '\n' or ch == '\r') {
            try stdout.print("\n", .{});
            return try allocator.dupe(u8, query);
        }
        if (ch == 0x1B) { // ESC key
            try stdout.print("\n", .{});
            return null;
        }
        if (ch == 127 or ch == 8) {
            if (query.len > 0) query = try allocator.realloc(query, query.len - 1);
        } else if (ch >= 32 and ch != 127) {
            query = try allocator.realloc(query, query.len + 1);
            query[query.len - 1] = ch;
        }
        try renderFilterPreview(allocator, stdout, options, query, &rendered_lines);
    }
}

fn renderFilterPreview(
    allocator: std.mem.Allocator,
    stdout: anytype,
    options: []const ModelOption,
    query: []const u8,
    rendered_lines: *usize,
) !void {
    if (rendered_lines.* > 1) {
        try stdout.print("\x1b[{d}A", .{rendered_lines.* - 1});
    }

    if (rendered_lines.* > 0) {
        var i: usize = 0;
        while (i < rendered_lines.*) : (i += 1) {
            try stdout.print("\r\x1b[2K", .{});
            if (i + 1 < rendered_lines.*) try stdout.print("\x1b[1B", .{});
        }
        if (rendered_lines.* > 1) {
            try stdout.print("\x1b[{d}A", .{rendered_lines.* - 1});
        }
    }

    const block = try buildFilterPreviewBlock(allocator, options, query);
    defer allocator.free(block);
    try stdout.print("{s}", .{block});

    rendered_lines.* = 1;
    for (block) |ch| {
        if (ch == '\n') rendered_lines.* += 1;
    }
}

fn buildFilterPreviewBlock(allocator: std.mem.Allocator, options: []const ModelOption, query: []const u8) ![]u8 {
    const filtered = try filterModelOptions(allocator, options, query);
    defer allocator.free(filtered);

    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("Filter models: {s} | matches: {d}", .{ query, filtered.len });
    const limit = @min(filtered.len, 6);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        try w.print("\n  {d}) {s}/{s} ({s})", .{ i + 1, filtered[i].provider_id, filtered[i].model_id, filtered[i].display_name });
    }
    if (filtered.len > limit) {
        try w.print("\n  ... and {d} more", .{filtered.len - limit});
    }
    return out.toOwnedSlice(allocator);
}

fn buildFilterPreviewLine(allocator: std.mem.Allocator, options: []const ModelOption, query: []const u8) ![]u8 {
    const filtered = try filterModelOptions(allocator, options, query);
    defer allocator.free(filtered);

    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("Filter models: {s} | matches: {d}", .{ query, filtered.len });
    if (filtered.len > 0) {
        try w.print(" | top: ", .{});
        const limit = @min(filtered.len, 3);
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            if (i > 0) try w.print(", ", .{});
            try w.print("{s}/{s}", .{ filtered[i].provider_id, filtered[i].model_id });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn supportsSubscription(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "openai");
}

fn chooseAuthMethod(input: []const u8, allow_subscription: bool) AuthMethod {
    if (!allow_subscription) return .api;
    if (std.mem.eql(u8, input, "subscription") or std.mem.eql(u8, input, "sub") or std.mem.eql(u8, input, "oauth")) {
        return .subscription;
    }
    return .api;
}

fn formatProvidersOutput(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);

    const w = out.writer(allocator);
    try w.print("Available providers:\n", .{});
    for (providers) |provider| {
        const status = if (isConnected(provider.id, connected)) "connected" else "not connected";
        const methods = if (supportsSubscription(provider.id)) "api|subscription" else "api";
        try w.print("- {s} ({s}) [{s}] methods={s}\n", .{ provider.id, provider.display_name, status, methods });
    }
    try w.print("Use /connect or /connect <provider-id> to set up a provider.\n", .{});

    return out.toOwnedSlice(allocator);
}

fn connectSubscription(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    provider_id: []const u8,
) !?[]u8 {
    if (!std.mem.eql(u8, provider_id, "openai")) {
        try stdout.print("Subscription flow is currently supported only for openai.\n", .{});
        return null;
    }

    const start = try openaiDeviceStart(allocator);
    defer allocator.free(start.device_auth_id);
    defer allocator.free(start.user_code);

    try stdout.print("Open this URL in your browser: {s}/codex/device\n", .{OPENAI_ISSUER});
    try stdout.print("Enter code: {s}\n", .{start.user_code});
    const open_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", "xdg-open https://auth.openai.com/codex/device >/dev/null 2>&1 || true" },
    });
    allocator.free(open_result.stdout);
    allocator.free(open_result.stderr);

    const proceed = try promptLine(allocator, stdin, stdout, "Press Enter after authorization (or type cancel): ");
    if (proceed) |p| {
        defer allocator.free(p);
        const t = std.mem.trim(u8, p, " \t\r\n");
        if (std.mem.eql(u8, t, "cancel")) return null;
    }

    const token = try openaiPollAndExchange(allocator, stdout, start.device_auth_id, start.user_code, start.interval_sec);
    if (token == null) {
        try stdout.print("Subscription login failed.\n", .{});
        return null;
    }
    return token;
}

const OpenAIDeviceStart = struct {
    device_auth_id: []u8,
    user_code: []u8,
    interval_sec: u64,
};

fn openaiDeviceStart(allocator: std.mem.Allocator) !OpenAIDeviceStart {
    const body = try std.fmt.allocPrint(allocator, "{{\"client_id\":\"{s}\"}}", .{OPENAI_CLIENT_ID});
    defer allocator.free(body);

    const out = try runCommandCapture(allocator, &.{
        "curl",                                               "-sS", "-X",                             "POST",
        OPENAI_ISSUER ++ "/api/accounts/deviceauth/usercode", "-H",  "Content-Type: application/json", "-H",
        "User-Agent: zagent/0.1",                             "-d",  body,
    });
    defer allocator.free(out);

    const StartResp = struct {
        device_auth_id: []const u8,
        user_code: []const u8,
        interval: ?[]const u8 = null,
    };
    var parsed = try std.json.parseFromSlice(StartResp, allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const interval = if (parsed.value.interval) |s| std.fmt.parseInt(u64, s, 10) catch 5 else 5;
    return .{
        .device_auth_id = try allocator.dupe(u8, parsed.value.device_auth_id),
        .user_code = try allocator.dupe(u8, parsed.value.user_code),
        .interval_sec = if (interval == 0) 5 else interval,
    };
}

fn openaiPollAndExchange(
    allocator: std.mem.Allocator,
    stdout: anytype,
    device_auth_id: []const u8,
    user_code: []const u8,
    interval_sec: u64,
) !?[]u8 {
    var tries: usize = 0;
    while (tries < 120) : (tries += 1) {
        const poll_body = try std.fmt.allocPrint(
            allocator,
            "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}",
            .{ device_auth_id, user_code },
        );
        defer allocator.free(poll_body);

        const poll = try runCommandCapture(allocator, &.{
            "curl",                                            "-sS", "-X",                             "POST",
            OPENAI_ISSUER ++ "/api/accounts/deviceauth/token", "-H",  "Content-Type: application/json", "-H",
            "User-Agent: zagent/0.1",                          "-d",  poll_body,
        });
        defer allocator.free(poll);

        const PollResp = struct {
            authorization_code: ?[]const u8 = null,
            code_verifier: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(PollResp, allocator, poll, .{ .ignore_unknown_fields = true }) catch {
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        };
        defer parsed.deinit();

        if (parsed.value.authorization_code == null or parsed.value.code_verifier == null) {
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        }

        const form = try std.fmt.allocPrint(
            allocator,
            "grant_type=authorization_code&code={s}&redirect_uri={s}/deviceauth/callback&client_id={s}&code_verifier={s}",
            .{ parsed.value.authorization_code.?, OPENAI_ISSUER, OPENAI_CLIENT_ID, parsed.value.code_verifier.? },
        );
        defer allocator.free(form);

        const token = try runCommandCapture(allocator, &.{
            "curl",                          "-sS", "-X",                                              "POST",
            OPENAI_ISSUER ++ "/oauth/token", "-H",  "Content-Type: application/x-www-form-urlencoded", "-d",
            form,
        });
        defer allocator.free(token);

        const TokenResp = struct {
            access_token: ?[]const u8 = null,
            refresh_token: ?[]const u8 = null,
        };
        var tok = std.json.parseFromSlice(TokenResp, allocator, token, .{ .ignore_unknown_fields = true }) catch {
            return null;
        };
        defer tok.deinit();

        if (tok.value.access_token) |access| {
            try stdout.print("Subscription authorized successfully.\n", .{});
            return try allocator.dupe(u8, access);
        }
        return null;
    }

    return null;
}

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stderr);
    return result.stdout;
}
