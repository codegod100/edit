const std = @import("std");

pub const MentionReadLimit: usize = 4096;
pub const MentionMaxFiles: usize = 4;

pub const LineEditResult = struct {
    text: []u8,
    cursor_pos: usize,
};

pub fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

pub fn isMentionPathChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '.' or ch == '_' or ch == '-';
}

fn sharedPrefixLen(a: []const u8, b: []const u8) usize {
    const max_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < max_len and a[i] == b[i]) : (i += 1) {}
    return i;
}

fn mentionCompletionSuffix(allocator: std.mem.Allocator, mention_prefix: []const u8) !?[]u8 {
    const slash = std.mem.lastIndexOfScalar(u8, mention_prefix, '/');
    const dir_path = if (slash) |idx| if (idx == 0) "/" else mention_prefix[0..idx] else ".";
    const needle = if (slash) |idx| mention_prefix[idx + 1 ..] else mention_prefix;

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var it = dir.iterate();
    var common: ?[]u8 = null;
    errdefer if (common) |v| allocator.free(v);

    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, needle)) continue;

        const rest = entry.name[needle.len..];
        const candidate = if (entry.kind == .directory)
            try std.fmt.allocPrint(allocator, "{s}/", .{rest})
        else
            try allocator.dupe(u8, rest);

        if (common) |existing| {
            const keep = sharedPrefixLen(existing, candidate);
            const next = try allocator.dupe(u8, existing[0..keep]);
            allocator.free(existing);
            allocator.free(candidate);
            common = next;
        } else {
            common = candidate;
        }
    }

    if (common) |value| {
        if (value.len == 0) {
            allocator.free(value);
            return null;
        }
        return value;
    }
    return null;
}

pub fn autocompleteMentionAtCursor(
    allocator: std.mem.Allocator,
    current: []const u8,
    cursor_pos: usize,
) !?LineEditResult {
    const pos = @min(cursor_pos, current.len);

    var start = pos;
    while (start > 0 and !isWhitespace(current[start - 1])) : (start -= 1) {}

    var end = pos;
    while (end < current.len and !isWhitespace(current[end])) : (end += 1) {}

    if (start >= current.len or current[start] != '@') return null;
    if (pos != end) return null;
    if (start + 1 > pos) return null;

    const mention_prefix = current[start + 1 .. pos];
    for (mention_prefix) |ch| {
        if (!isMentionPathChar(ch)) return null;
    }

    const suffix = (try mentionCompletionSuffix(allocator, mention_prefix)) orelse return null;
    defer allocator.free(suffix);

    const out = try allocator.alloc(u8, current.len + suffix.len);
    @memcpy(out[0..pos], current[0..pos]);
    @memcpy(out[pos .. pos + suffix.len], suffix);
    @memcpy(out[pos + suffix.len ..], current[pos..]);
    return .{ .text = out, .cursor_pos = pos + suffix.len };
}

// --- Path resolution and file mentions ---

pub fn pathWithinBase(base: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, base)) return false;
    if (candidate.len == base.len) return true;
    return candidate[base.len] == '/';
}

pub fn resolveMentionPath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const abs = if (std.fs.path.isAbsolute(raw_path))
        try allocator.dupe(u8, raw_path)
    else
        try std.fs.path.resolve(allocator, &.{ cwd, raw_path });

    if (!pathWithinBase(cwd, abs)) {
        allocator.free(abs);
        return error.InvalidPath;
    }
    return abs;
}

pub fn collectMentionPaths(allocator: std.mem.Allocator, input: []const u8, max_files: usize) !std.ArrayList([]u8) {
    var out = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    var i: usize = 0;
    while (i < input.len and out.items.len < max_files) : (i += 1) {
        if (input[i] != '@') continue;
        if (i > 0 and !isWhitespace(input[i - 1])) continue;

        var j = i + 1;
        while (j < input.len and isMentionPathChar(input[j])) : (j += 1) {}
        if (j == i + 1) continue;

        const path = input[i + 1 .. j];
        var exists = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, path)) {
                exists = true;
                break;
            }
        }
        if (!exists) try out.append(allocator, try allocator.dupe(u8, path));
        i = j - 1;
    }

    return out;
}

fn readMentionedFileSnippet(allocator: std.mem.Allocator, raw_path: []const u8, max_bytes: usize) !?[]u8 {
    const resolved = resolveMentionPath(allocator, raw_path) catch return null;
    defer allocator.free(resolved);

    var file = std.fs.openFileAbsolute(resolved, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    if (stat.kind != .file) return null;

    const content = file.readToEndAlloc(allocator, max_bytes) catch return null;
    errdefer allocator.free(content);

    if (stat.size > content.len) {
        const with_note = try std.fmt.allocPrint(allocator, "{s}\n\n[...truncated at {d} bytes]", .{ content, max_bytes });
        allocator.free(content);
        return with_note;
    }
    return content;
}

pub fn buildPromptWithMentions(allocator: std.mem.Allocator, base_prompt: []const u8, user_input: []const u8) ![]u8 {
    var mentions_list = try collectMentionPaths(allocator, user_input, MentionMaxFiles);
    defer {
        for (mentions_list.items) |m| allocator.free(m);
        mentions_list.deinit(allocator);
    }

    if (mentions_list.items.len == 0) return allocator.dupe(u8, base_prompt);

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try w.print("{s}", .{base_prompt});

    var added: usize = 0;
    for (mentions_list.items) |raw_path| {
        const snippet = try readMentionedFileSnippet(allocator, raw_path, MentionReadLimit) orelse continue;
        defer allocator.free(snippet);

        if (added == 0) {
            try w.print("\n\nMentioned file context (from @path in current request):\n", .{});
        }
        try w.print("\n@{s}\n{s}\n", .{ raw_path, snippet });
        added += 1;
    }

    return out.toOwnedSlice(allocator);
}
