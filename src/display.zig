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
pub const C_PROMPT = "\x1b[38;5;111m"; // User prompt lines
pub const C_THINKING = "\x1b[38;5;179m"; // Thinking headers

// Background colors
pub const C_REASONING_BG = "\x1b[48;5;234m"; // Very dark gray background for reasoning text
pub const C_REASONING_FG = "\x1b[38;5;252m"; // High-contrast light gray text for reasoning on dark terminals

// Braille spinner frames for working/thinking indicator
const SPINNER_FRAMES = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
var spinner_frame_index: u8 = 0;
var spinner_last_update: i64 = 0;

/// Spinner states for monitoring what the model is doing
pub const SpinnerState = enum(u8) {
    idle = 0,
    thinking = 1,
    tool = 2,
    reading = 3,
    writing = 4,
    bash = 5,
    search = 6,
};

pub var g_spinner_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
var g_spinner_custom_text: [128]u8 = undefined;
var g_spinner_custom_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

// Status bar info
var g_status_provider: [64]u8 = undefined;
var g_status_provider_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var g_status_model: [64]u8 = undefined;
var g_status_model_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);
var g_status_path: [256]u8 = undefined;
var g_status_path_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

pub fn setStatusBarInfo(provider_id: []const u8, model_id: []const u8, path: []const u8) void {
    const p_len = @min(provider_id.len, g_status_provider.len);
    @memcpy(g_status_provider[0..p_len], provider_id[0..p_len]);
    g_status_provider_len.store(p_len, .release);

    const m_len = @min(model_id.len, g_status_model.len);
    @memcpy(g_status_model[0..m_len], model_id[0..m_len]);
    g_status_model_len.store(m_len, .release);

    const path_len = @min(path.len, g_status_path.len);
    @memcpy(g_status_path[0..path_len], path[0..path_len]);
    g_status_path_len.store(path_len, .release);
}

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

    if (custom_len > 0) {
        return std.fmt.bufPrint(buf, "{s}", .{ g_spinner_custom_text[0..custom_len] }) catch "Working...";
    }

    return switch (state) {
        0 => "Ready",
        1 => "Thinking...",
        else => "Running...",
    };
}

