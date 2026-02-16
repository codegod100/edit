const std = @import("std");
const builtin = @import("builtin");
const display = @import("../display.zig"); // Use display.zig for terminal logic
const model_select = @import("../model_select.zig"); // Core logic for model selection
const provider = @import("../provider.zig");
const context = @import("../context.zig");

// --- Helper Functions ---

pub fn sanitizeLineInput(allocator: std.mem.Allocator, raw: ?[]u8) !?[]u8 {
    if (raw == null) return null;
    const slice = raw.?;
    defer allocator.free(slice);

    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    if (trimmed.len == 0) return null;

    var out: std.ArrayListUnmanaged(u8) = .empty;
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

pub fn promptLine(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    prompt: []const u8,
) !?[]u8 {
    try stdout.print("{s}", .{prompt});
    const raw = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    return sanitizeLineInput(allocator, raw);
}

// --- Interactive Model Selection ---

pub fn interactiveModelSelect(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    stdin_file: std.fs.File,
    providers: []const provider.ProviderSpec,
    connected: []const provider.ProviderState,
    only_provider_id: ?[]const u8,
) !?model_select.ModelSelection {
    const options = try model_select.collectModelOptions(allocator, providers, connected, only_provider_id);
    defer allocator.free(options);

    const query_opt = if (stdin_file.isTty())
        try readFilterQueryRealtime(allocator, stdin_file, stdout, options)
    else
        try promptLine(allocator, stdin, stdout, "Filter models (empty = all): ");

    if (query_opt == null) return null;
    defer allocator.free(query_opt.?);
    const query = std.mem.trim(u8, query_opt.?, " \t\r\n");

    const filtered = try model_select.filterModelOptions(allocator, options, query);
    defer allocator.free(filtered);
    if (filtered.len == 0) {
        try stdout.print("No models matched filter: {s}\n", .{query});
        return null;
    }

    if (model_select.autoPickSingleModel(filtered)) |model| {
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

    const model = model_select.resolveGlobalModelPick(filtered, model_pick) orelse {
        try stdout.print("Unknown model: {s}\n", .{model_pick});
        return null;
    };

    return .{ .provider_id = model.provider_id, .model_id = model.model_id };
}

fn readFilterQueryRealtime(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdout: anytype,
    options: []const model_select.ModelOption,
) !?[]u8 {
    // ... tcgetattr ...
    const original = try std.posix.tcgetattr(stdin_file.handle);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false; // Disable signal generation so Ctrl+C produces 0x03 byte

    if (builtin.os.tag == .linux) {
        raw.cc[6] = 1; // VMIN
        raw.cc[5] = 1; // VTIME (100ms)
    } else if (builtin.os.tag == .macos) {
        raw.cc[16] = 1; // VMIN
        raw.cc[17] = 1; // VTIME (100ms)
    }
    try std.posix.tcsetattr(stdin_file.handle, .NOW, raw);
    defer std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};

    var query = try allocator.alloc(u8, 0);
    defer allocator.free(query); // Note: we realloc, so we must be careful.
    // Wait, query is realloc'd. We should return a duplicate or take ownership.
    // The loop handles realloc. At return we duplicate.

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
    options: []const model_select.ModelOption,
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

fn buildFilterPreviewBlock(allocator: std.mem.Allocator, options: []const model_select.ModelOption, query: []const u8) ![]u8 {
    const filtered = try model_select.filterModelOptions(allocator, options, query);
    defer allocator.free(filtered);

    var out: std.ArrayListUnmanaged(u8) = .empty;
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
