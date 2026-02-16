const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("cancel.zig");
const mentions = @import("mentions.zig");
const context = @import("context.zig");

pub const EditKey = enum {
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

pub fn stdInFile() std.fs.File {
    if (@hasDecl(std.fs.File, "stdin")) {
        return std.fs.File.stdin();
    }
    if (@hasDecl(std.io, "getStdIn")) {
        return std.io.getStdIn();
    }
    @compileError("No supported stdin API in this Zig version");
}

pub fn stdOutFile() std.fs.File {
    if (@hasDecl(std.fs.File, "stdout")) {
        return std.fs.File.stdout();
    }
    if (@hasDecl(std.io, "getStdOut")) {
        return std.io.getStdOut();
    }
    @compileError("No supported stdout API in this Zig version");
}

pub fn applyEditKey(
    allocator: std.mem.Allocator,
    current: []const u8,
    key: EditKey,
    character: u8,
    autocompleteCommandFn: *const fn ([]const u8) []const u8,
) ![]u8 {
    return switch (key) {
        .tab => allocator.dupe(u8, autocompleteCommandFn(current)),
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
        else => allocator.dupe(u8, current),
    };
}

pub fn applyEditKeyAtCursor(
    allocator: std.mem.Allocator,
    current: []const u8,
    key: EditKey,
    character: u8,
    cursor_pos: usize,
    autocompleteCommandFn: *const fn ([]const u8) []const u8,
) !mentions.LineEditResult {
    const pos = @min(cursor_pos, current.len);

    return switch (key) {
        .tab => {
            if (try mentions.autocompleteMentionAtCursor(allocator, current, pos)) |completed| {
                return completed;
            }
            const text = try allocator.dupe(u8, autocompleteCommandFn(current));
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

pub fn readPromptLine(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdin_reader: anytype,
    stdout: anytype,
    prompt: []const u8,
    history: *context.CommandHistory,
) !?[]u8 {

    const original = std.posix.tcgetattr(stdin_file.handle) catch {
        try stdout.writeAll(prompt);
        return stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    };

    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    if (builtin.os.tag == .linux) {
        raw.cc[6] = 1;
        raw.cc[5] = 0;
    } else if (builtin.os.tag == .macos) {
        raw.cc[16] = 1;
        raw.cc[17] = 0;
    }
    std.posix.tcsetattr(stdin_file.handle, .NOW, raw) catch |err| {
        // If terminal setup fails (e.g., Ctrl+C pressed), fall back to simple mode
        std.log.debug("Failed to set raw mode: {any}", .{err});
        try stdout.writeAll(prompt);
        return stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    };
    defer std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};

    // Initial draw of timeline + prompt
    const display = @import("display.zig");
    try display.clearScreenAndRedrawTimeline(stdout, prompt);
    
    // Use arena for line editing to simplify memory management
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var line: []u8 = &.{};
    var cursor_pos: usize = 0;
    var buf: [1]u8 = undefined;
    
    // History navigation state
    var history_index: ?usize = null; // null means not navigating history (editing current)
    var saved_line: []u8 = &.{}; // Line being edited before history navigation

    while (true) {
        const n = try stdin_file.read(&buf);
        if (n == 0) {
            if (line.len == 0) return null;
            return try allocator.dupe(u8, line);
        }

        const ch = buf[0];

        // Escape sequence (arrow keys, etc.)
        if (ch == 27) {
            // Check for escape sequence [X
            var seq_buf: [2]u8 = undefined;
            const seq_n = stdin_file.read(&seq_buf) catch 0;
            if (seq_n >= 2 and seq_buf[0] == '[') {
                switch (seq_buf[1]) {
                    'D' => { // Left arrow
                        if (cursor_pos > 0) {
                            cursor_pos -= 1;
                            try stdout.writeAll("\x1b[D");
                        }
                    },
                    'C' => { // Right arrow
                        if (cursor_pos < line.len) {
                            cursor_pos += 1;
                            try stdout.writeAll("\x1b[C");
                        }
                    },
                    'A' => { // Up arrow - previous history entry
                        if (history.items.items.len == 0) continue;
                        
                        // Save current line if starting history navigation
                        if (history_index == null) {
                            saved_line = try arena_alloc.dupe(u8, line);
                            history_index = history.items.items.len;
                        }
                        
                        if (history_index.? > 0) {
                            history_index.? -= 1;
                            const history_entry = history.items.items[history_index.?];
                            
                            // Clear current line and load history entry
                            // Move cursor to end of current line first
                            while (cursor_pos < line.len) {
                                cursor_pos += 1;
                                try stdout.writeAll("\x1b[C");
                            }
                            // Clear from cursor to beginning of line
                            for (0..line.len) |_| {
                                try stdout.writeAll("\x08 \x08");
                            }
                            
                            line = try arena_alloc.dupe(u8, history_entry);
                            cursor_pos = line.len;
                            try stdout.writeAll(line);
                        }
                    },
                    'B' => { // Down arrow - next history entry
                        if (history_index == null) continue;
                        
                        if (history_index.? < history.items.items.len - 1) {
                            history_index.? += 1;
                            const history_entry = history.items.items[history_index.?];
                            
                            // Clear current line and load history entry
                            while (cursor_pos < line.len) {
                                cursor_pos += 1;
                                try stdout.writeAll("\x1b[C");
                            }
                            for (0..line.len) |_| {
                                try stdout.writeAll("\x08 \x08");
                            }
                            
                            line = try arena_alloc.dupe(u8, history_entry);
                            cursor_pos = line.len;
                            try stdout.writeAll(line);
                        } else {
                            // At end of history, restore saved line
                            history_index = null;
                            
                            // Clear current line
                            while (cursor_pos < line.len) {
                                cursor_pos += 1;
                                try stdout.writeAll("\x1b[C");
                            }
                            for (0..line.len) |_| {
                                try stdout.writeAll("\x08 \x08");
                            }
                            
                            line = try arena_alloc.dupe(u8, saved_line);
                            cursor_pos = line.len;
                            try stdout.writeAll(line);
                        }
                    },
                    'H' => { // Home
                        while (cursor_pos > 0) {
                            cursor_pos -= 1;
                            try stdout.writeAll("\x1b[D");
                        }
                    },
                    'F' => { // End
                        while (cursor_pos < line.len) {
                            cursor_pos += 1;
                            try stdout.writeAll("\x1b[C");
                        }
                    },
                    '3' => { // Delete key (ESC [ 3 ~)
                        var tilde_buf: [1]u8 = undefined;
                        _ = stdin_file.read(&tilde_buf) catch {};
                        if (cursor_pos < line.len) {
                            const new_len = line.len - 1;
                            const new_line = try arena_alloc.alloc(u8, new_len);
                            @memcpy(new_line[0..cursor_pos], line[0..cursor_pos]);
                            @memcpy(new_line[cursor_pos..], line[cursor_pos + 1 ..]);
                            // arena freed on defer
                            line = new_line;
                            // Redraw from cursor to end
                            try stdout.writeAll(line[cursor_pos..]);
                            try stdout.writeAll(" ");
                            for (0..line.len - cursor_pos + 1) |_| {
                                try stdout.writeAll("\x1b[D");
                            }
                        }
                    },
                    else => {},
                }
            } else {
                // Just ESC - cancel
                cancel.setCancelled();
                try stdout.print("\n^C (cancelled)\n", .{});
                return try allocator.dupe(u8, "");
            }
            continue;
        }

        if (ch == 3) { // Ctrl+C
            return null;
        }

        if (ch == '\n' or ch == '\r') {
            try stdout.print("\n", .{});
            return try allocator.dupe(u8, line);
        }

        if (ch == 127 or ch == 8) { // Backspace
            if (cursor_pos > 0) {
                const new_len = line.len - 1;
                const new_line = try arena_alloc.alloc(u8, new_len);
                @memcpy(new_line[0 .. cursor_pos - 1], line[0 .. cursor_pos - 1]);
                @memcpy(new_line[cursor_pos - 1 ..], line[cursor_pos..]);
                // arena freed on defer
                line = new_line;
                cursor_pos -= 1;
                // Move cursor back, clear character, move back again
                try stdout.writeAll("\x08 \x08");
                // Redraw rest of line
                if (cursor_pos < line.len) {
                    try stdout.writeAll(line[cursor_pos..]);
                    try stdout.writeAll(" ");
                    for (0..line.len - cursor_pos + 1) |_| {
                        try stdout.writeAll("\x1b[D");
                    }
                }
            }
            continue;
        }

        if (ch >= 32 and ch < 127) { // Printable character
            const new_line = try arena_alloc.alloc(u8, line.len + 1);
            @memcpy(new_line[0..cursor_pos], line[0..cursor_pos]);
            new_line[cursor_pos] = ch;
            @memcpy(new_line[cursor_pos + 1 ..], line[cursor_pos..]);
            // arena freed on defer
            line = new_line;
            // Insert character at cursor position
            try stdout.writeAll(line[cursor_pos..]);
            cursor_pos += 1;
            // Move cursor back to position after inserted char
            for (0..line.len - cursor_pos) |_| {
                try stdout.writeAll("\x1b[D");
            }
        }
    }
}

pub fn drainQueuedLinesFromStdin(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    partial: *std.ArrayList(u8),
    out_lines: *std.ArrayList([]u8),
) void {
    if (!stdin_file.isTty()) return;

    const O_NONBLOCK = if (builtin.os.tag == .linux)
        @as(u32, 0o4000)
    else if (builtin.os.tag == .macos)
        @as(u32, 0x0004)
    else
        @as(u32, 0);

    const original_flags = std.posix.fcntl(stdin_file.handle, std.posix.F.GETFL, 0) catch return;
    _ = std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags | O_NONBLOCK) catch return;
    defer _ = std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags) catch {};

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.posix.read(stdin_file.handle, &buf) catch 0;
        if (n == 0) break;

        partial.appendSlice(allocator, buf[0..n]) catch break;
        while (std.mem.indexOfScalar(u8, partial.items, '\n')) |idx| {
            const raw = partial.items[0..idx];
            const no_cr = std.mem.trimRight(u8, raw, "\r");
            const trimmed = std.mem.trim(u8, no_cr, " \t\r\n");
            if (trimmed.len > 0) {
                const owned = allocator.dupe(u8, trimmed) catch null;
                if (owned) |line| {
                    out_lines.append(allocator, line) catch allocator.free(line);
                }
            }

            const rest = partial.items[idx + 1 ..];
            std.mem.copyForwards(u8, partial.items[0..rest.len], rest);
            partial.items = partial.items[0..rest.len];
        }
    }
}