/// Get the current braille spinner frame. Call periodically to animate.
/// Returns the spinner character and advances to next frame if enough time passed.
pub fn getSpinnerFrame() []const u8 {
    const now = std.time.milliTimestamp();
    if (now - spinner_last_update > 80) { // Update every 80ms
        spinner_frame_index = @intCast((spinner_frame_index + 1) % SPINNER_FRAMES.len);
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

fn runeDisplayWidth(cp: u21) usize {
    // Zero-width joiners/variation selectors/combining marks.
    if (cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F) or
        (cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or
        (cp >= 0x1DC0 and cp <= 0x1DFF) or
        (cp >= 0x20D0 and cp <= 0x20FF) or
        (cp >= 0xFE20 and cp <= 0xFE2F))
    {
        return 0;
    }

    // Common full-width / emoji ranges that occupy two cells in terminals.
    if ((cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2329 and cp <= 0x232A) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE10 and cp <= 0xFE19) or
        (cp >= 0xFE30 and cp <= 0xFE6F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF))
    {
        return 2;
    }
    return 1;
}

fn displayWidthAnsi(text: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '[') {
            i += 2;
            while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == ';')) : (i += 1) {}
            if (i < text.len) i += 1;
            continue;
        }

        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            n += 1;
            i += 1;
            continue;
        };
        if (i + len > text.len) {
            n += 1;
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            n += 1;
            i += 1;
            continue;
        };
        n += runeDisplayWidth(cp);
        i += len;
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
    // 1. Detect if this is a box (Plan & Progress, etc.)
    const is_box = blk: {
        if (output.len < 3) break :blk false;
        // Check first 32 bytes for any box-drawing characters (allowing for ANSI codes)
        const check_len = @min(output.len, 32);
        break :blk std.mem.indexOf(u8, output[0..check_len], "╭") != null or 
                 std.mem.indexOf(u8, output[0..check_len], "\xe2\x95\xad") != null;
    };

    const MAX_WIDTH: usize = 500;

    // 2. If it's a box, bypass truncation logic entirely
    if (is_box) {
        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= output.len) : (i += 1) {
            if (i == output.len or output[i] == '\n') {
                const raw = output[line_start..i];
                const trimmed = std.mem.trimRight(u8, raw, "\r");
                line_start = i + 1;
                if (trimmed.len == 0) continue;

                // For boxes, we use a simple indent but no L-bracket prefix
                const prefix = "    ";
                if (trimmed.len > MAX_WIDTH) {
                    const safe_len = findUtf8SafeLen(trimmed, MAX_WIDTH);
                    addTimelineEntry("{s}{s}{s}\xe2\x80\xa6{s}\n", .{ prefix, C_GREY, trimmed[0..safe_len], C_RESET });
                } else {
                    addTimelineEntry("{s}{s}{s}{s}\n", .{ prefix, C_GREY, trimmed, C_RESET });
                }
            }
        }
        return;
    }

    // 3. Standard command output truncation logic
    const head_limit: usize = 5;
    const tail_limit: usize = 5;

    const Range = struct { start: usize, end: usize, important: bool = false };
    const MAX_BUFFER = 100;
    var head: [MAX_BUFFER]Range = undefined;
    var head_len: usize = 0;

    var tail: [MAX_BUFFER]Range = undefined;
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

            const is_important = std.mem.indexOf(u8, trimmed, "error:") != null or std.mem.indexOf(u8, trimmed, "note:") != null or std.mem.indexOf(u8, trimmed, "panic:") != null;

            const r: Range = .{ .start = start, .end = end, .important = is_important };
            if (head_len < head_limit) {
                head[head_len] = r;
                head_len += 1;
            }

            // If important, try to keep it in the tail buffer even if it was a while ago
            if (is_important) {
                // Find a non-important slot to replace, or just use the rolling index
                var replaced = false;
                var j: usize = 0;
                while (j < tail_limit) : (j += 1) {
                    if (!tail[j].important) {
                        tail[j] = r;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) {
                    tail[tail_seen % tail_limit] = r;
                    tail_seen += 1;
                }
            } else {
                tail[tail_seen % tail_limit] = r;
                tail_seen += 1;
            }
            if (tail_len < tail_limit) tail_len += 1;
        }
    }

    if (total == 0) return;

    const trunc = total > (head_limit + tail_limit);

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
                    const safe_len = findUtf8SafeLen(trimmed, MAX_WIDTH);
                    addTimelineEntry("{s}{s}{s}\xe2\x80\xa6{s}\n", .{ prefix, C_GREY, trimmed[0..safe_len], C_RESET });
                } else {
                    addTimelineEntry("{s}{s}{s}{s}\n", .{ prefix, C_GREY, trimmed, C_RESET });
                }
            }
        }
        return;
    }

    var printed_any = false;
    for (head[0..head_len]) |r| {
        const line = output[r.start..r.end];
        const prefix = if (!printed_any) "  \xe2\x94\x94 " else "    ";
        printed_any = true;

        if (line.len > MAX_WIDTH) {
            const safe_len = findUtf8SafeLen(line, MAX_WIDTH);
            addTimelineEntry("{s}{s}{s}\xe2\x80\xa6{s}\n", .{ prefix, C_GREY, line[0..safe_len], C_RESET });
        } else {
            addTimelineEntry("{s}{s}{s}{s}\n", .{ prefix, C_GREY, line, C_RESET });
        }
    }

    const omitted = total - head_limit - tail_limit;
    addTimelineEntry("    {s}\xe2\x80\xa6 +{d} lines{s}\n", .{ C_GREY, omitted, C_RESET });

    const first = tail_seen - tail_len;
    var t: usize = 0;
    while (t < tail_len) : (t += 1) {
        const r = tail[(first + t) % tail_limit];
        const line = output[r.start..r.end];
        const prefix = "    ";
        if (line.len > MAX_WIDTH) {
            const safe_len = findUtf8SafeLen(line, MAX_WIDTH);
            addTimelineEntry("{s}{s}{s}\xe2\x80\xa6{s}\n", .{ prefix, C_GREY, line[0..safe_len], C_RESET });
        } else {
            addTimelineEntry("{s}{s}{s}{s}\n", .{ prefix, C_GREY, line, C_RESET });
        }
    }
}

