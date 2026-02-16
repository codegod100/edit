const std = @import("std");
const builtin = @import("builtin");

// ANSI color codes
pub const C_RESET = "\x1b[0m";
pub const C_BOLD = "\x1b[1m";
pub const C_DIM = "\x1b[2m";
pub const C_ITALIC = "\x1b[3m";
pub const C_UNDERLINE = "\x1b[4m";
pub const C_BLUE = "\x1b[34m";
pub const C_ORANGE = "\x1b[38;5;208m";
pub const C_PURPLE = "\x1b[38;5;135m";
pub const C_YELLOW = "\x1b[33m";
pub const C_GREEN = "\x1b[32m";
pub const C_RED = "\x1b[31m";
pub const C_CYAN = "\x1b[36m";
pub const C_BRIGHT_WHITE = "\x1b[97m";
pub const C_GREY = "\x1b[90m";

pub fn terminalColumns() usize {
    if (builtin.os.tag != .windows) {
        var ws: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(rc) == .SUCCESS and ws.col > 0) {
            return @as(usize, @intCast(ws.col));
        }
    }
    const cols_env = std.posix.getenv("COLUMNS") orelse return 80;
    return std.fmt.parseInt(usize, cols_env, 10) catch 80;
}

pub fn visibleLenAnsi(text: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == ';')) : (i += 1) {}
            continue;
        }
        n += 1;
    }
    return n;
}

pub fn buildToolResultEventLine(
    allocator: std.mem.Allocator,
    step: usize,
    call_id: []const u8,
    tool_name: []const u8,
    status: []const u8,
    bytes: usize,
    duration_ms: i64,
    file_path: ?[]const u8,
) ![]u8 {
    _ = step;
    _ = call_id;
    _ = bytes;

    const status_color = if (std.mem.eql(u8, status, "ok")) C_GREEN else C_RED;
    const status_symbol = if (std.mem.eql(u8, status, "ok")) "✓" else "✗";

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("{s}{s}{s} ", .{ status_color, status_symbol, C_RESET });
    if (file_path) |fp| {
        try w.print("{s} {s}", .{ tool_name, fp });
    } else {
        try w.print("{s}", .{tool_name});
    }
    try w.print(" {s}({d}ms){s}", .{ C_DIM, duration_ms, C_RESET });

    return out.toOwnedSlice(allocator);
}

pub fn printColoredToolEvent(stdout: anytype, event_type: []const u8, step: ?usize, call_id: ?[]const u8, tool_name: ?[]const u8) !void {
    if (!std.mem.eql(u8, event_type, "tool-call")) return;
    if (tool_name) |tname| {
        try stdout.print("• {s}\n", .{tname});
    }
    _ = step;
    _ = call_id;
}

pub fn printTruncatedCommandOutput(stdout: anytype, output: []const u8) !void {
    const HEAD: usize = 2;
    const TAIL: usize = 2;

    const Range = struct { start: usize, end: usize };
    var head: [HEAD]Range = undefined;
    var head_len: usize = 0;

    var tail: [TAIL]Range = undefined;
    var tail_seen: usize = 0;
    var tail_len: usize = 0;

    var total: usize = 0;

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= output.len) : (i += 1) {
        if (i == output.len or output[i] == '\n') {
            const raw = output[line_start..i];
            const trimmed = std.mem.trimRight(u8, raw, "\r");
            const start = line_start;
            const end = start + trimmed.len;
            line_start = i + 1;

            if (trimmed.len == 0) continue;
            total += 1;

            const r: Range = .{ .start = start, .end = end };
            if (head_len < HEAD) {
                head[head_len] = r;
                head_len += 1;
            }

            tail[tail_seen % TAIL] = r;
            tail_seen += 1;
            if (tail_len < TAIL) tail_len += 1;
        }
    }

    if (total == 0) return;

    const trunc = total > (HEAD + TAIL);
    if (!trunc) {
        var printed_any = false;
        line_start = 0;
        i = 0;
        while (i <= output.len) : (i += 1) {
            if (i == output.len or output[i] == '\n') {
                const raw = output[line_start..i];
                const trimmed = std.mem.trimRight(u8, raw, "\r");
                line_start = i + 1;
                if (trimmed.len == 0) continue;

                const prefix = if (!printed_any) "  └ " else "    ";
                printed_any = true;
                try stdout.print("{s}{s}{s}{s}\n", .{ prefix, C_GREY, trimmed, C_RESET });
            }
        }
        return;
    }

    var printed_any = false;
    for (head[0..HEAD]) |r| {
        const prefix = if (!printed_any) "  └ " else "    ";
        printed_any = true;
        try stdout.print("{s}{s}{s}{s}\n", .{ prefix, C_GREY, output[r.start..r.end], C_RESET });
    }

    const omitted = total - HEAD - TAIL;
    try stdout.print("    {s}… +{d} lines{s}\n", .{ C_GREY, omitted, C_RESET });

    const first = tail_seen - tail_len;
    var t: usize = 0;
    while (t < tail_len) : (t += 1) {
        const r = tail[(first + t) % TAIL];
        try stdout.print("    {s}{s}{s}\n", .{ C_GREY, output[r.start..r.end], C_RESET });
    }
}

