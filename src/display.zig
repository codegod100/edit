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

// Braille spinner frames for working/thinking indicator
const SPINNER_FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
var spinner_frame_index: u8 = 0;
var spinner_last_update: i64 = 0;

/// Spinner states for monitoring what the model is doing
pub const SpinnerState = enum(u8) {
    thinking = 0,
    tool = 1,
    reading = 2,
    writing = 3,
    bash = 4,
    search = 5,
};

var g_spinner_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var g_spinner_custom_text: [128]u8 = undefined;
var g_spinner_custom_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

pub fn setSpinnerState(state: SpinnerState) void {
    g_spinner_state.store(@intFromEnum(state), .release);
    g_spinner_custom_len.store(0, .release);
}

pub fn setSpinnerStateWithText(state: SpinnerState, text: []const u8) void {
    g_spinner_state.store(@intFromEnum(state), .release);
    const len = @min(text.len, g_spinner_custom_text.len);
    @memcpy(g_spinner_custom_text[0..len], text[0..len]);
    g_spinner_custom_len.store(len, .release);
}

pub fn getSpinnerStateText(buf: []u8) []const u8 {
    const custom_len = g_spinner_custom_len.load(.acquire);
    const state = g_spinner_state.load(.acquire);
    const state_name = switch (state) {
        1 => "tool",
        2 => "read",
        3 => "write",
        4 => "$",
        5 => "search",
        else => "Thinking",
    };

    if (custom_len > 0) {
        // Format: "state: custom_text"
        const fmt = std.fmt.bufPrint(buf, "{s}: {s}", .{ state_name, g_spinner_custom_text[0..custom_len] }) catch state_name;
        return fmt;
    }
    return state_name;
}

/// Get the current braille spinner frame. Call periodically to animate.
/// Returns the spinner character and advances to next frame if enough time passed.
pub fn getSpinnerFrame() []const u8 {
    const now = std.time.milliTimestamp();
    if (now - spinner_last_update > 80) { // Update every 80ms
        spinner_frame_index = (spinner_frame_index + 1) % SPINNER_FRAMES.len;
        spinner_last_update = now;
    }
    return SPINNER_FRAMES[spinner_frame_index];
}

/// Reset spinner to first frame
pub fn resetSpinner() void {
    spinner_frame_index = 0;
    spinner_last_update = 0;
    g_spinner_state.store(0, .release);
}

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

pub fn stripAnsi(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == ';' or text[i] == 'm' or text[i] == 'K' or text[i] == 'A' or text[i] == 'B' or text[i] == 'C' or text[i] == 'D' or text[i] == 'H' or text[i] == 'J')) : (i += 1) {
                const c = text[i];
                if (c >= 'A' and c <= 'Z' or c == 'm') {
                    i += 1;
                    break;
                }
            }
            continue;
        }
        try out.append(allocator, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
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

    var out: std.ArrayListUnmanaged(u8) = .empty;
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
    _ = stdout;
    // Use timeline callback instead of direct stdout
    formatTruncatedCommandOutput(output);
}

/// Format command output for timeline and add it via callback
fn formatTruncatedCommandOutput(output: []const u8) void {
    const HEAD: usize = 5;
    const TAIL: usize = 5;

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
    const MAX_WIDTH: usize = 120;

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

                const prefix = if (!printed_any) "  \xe2\x94\x94 " else "    ";
                printed_any = true;
                
                if (trimmed.len > MAX_WIDTH) {
                    addTimelineEntry("{s}{s}{s}\xe2\x80\xa6{s}", .{ prefix, C_GREY, trimmed[0..MAX_WIDTH], C_RESET });
                } else {
                    addTimelineEntry("{s}{s}{s}{s}", .{ prefix, C_GREY, trimmed, C_RESET });
                }
            }
        }
        return;
    }

    var printed_any = false;
    for (head[0..HEAD]) |r| {
        const prefix = if (!printed_any) "  \xe2\x94\x94 " else "    ";
        printed_any = true;
        const line = output[r.start..r.end];
        if (line.len > MAX_WIDTH) {
            addTimelineEntry("{s}{s}{s}\xe2\x80\xa6{s}", .{ prefix, C_GREY, line[0..MAX_WIDTH], C_RESET });
        } else {
            addTimelineEntry("{s}{s}{s}{s}", .{ prefix, C_GREY, line, C_RESET });
        }
    }

    const omitted = total - HEAD - TAIL;
    addTimelineEntry("    {s}\xe2\x80\xa6 +{d} lines{s}", .{ C_GREY, omitted, C_RESET });

    const first = tail_seen - tail_len;
    var t: usize = 0;
    while (t < tail_len) : (t += 1) {
        const r = tail[(first + t) % TAIL];
        const line = output[r.start..r.end];
        if (line.len > MAX_WIDTH) {
            addTimelineEntry("    {s}{s}{s}\xe2\x80\xa6{s}", .{ C_GREY, line[0..MAX_WIDTH], C_RESET, "" });
        } else {
            addTimelineEntry("    {s}{s}{s}", .{ C_GREY, line, C_RESET });
        }
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
var g_timeline_mutex: std.Thread.Mutex = .{};

// Global stdout mutex to prevent concurrent writes
pub var g_stdout_mutex: std.Thread.Mutex = .{};

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
    g_timeline_mutex.lock();
    defer g_timeline_mutex.unlock();
    if (g_timeline_allocator) |allocator| {
        const entry = std.fmt.allocPrint(allocator, format, args) catch return;
        g_timeline_entries.append(allocator, entry) catch allocator.free(entry);
    }
}

