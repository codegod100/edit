const std = @import("std");
const tools = @import("tools.zig");
const llm = @import("llm.zig");

/// Convert tools.ToolDef slice to llm.ToolRouteDef slice (identical layout).
pub fn toolDefsToLlm(defs: []const tools.ToolDef) []const llm.ToolRouteDef {
    return @ptrCast(defs);
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
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

pub fn writeJsonString(w: anytype, s: []const u8) !void {
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

pub fn joinPaths(allocator: std.mem.Allocator, paths: []const []u8) !?[]u8 {
    if (paths.len == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (paths, 0..) |p, idx| {
        if (idx > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, p);
    }
    const value = try out.toOwnedSlice(allocator);
    return @as(?[]u8, value);
}

pub fn sanitizeLineInput(allocator: std.mem.Allocator, raw: ?[]u8) !?[]u8 {
    if (raw == null) return null;
    const slice = raw.?;
    defer allocator.free(slice);

    const trimmed = std.mem.trim(u8, slice, " \t\r\n");
    if (trimmed.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
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

pub fn isCodexModelId(model_id: []const u8) bool {
    return std.mem.indexOf(u8, model_id, "codex") != null;
}

pub fn shellQuoteSingle(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
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

pub fn containsPath(paths: []const []u8, candidate: []const u8) bool {
    for (paths) |p| {
        if (std.mem.eql(u8, p, candidate)) return true;
    }
    return false;
}