pub fn describeModelQueryError(err: anyerror) []const u8 {
    return switch (err) {
        error.ModelProviderError => "upstream provider returned an error (see debug log for details)",
        error.ModelResponseParseError => "upstream model response JSON parse failed",
        error.ModelResponseMissingChoices => "upstream model response missing choices/content",
        else => @errorName(err),
    };
}

// Timeline display for keeping prompt at bottom
var g_timeline_entries: std.ArrayListUnmanaged([]const u8) = .{};
var g_timeline_allocator: ?std.mem.Allocator = null;

pub fn initTimeline(allocator: std.mem.Allocator) void {
    g_timeline_allocator = allocator;
}

pub fn deinitTimeline() void {
    if (g_timeline_allocator) |allocator| {
        for (g_timeline_entries.items) |entry| {
            allocator.free(entry);
        }
        g_timeline_entries.deinit(allocator);
        g_timeline_entries = .{};
        g_timeline_allocator = null;
    }
}

pub fn addTimelineEntry(comptime format: []const u8, args: anytype) void {
    if (g_timeline_allocator) |allocator| {
        const entry = std.fmt.allocPrint(allocator, format, args) catch return;
        g_timeline_entries.append(allocator, entry) catch allocator.free(entry);
    }
}

pub fn clearScreenAndRedrawTimeline(stdout: anytype, current_prompt: []const u8) !void {
    // Get terminal height
    const term_height = getTerminalHeight();
    
    // Clear screen and move cursor to top
    try stdout.writeAll("\x1b[2J\x1b[H");
    
    // Count lines in prompt (box + system info = 4 lines typically)
    var prompt_lines: usize = 0;
    for (current_prompt) |c| {
        if (c == '\n') prompt_lines += 1;
    }
    if (prompt_lines == 0) prompt_lines = 4;
    
    // Calculate how many timeline entries we can show
    const reserved_lines = prompt_lines;
    const max_timeline_lines = if (term_height > reserved_lines) term_height - reserved_lines else 5;
    
    // Count total lines in all timeline entries (each entry may have newlines)
    var total_entry_lines: usize = 0;
    for (g_timeline_entries.items) |entry| {
        var lines_in_entry: usize = 1; // At least 1 line
        for (entry) |c| {
            if (c == '\n') lines_in_entry += 1;
        }
        total_entry_lines += lines_in_entry;
    }
    
    // If we have more content than fits, only show what fits
    // Start from the top and draw until we fill the available space
    var lines_remaining = max_timeline_lines;
    var start_idx: usize = 0;
    
    // Find starting index that allows us to show max content
    if (total_entry_lines > max_timeline_lines) {
        // Need to scroll - find which entries to skip
        var lines_to_skip = total_entry_lines - max_timeline_lines;
        var idx: usize = 0;
        while (idx < g_timeline_entries.items.len and lines_to_skip > 0) {
            var lines_in_entry: usize = 1;
            for (g_timeline_entries.items[idx]) |c| {
                if (c == '\n') lines_in_entry += 1;
            }
            if (lines_in_entry <= lines_to_skip) {
                lines_to_skip -= lines_in_entry;
                idx += 1;
            } else {
                break;
            }
        }
        start_idx = idx;
    }
    
    // Draw timeline entries that fit
    var idx = start_idx;
    while (idx < g_timeline_entries.items.len and lines_remaining > 0) : (idx += 1) {
        const entry = g_timeline_entries.items[idx];
        var lines_in_entry: usize = 1;
        for (entry) |c| {
            if (c == '\n') lines_in_entry += 1;
        }
        
        if (lines_in_entry <= lines_remaining) {
            try stdout.print("{s}", .{entry});
            if (idx < g_timeline_entries.items.len - 1) {
                try stdout.writeAll("\n");
            }
            lines_remaining -= lines_in_entry;
        } else {
            // Entry is too long, truncate it
            break;
        }
    }
    
    // Fill remaining space to push prompt to bottom
    while (lines_remaining > 0) : (lines_remaining -= 1) {
        try stdout.writeAll("\n");
    }
    
    // Draw prompt box at bottom
    try stdout.print("{s}", .{current_prompt});
    
    // Position cursor: go up to middle line and to column 4 (after "│ >")
    // After printing prompt (ends with \n), cursor is at start of new line
    // Need to go up 3 lines: from below system info -> system info -> bottom border -> middle line
    try stdout.writeAll("\x1b[3A"); // Move up 3 lines
    try stdout.writeAll("\x1b[4G"); // Move to column 4 (after "│ >")
}