fn findUtf8SafeLen(text: []const u8, max: usize) usize {
    if (text.len <= max) return text.len;
    var i = max;
    // Walk back to start of UTF-8 character (not 10xxxxxx)
    while (i > 0 and (text[i] & 0xc0) == 0x80) : (i -= 1) {}
    return i;
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
pub const TimelineCallback = *const fn ([]const u8) void;
var g_timeline_callback: ?TimelineCallback = null;

// Global stdout mutex to prevent concurrent writes
pub var g_stdout_mutex: std.Thread.Mutex = .{};

pub fn initTimeline(allocator: std.mem.Allocator) void {
    g_timeline_allocator = allocator;
}

pub fn setTimelineCallback(callback: ?TimelineCallback) void {
    g_timeline_callback = callback;
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

pub fn consumeTimelineEntries(allocator: std.mem.Allocator) ![]u8 {
    g_timeline_mutex.lock();
    defer g_timeline_mutex.unlock();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    for (g_timeline_entries.items) |entry| {
        try out.appendSlice(allocator, entry);
        allocator.free(entry);
    }
    g_timeline_entries.clearRetainingCapacity();

    return out.toOwnedSlice(allocator);
}

pub fn addTimelineEntry(comptime format: []const u8, args: anytype) void {
    g_timeline_mutex.lock();
    defer g_timeline_mutex.unlock();
    
    // Also print to stderr immediately so we have a scrolling log
    g_stdout_mutex.lock();
    defer g_stdout_mutex.unlock();
    
    std.debug.print(format, args);

    if (g_timeline_callback) |callback| {
        const rendered = std.fmt.allocPrint(std.heap.page_allocator, format, args) catch return;
        defer std.heap.page_allocator.free(rendered);
        callback(rendered);
    }

    if (g_timeline_allocator) |allocator| {
        const entry = std.fmt.allocPrint(allocator, format, args) catch return;
        g_timeline_entries.append(allocator, entry) catch allocator.free(entry);
    }
}

pub fn addWrappedTimelineEntry(prefix: []const u8, text: []const u8, suffix: []const u8) void {
    const term_width = terminalColumns();
    const reserved_width = visibleLenAnsi(prefix) + visibleLenAnsi(suffix);
    const content_width = if (term_width > reserved_width) term_width - reserved_width else 1;

    var line_start: usize = 0;
    while (line_start <= text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        const line_end = nl orelse text.len;
        const line = text[line_start..line_end];

        if (line.len == 0) {
            addTimelineEntry("{s}{s}{s}\n", .{ prefix, "", suffix });
        } else {
            var start: usize = 0;
            while (start < line.len) {
                // Avoid carrying spaces at the start of wrapped lines.
                while (start < line.len and (line[start] == ' ' or line[start] == '\t')) : (start += 1) {}
                if (start >= line.len) break;

                var j: usize = start;
                var visible_count: usize = 0;
                var last_space_idx: ?usize = null;

                while (j < line.len) {
                    if (line[j] == 0x1b and j + 1 < line.len and line[j + 1] == '[') {
                        j += 2;
                        while (j < line.len and !((line[j] >= 'A' and line[j] <= 'Z') or line[j] == 'm')) : (j += 1) {}
                        if (j < line.len) j += 1;
                        continue;
                    }

                    if (line[j] == ' ' or line[j] == '\t') {
                        last_space_idx = j;
                    }

                    const char_len = std.unicode.utf8ByteSequenceLength(line[j]) catch {
                        if (visible_count + 1 > content_width) break;
                        visible_count += 1;
                        j += 1;
                        continue;
                    };
                    if (j + char_len > line.len) {
                        if (visible_count + 1 > content_width) break;
                        visible_count += 1;
                        j += 1;
                        continue;
                    }
                    const cp = std.unicode.utf8Decode(line[j .. j + char_len]) catch {
                        if (visible_count + 1 > content_width) break;
                        visible_count += 1;
                        j += 1;
                        continue;
                    };
                    const char_width = runeDisplayWidth(cp);
                    if (visible_count + char_width > content_width) break;
                    visible_count += char_width;
                    j += char_len;
                }

                var end = j;
                if (j < line.len) {
                    if (last_space_idx) |space_idx| {
                        if (space_idx > start) end = space_idx;
                    }
                }

                // Hard-wrap if a single token is longer than line width.
                if (end == start) {
                    const char_len = std.unicode.utf8ByteSequenceLength(line[start]) catch 1;
                    end = start + char_len;
                    if (end > line.len) end = start + 1;
                }

                const chunk = std.mem.trimRight(u8, line[start..end], " \t");
                addTimelineEntry("{s}{s}{s}\n", .{ prefix, chunk, suffix });
                start = end;
            }
        }

        if (nl == null) break;
        line_start = line_end + 1;
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

pub fn setupScrollingRegion(stdout_file: std.fs.File) void {
    const height = getTerminalHeight();
    const width = terminalColumns();
    if (height < 3) return; // Need at least 3 lines for status + space
    
    // 1. Clear screen and move to top-left
    _ = stdout_file.write("\x1b[2J\x1b[H") catch {};

    // 2. Print a horizontal line to mark the start of the session
    const line_color = "\x1b[38;5;240m"; // Dark grey
    std.debug.print("{s}", .{line_color});
    var w: usize = 0;
    while (w < width) : (w += 1) std.debug.print("\xe2\x94\x80", .{});
    std.debug.print("{s}\n", .{C_RESET});

    // 3. DECSTBM: Set Top and Bottom Margins
    // We reserve the LAST line for status.
    // Margins are 1-based.
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[1;{d}r", .{height - 1}) catch return;
    _ = stdout_file.write(seq) catch {};
    // Ensure cursor is in region at line 2 (below our separator)
    _ = stdout_file.write("\x1b[2;1H") catch {};

    // Initial status bar draw so it's not empty
    renderStatusBar(stdout_file, " ", "Ready");
}

pub const BoxStyle = struct {
    top_left: []const u8 = "\xe2\x95\xad", // ╭
    top_right: []const u8 = "\xe2\x95\xae", // ╮
    bottom_left: []const u8 = "\xe2\x95\xb0", // ╰
    bottom_right: []const u8 = "\xe2\x95\xaf", // ╯
    horizontal: []const u8 = "\xe2\x94\x80", // ─
    vertical: []const u8 = "\xe2\x94\x82", // │
    mid_left: []const u8 = "\xe2\x94\x9c", // ├
    mid_right: []const u8 = "\xe2\x94\xa4", // ┤
};

pub fn renderBox(allocator: std.mem.Allocator, title: []const u8, lines: []const []const u8, width: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);
    const s = BoxStyle{};

    const inner_width = width - 2;

    // Top
    try w.writeAll(C_DIM);
    try w.writeAll(s.top_left);
    var i: usize = 0;
    while (i < inner_width) : (i += 1) try w.writeAll(s.horizontal);
    try w.writeAll(s.top_right);
    try w.writeAll(C_RESET);
    try w.writeAll("\n");

    // Title line if present
    if (title.len > 0) {
        try w.writeAll(C_DIM);
        try w.writeAll(s.vertical);
        try w.writeAll(C_RESET);
        try w.writeAll("  ");
        try w.writeAll(C_BOLD);
        try w.writeAll(C_CYAN);
        try w.writeAll(title);
        try w.writeAll(C_RESET);
        
        const padding = if (inner_width > title.len + 2) inner_width - 2 - title.len else 0;
        i = 0;
        while (i < padding) : (i += 1) try w.writeByte(' ');
        
        try w.writeAll(C_DIM);
        try w.writeAll(s.vertical);
        try w.writeAll(C_RESET);
        try w.writeAll("\n");

        try w.writeAll(C_DIM);
        try w.writeAll(s.mid_left);
        i = 0;
        while (i < inner_width) : (i += 1) try w.writeAll(s.horizontal);
        try w.writeAll(s.mid_right);
        try w.writeAll(C_RESET);
        try w.writeAll("\n");
    }

    // Content with ANSI-aware word wrapping
    for (lines) |line| {
        var start: usize = 0;
        while (start < line.len or line.len == 0) {
            try w.writeAll(C_DIM);
            try w.writeAll(s.vertical);
            try w.writeAll(C_RESET);
            try w.writeAll(" ");
            
            var visible_count: usize = 0;
            var j: usize = start;
            var last_space_idx: ?usize = null;
            var last_space_visible: usize = 0;
            const target_width = width - 4;

            while (j < line.len and visible_count < target_width) {
                if (line[j] == 0x1b and j + 1 < line.len and line[j + 1] == '[') {
                    const esc_start = j;
                    j += 2;
                    while (j < line.len and !((line[j] >= 'A' and line[j] <= 'Z') or line[j] == 'm')) : (j += 1) {}
                    j += 1;
                    try w.writeAll(line[esc_start..j]);
                    continue;
                }
                
                if (line[j] == ' ') {
                    last_space_idx = j;
                    last_space_visible = visible_count;
                }

                const char_len = std.unicode.utf8ByteSequenceLength(line[j]) catch 1;
                j += char_len;
                visible_count += 1;
            }

            var end = j;
            var end_visible = visible_count;

            if (end < line.len and last_space_idx != null) {
                end = last_space_idx.? + 1;
                end_visible = last_space_visible + 1;
            }

            // Write the chunk
            var k: usize = start;
            var written_visible: usize = 0;
            while (k < end) {
                if (line[k] == 0x1b and k + 1 < line.len and line[k + 1] == '[') {
                    const esc_start = k;
                    k += 2;
                    while (k < line.len and !((line[k] >= 'A' and line[k] <= 'Z') or line[k] == 'm')) : (k += 1) {}
                    k += 1;
                    try w.writeAll(line[esc_start..k]);
                    continue;
                }
                const char_len = std.unicode.utf8ByteSequenceLength(line[k]) catch 1;
                try w.writeAll(line[k .. k + char_len]);
                k += char_len;
                written_visible += 1;
            }

            const padding = target_width - written_visible;
            var p: usize = 0;
            while (p < padding) : (p += 1) try w.writeByte(' ');
            
            try w.writeAll(" ");
            try w.writeAll(C_DIM);
            try w.writeAll(s.vertical);
            try w.writeAll(C_RESET);
            try w.writeAll("\n");
            
            start = end;
            if (start >= line.len and line.len > 0) break;
            if (line.len == 0) break;
        }
    }

    // Bottom
    try w.writeAll(C_DIM);
    try w.writeAll(s.bottom_left);
    i = 0;
    while (i < inner_width) : (i += 1) try w.writeAll(s.horizontal);
    try w.writeAll(s.bottom_right);
    try w.writeAll(C_RESET);
    try w.writeAll("\n");

    return out.toOwnedSlice(allocator);
}

pub fn resetScrollingRegion(stdout_file: std.fs.File) void {
    const height = getTerminalHeight();

    // Clear pinned status bar line so shell prompt is not visually polluted.
    var clear_buf: [32]u8 = undefined;
    const clear_seq = std.fmt.bufPrint(&clear_buf, "\x1b[{d};1H\x1b[2K", .{height}) catch "";
    if (clear_seq.len > 0) _ = stdout_file.write(clear_seq) catch {};

    // Reset margins to full screen
    _ = stdout_file.write("\x1b[r") catch {};
    // Ensure cursor is at bottom of region
    var buf: [32]u8 = undefined;
    const seq = std.fmt.bufPrint(&buf, "\x1b[{d};1H", .{height}) catch return;
    _ = stdout_file.write(seq) catch {};
}

fn trimCellMarkdown(cell: []const u8) []const u8 {
    const t = std.mem.trim(u8, cell, " \t");
    if (t.len >= 4 and std.mem.startsWith(u8, t, "**") and std.mem.endsWith(u8, t, "**")) {
        return t[2 .. t.len - 2];
    }
    if (t.len >= 2 and std.mem.startsWith(u8, t, "`") and std.mem.endsWith(u8, t, "`")) {
        return t[1 .. t.len - 1];
    }
    return t;
}

fn splitPipeRow(allocator: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var t = std.mem.trim(u8, line, " \t");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= t.len) : (i += 1) {
        if (i == t.len or t[i] == '|') {
            try out.append(allocator, std.mem.trim(u8, t[start..i], " \t"));
            start = i + 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isPipeTableSeparator(line: []const u8) bool {
    var t = std.mem.trim(u8, line, " \t");
    if (t.len > 0 and t[0] == '|') t = t[1..];
    if (t.len > 0 and t[t.len - 1] == '|') t = t[0 .. t.len - 1];
    if (t.len == 0) return false;

    var has_dash = false;
    for (t) |c| {
        switch (c) {
            '-' => has_dash = true,
            ':', ' ', '\t', '|' => {},
            else => return false,
        }
    }
    return has_dash;
}

fn isPipeTableRow(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return std.mem.indexOfScalar(u8, t, '|') != null and !std.mem.startsWith(u8, t, "```");
}

fn writeRepeated(writer: anytype, s: []const u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try writer.writeAll(s);
}

fn renderAnsiPipeTable(allocator: std.mem.Allocator, header_line: []const u8, body_lines: []const []const u8) ![]u8 {
    const header_cells = try splitPipeRow(allocator, header_line);
    defer allocator.free(header_cells);
    if (header_cells.len < 2) return allocator.dupe(u8, header_line);

    const cols = header_cells.len;
    var widths = try allocator.alloc(usize, cols);
    defer allocator.free(widths);
    @memset(widths, 0);

    for (header_cells, 0..) |c, idx| widths[idx] = displayWidthAnsi(trimCellMarkdown(c));

    for (body_lines) |line| {
        const cells = try splitPipeRow(allocator, line);
        defer allocator.free(cells);
        var i: usize = 0;
        while (i < cols) : (i += 1) {
            const cell = if (i < cells.len) trimCellMarkdown(cells[i]) else "";
            const n = displayWidthAnsi(cell);
            if (n > widths[i]) widths[i] = n;
        }
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    // Top border
    try w.writeAll(C_DIM ++ "┌");
    for (widths, 0..) |wd, i| {
        try writeRepeated(w, "─", wd + 2);
        try w.writeAll(if (i + 1 < cols) "┬" else "┐");
    }
    try w.writeAll(C_RESET ++ "\n");

    // Header row
    try w.writeAll(C_DIM ++ "│" ++ C_RESET);
    for (header_cells, 0..) |c, i| {
        const cell = trimCellMarkdown(c);
        try w.writeAll(" ");
        try w.writeAll(C_BOLD ++ C_BRIGHT_WHITE);
        try w.writeAll(cell);
        try w.writeAll(C_RESET);
        const pad = widths[i] - displayWidthAnsi(cell);
        try writeRepeated(w, " ", pad + 1);
        try w.writeAll(C_DIM ++ "│" ++ C_RESET);
    }
    try w.writeAll("\n");

    // Header separator
    try w.writeAll(C_DIM ++ "├");
    for (widths, 0..) |wd, i| {
        try writeRepeated(w, "─", wd + 2);
        try w.writeAll(if (i + 1 < cols) "┼" else "┤");
    }
    try w.writeAll(C_RESET ++ "\n");

    // Body rows
    for (body_lines) |line| {
        const cells = try splitPipeRow(allocator, line);
        defer allocator.free(cells);
        try w.writeAll(C_DIM ++ "│" ++ C_RESET);
        var i: usize = 0;
        while (i < cols) : (i += 1) {
            const cell = if (i < cells.len) trimCellMarkdown(cells[i]) else "";
            try w.writeAll(" ");
            try w.writeAll(cell);
            const pad = widths[i] - displayWidthAnsi(cell);
            try writeRepeated(w, " ", pad + 1);
            try w.writeAll(C_DIM ++ "│" ++ C_RESET);
        }
        try w.writeAll("\n");
    }

    // Bottom border
    try w.writeAll(C_DIM ++ "└");
    for (widths, 0..) |wd, i| {
        try writeRepeated(w, "─", wd + 2);
        try w.writeAll(if (i + 1 < cols) "┴" else "┘");
    }
    try w.writeAll(C_RESET ++ "\n");

    return out.toOwnedSlice(allocator);
}

fn orderedListMarkerLen(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == 0 or i + 1 >= line.len) return null;
    if (line[i] == '.' and line[i + 1] == ' ') return i + 2;
    return null;
}

fn renderMarkdownInline(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    var i: usize = 0;
    var in_code = false;
    var in_bold = false;
    while (i < text.len) {
        if (!in_code and i + 1 < text.len and text[i] == '*' and text[i + 1] == '*') {
            if (in_bold) {
                try w.writeAll(C_RESET);
            } else {
                try w.writeAll(C_BOLD);
            }
            in_bold = !in_bold;
            i += 2;
            continue;
        }
        if (text[i] == '`') {
            if (in_code) {
                try w.writeAll(C_RESET);
                if (in_bold) try w.writeAll(C_BOLD);
            } else {
                try w.writeAll(C_ORANGE);
            }
            in_code = !in_code;
            i += 1;
            continue;
        }
        try w.writeByte(text[i]);
        i += 1;
    }

    if (in_code or in_bold) try w.writeAll(C_RESET);
    return out.toOwnedSlice(allocator);
}

fn renderMarkdownLine(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    const trimmed_left = std.mem.trimLeft(u8, line, " \t");
    const indent_len = line.len - trimmed_left.len;
    const indent = line[0..indent_len];

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    if (std.mem.startsWith(u8, trimmed_left, "### ")) {
        try w.writeAll(indent);
        try w.writeAll(C_BOLD ++ C_CYAN);
        try w.writeAll(trimmed_left[4..]);
        try w.writeAll(C_RESET);
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.startsWith(u8, trimmed_left, "## ")) {
        try w.writeAll(indent);
        try w.writeAll(C_BOLD ++ C_CYAN);
        try w.writeAll(trimmed_left[3..]);
        try w.writeAll(C_RESET);
        return out.toOwnedSlice(allocator);
    }
    if (std.mem.startsWith(u8, trimmed_left, "# ")) {
        try w.writeAll(indent);
        try w.writeAll(C_BOLD ++ C_CYAN);
        try w.writeAll(trimmed_left[2..]);
        try w.writeAll(C_RESET);
        return out.toOwnedSlice(allocator);
    }

    if (orderedListMarkerLen(trimmed_left)) |marker_len| {
        try w.writeAll(indent);
        try w.writeAll(C_CYAN);
        try w.writeAll(trimmed_left[0..marker_len]);
        try w.writeAll(C_RESET);
        const rest = try renderMarkdownInline(allocator, trimmed_left[marker_len..]);
        defer allocator.free(rest);
        try w.writeAll(rest);
        return out.toOwnedSlice(allocator);
    }
    if (trimmed_left.len >= 2 and ((trimmed_left[0] == '-' or trimmed_left[0] == '*') and trimmed_left[1] == ' ')) {
        try w.writeAll(indent);
        try w.writeAll(C_CYAN);
        try w.writeAll(trimmed_left[0..2]);
        try w.writeAll(C_RESET);
        const rest = try renderMarkdownInline(allocator, trimmed_left[2..]);
        defer allocator.free(rest);
        try w.writeAll(rest);
        return out.toOwnedSlice(allocator);
    }

    const inline_rendered = try renderMarkdownInline(allocator, line);
    defer allocator.free(inline_rendered);
    try w.writeAll(inline_rendered);
    return out.toOwnedSlice(allocator);
}

pub fn addAssistantMessage(allocator: std.mem.Allocator, text: []const u8) !void {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (i == text.len or text[i] == '\n') {
            try lines.append(allocator, std.mem.trimRight(u8, text[start..i], "\r"));
            start = i + 1;
        }
    }

    var is_first_output = true;
    var in_code_fence = false;
    var idx: usize = 0;
    while (idx < lines.items.len) {
        const line = lines.items[idx];
        const trimmed_line = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed_line, "```")) {
            in_code_fence = !in_code_fence;
            idx += 1;
            continue;
        }

        if (idx + 1 < lines.items.len and isPipeTableRow(lines.items[idx]) and isPipeTableSeparator(lines.items[idx + 1])) {
            const table_start = idx;
            idx += 2; // skip header + separator
            while (idx < lines.items.len and isPipeTableRow(lines.items[idx])) : (idx += 1) {}

            const rendered = try renderAnsiPipeTable(allocator, lines.items[table_start], lines.items[table_start + 2 .. idx]);
            defer allocator.free(rendered);

            if (is_first_output) {
                addTimelineEntry("{s}⛬{s}\n", .{ C_CYAN, C_RESET });
                is_first_output = false;
            }
            addTimelineEntry("{s}", .{rendered});
            continue;
        }

        const rendered_line = if (in_code_fence)
            try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ C_ORANGE, line, C_RESET })
        else
            try renderMarkdownLine(allocator, line);
        defer allocator.free(rendered_line);

        if (is_first_output) {
            addTimelineEntry("{s}⛬{s} {s}\n", .{ C_CYAN, C_RESET, rendered_line });
            is_first_output = false;
        } else {
            addTimelineEntry("{s}\n", .{rendered_line});
        }
        idx += 1;
    }
}

// Track if spinner is active to reserve space for it
pub var g_spinner_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn setSpinnerActive(active: bool) void {
    g_spinner_active.store(active, .release);
}

pub fn renderStatusBar(stdout_file: std.fs.File, spinner_frame: []const u8, state_text: []const u8) void {
    const term_height = getTerminalHeight();
    const term_width = terminalColumns();

    g_stdout_mutex.lock();
    defer g_stdout_mutex.unlock();

    // Target the absolute last line (outside the scrolling region)
    const bg_color = "\x1b[48;5;235m"; // Dark grey background
    const fg_color = "\x1b[38;5;250m"; // Light grey foreground
    const accent_color = "\x1b[38;5;110m"; // Soft blue for labels
    
    const p_len = g_status_provider_len.load(.acquire);
    const m_len = g_status_model_len.load(.acquire);
    const path_len = g_status_path_len.load(.acquire);

    var buf: [1024]u8 = undefined;
    
    // Status text (Spinner + State) - Fixed width 30 chars
    // Provider/Model - Fixed start at col 32
    // Path - Fixed start at col 64 or right aligned? 
    // Let's use specific widths.
    
    var id_buf: [128]u8 = undefined;
    // Spinner + State: "⠋ Thinking..." (max ~20 chars)
    const status_part = std.fmt.bufPrint(&id_buf, "{s} {s}", .{spinner_frame, state_text}) catch " ";
    
    // Model ID: "openai/gpt-4"
    const full_id = std.fmt.bufPrint(&buf, "{s}/{s}", .{ g_status_provider[0..p_len], g_status_model[0..m_len] }) catch "model";

    // Path
    const path_str = g_status_path[0..path_len];

    // Construct the full line with explicit padding
    // We use a new buffer for the final escape sequence
    var final_buf: [2048]u8 = undefined;
    const status = std.fmt.bufPrint(&final_buf, "\x1b[s\x1b[{d};1H{s}{s} {s: <18} {s} {s: <22} {s} {s}\x1b[K\x1b[0m\x1b[u", .{
        term_height,
        bg_color,
        fg_color,
        status_part, // Left (Status)
        accent_color,
        full_id,     // Middle (Model)
        fg_color,
        path_str,    // Right (Path)
    }) catch return;

    const safe_len = @min(status.len, term_width + 100); // 100 for escape codes
    _ = stdout_file.write(status[0..safe_len]) catch {};
}