// Track if spinner is active to reserve space for it
pub var g_spinner_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn setSpinnerActive(active: bool) void {
    g_spinner_active.store(active, .release);
}

/// Redraw the entire screen with timeline and current prompt.
/// Uses direct File access to avoid buffering issues.
pub fn clearScreenAndRedrawTimeline(stdout_file: std.fs.File, current_prompt: []const u8) !void {
    // Lock stdout for atomic redraw
    g_stdout_mutex.lock();
    defer g_stdout_mutex.unlock();

    // Get terminal dimensions first
    const term_height = getTerminalHeight();

    // Count lines in prompt
    var prompt_lines: usize = 0;
    for (current_prompt) |c| {
        if (c == '\n') prompt_lines += 1;
    }
    if (prompt_lines == 0) prompt_lines = 4;

    // Reserve extra line as buffer between timeline and prompt
    const spinner_buffer: usize = if (g_spinner_active.load(.acquire)) 2 else 1;
    const reserved_lines = prompt_lines + spinner_buffer;
    const max_timeline_lines = if (term_height > reserved_lines) term_height - reserved_lines else 5;

    // Move to top-left and clear everything below it (avoids scrollback pollution)
    try stdout_file.writeAll("\x1b[H\x1b[J");

    // Lock timeline for reading
    g_timeline_mutex.lock();
    defer g_timeline_mutex.unlock();

    // Calculate total lines in timeline entries
    var total_entry_lines: usize = 0;
    for (g_timeline_entries.items) |entry| {
        var lines_in_entry: usize = 0;
        for (entry) |c| {
            if (c == '\n') lines_in_entry += 1;
        }
        if (entry.len > 0 and entry[entry.len - 1] != '\n') lines_in_entry += 1;
        total_entry_lines += lines_in_entry;
    }

    // Determine which entries to show (scrolling if needed)
    // We want to fill exactly max_timeline_lines
    const lines_to_show = @min(total_entry_lines, max_timeline_lines);
    var start_idx: usize = 0;

    if (total_entry_lines > max_timeline_lines) {
        // Scroll: skip oldest entries
        var lines_to_skip = total_entry_lines - max_timeline_lines;
        var idx: usize = 0;
        while (idx < g_timeline_entries.items.len and lines_to_skip > 0) {
            var lines_in_entry: usize = 0;
            for (g_timeline_entries.items[idx]) |c| {
                if (c == '\n') lines_in_entry += 1;
            }
            if (g_timeline_entries.items[idx].len > 0 and g_timeline_entries.items[idx][g_timeline_entries.items[idx].len - 1] != '\n') lines_in_entry += 1;

            if (lines_in_entry <= lines_to_skip) {
                lines_to_skip -= lines_in_entry;
                idx += 1;
            } else {
                break;
            }
        }
        start_idx = idx;
    }

    // Print blank lines to push content down if timeline is shorter than max
    // This ensures the prompt is always at the bottom
    const leading_blanks = max_timeline_lines - lines_to_show;
    for (0..leading_blanks) |_| {
        try stdout_file.writeAll("\n");
    }

    // Draw timeline entries
    var idx = start_idx;
    while (idx < g_timeline_entries.items.len) : (idx += 1) {
        const entry = g_timeline_entries.items[idx];
        if (entry.len == 0) continue;
        try stdout_file.writeAll(entry);
        if (entry[entry.len - 1] != '\n') try stdout_file.writeAll("\n");
    }

    // Exactly one blank line before prompt (this is the spinner buffer line)
    try stdout_file.writeAll("\n");

    // Draw prompt at bottom
    try stdout_file.writeAll(current_prompt);

    // Position cursor in input line (│ > ) if it's a TTY and spinner is NOT active
    // Standard prompt is 4 lines. Input is 3rd from bottom.
    const is_tty = std.posix.isatty(stdout_file.handle);
    if (is_tty and !g_spinner_active.load(.acquire)) {
        try stdout_file.writeAll("\x1b[3A\x1b[5G");
        // Ensure cursor is visible and block style
        try stdout_file.writeAll("\x1b[?25h\x1b[1 q");
    }
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

fn renderMarkdownTableRow(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), line: []const u8, use_color: bool) !bool {
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
    var out: std.ArrayListUnmanaged(u8) = .empty;
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
    out: *std.ArrayListUnmanaged(u8),
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