pub fn getTerminalHeight() usize {
    if (builtin.os.tag != .windows) {
        var ws: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(rc) == .SUCCESS and ws.row > 0) {
            return @as(usize, @intCast(ws.row));
        }
    }
    return 24; // Default terminal height
}

fn isMarkdownTableSeparatorRow(line: []const u8) bool {
    var text = std.mem.trim(u8, line, " \t");
    if (text.len == 0) return false;
    if (text[0] == '|') text = text[1..];
    if (text.len > 0 and text[text.len - 1] == '|') text = text[0 .. text.len - 1];
    if (text.len == 0) return false;

    var seen_dash = false;
    for (text) |ch| {
        switch (ch) {
            '-', ':' => seen_dash = true,
            '|', ' ', '\t' => {},
            else => return false,
        }
    }
    return seen_dash;
}

fn renderMarkdownTableRow(allocator: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, use_color: bool) !bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    if (trimmed[0] != '|' and std.mem.indexOfScalar(u8, trimmed, '|') == null) return false;
    if (isMarkdownTableSeparatorRow(trimmed)) return true;

    var row = trimmed;
    if (row.len > 0 and row[0] == '|') row = row[1..];
    if (row.len > 0 and row[row.len - 1] == '|') row = row[0 .. row.len - 1];

    var cells = std.mem.splitScalar(u8, row, '|');
    var first = true;
    while (cells.next()) |cell_raw| {
        const cell = std.mem.trim(u8, cell_raw, " \t");
        if (cell.len == 0) continue;
        if (!first) try out.appendSlice(allocator, " | ");
        first = false;
        if (use_color) {
            try out.writer(allocator).print("{s}{s}{s}", .{ C_CYAN, cell, C_RESET });
        } else {
            try out.appendSlice(allocator, cell);
        }
    }
    try out.append(allocator, '\n');
    return true;
}

pub fn renderMarkdownForTerminal(allocator: std.mem.Allocator, input: []const u8, use_color: bool) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit(allocator);

    var in_code_block = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        const trimmed_left = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed_left, "```")) {
            in_code_block = !in_code_block;
            continue;
        }

        if (try renderMarkdownTableRow(allocator, &out, line, use_color)) {
            continue;
        }

        if (in_code_block) {
            if (use_color) try out.writer(allocator).print("{s}{s}{s}\n", .{ C_GREY, line, C_RESET }) else {
                try out.appendSlice(allocator, line);
                try out.append(allocator, '\n');
            }
            continue;
        }

        var hashes: usize = 0;
        while (hashes < trimmed_left.len and trimmed_left[hashes] == '#') : (hashes += 1) {}
        if (hashes > 0 and hashes <= 6 and hashes < trimmed_left.len and trimmed_left[hashes] == ' ') {
            const header_text = std.mem.trim(u8, trimmed_left[hashes + 1 ..], " \t");
            if (use_color) try out.writer(allocator).print("{s}{s}{s}{s}\n", .{ C_BOLD, C_CYAN, header_text, C_RESET }) else {
                try out.appendSlice(allocator, header_text);
                try out.append(allocator, '\n');
            }
            continue;
        }

        var content = line;
        if (std.mem.startsWith(u8, trimmed_left, ">")) {
            if (use_color) try out.appendSlice(allocator, C_DIM);
            try out.appendSlice(allocator, "| ");
            content = std.mem.trimLeft(u8, trimmed_left[1..], " \t");
        } else if ((std.mem.startsWith(u8, trimmed_left, "- ") or std.mem.startsWith(u8, trimmed_left, "* ") or std.mem.startsWith(u8, trimmed_left, "+ "))) {
            try out.appendSlice(allocator, "• ");
            content = trimmed_left[2..];
        } else {
            var di: usize = 0;
            while (di < trimmed_left.len and std.ascii.isDigit(trimmed_left[di])) : (di += 1) {}
            if (di > 0 and di + 1 < trimmed_left.len and trimmed_left[di] == '.' and trimmed_left[di + 1] == ' ') {
                try out.appendSlice(allocator, trimmed_left[0 .. di + 2]);
                content = trimmed_left[di + 2 ..];
            }
        }

        try appendInlineMarkdown(allocator, &out, content, use_color);
        if (use_color and std.mem.startsWith(u8, trimmed_left, ">")) {
            try out.appendSlice(allocator, C_RESET);
        }
        try out.append(allocator, '\n');
    }

    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(allocator);
}

fn appendInlineMarkdown(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    use_color: bool,
) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '`')) |end| {
                const code = text[i + 1 .. end];
                if (use_color) try out.writer(allocator).print("{s}{s}{s}", .{ C_YELLOW, code, C_RESET }) else try out.appendSlice(allocator, code);
                i = end + 1;
                continue;
            }
        }

        if (i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, text, i + 2, "**")) |end| {
                const bold_text = text[i + 2 .. end];
                if (use_color) try out.writer(allocator).print("{s}{s}{s}", .{ C_BOLD, bold_text, C_RESET }) else try out.appendSlice(allocator, bold_text);
                i = end + 2;
                continue;
            }
        }

        if (text[i] == '*') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, '*')) |end| {
                const em_text = text[i + 1 .. end];
                if (use_color) try out.writer(allocator).print("{s}{s}{s}", .{ C_ITALIC, em_text, C_RESET }) else try out.appendSlice(allocator, em_text);
                i = end + 1;
                continue;
            }
        }

        if (text[i] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, i + 1, ']')) |close_bracket| {
                if (close_bracket + 2 < text.len and text[close_bracket + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, text, close_bracket + 2, ')')) |close_paren| {
                        const label = text[i + 1 .. close_bracket];
                        const url = text[close_bracket + 2 .. close_paren];
                        if (use_color) try out.writer(allocator).print("{s}{s}{s} ({s})", .{ C_UNDERLINE, label, C_RESET, url }) else {
                            try out.appendSlice(allocator, label);
                            try out.writer(allocator).print(" ({s})", .{url});
                        }
                        i = close_paren + 1;
                        continue;
                    }
                }
            }
        }

        try out.append(allocator, text[i]);
        i += 1;
    }
}
