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

pub fn readPromptLine(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdin_reader: anytype,
    stdout: anytype,
    prompt: []const u8,
    history: *context.CommandHistory,
) !?[]u8 {
    _ = prompt;

    const original = std.posix.tcgetattr(stdin_file.handle) catch {
        const line = try stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024) orelse return null;
        return line;
    };

    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = true; // Keep ISIG for Ctrl+C
    if (builtin.os.tag == .linux) {
        raw.cc[6] = 1;
        raw.cc[5] = 0;
    } else if (builtin.os.tag == .macos) {
        raw.cc[16] = 1;
        raw.cc[17] = 0;
    }
    std.posix.tcsetattr(stdin_file.handle, .NOW, raw) catch |err| {
        std.log.debug("Failed to set raw mode: {any}", .{err});
        return stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024) catch null;
    };
    defer std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};

    // Use arena for line editing to simplify memory management
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var line: []u8 = &.{};
    var cursor_pos: usize = 0;
    var buf: [1]u8 = undefined;
    
    // History navigation state
    var history_index: ?usize = null;
    var saved_line: []u8 = &.{};

    while (true) {
        const n = try stdin_file.read(&buf);
        if (n == 0) break;

        const ch = buf[0];

        // Escape sequence (arrow keys, etc.)
        if (ch == 27) {
            var seq_buf: [2]u8 = undefined;
            const seq_n = stdin_file.read(&seq_buf) catch 0;
            if (seq_n >= 2 and seq_buf[0] == '[') {
                switch (seq_buf[1]) {
                    'D' => { // Left
                        if (cursor_pos > 0) {
                            cursor_pos -= 1;
                            try stdout.writeAll("\x1b[D");
                        }
                    },
                    'C' => { // Right
                        if (cursor_pos < line.len) {
                            cursor_pos += 1;
                            try stdout.writeAll("\x1b[C");
                        }
                    },
                    'A' => { // Up - History
                        if (history.items.items.len == 0) continue;
                        if (history_index == null) {
                            saved_line = try arena_alloc.dupe(u8, line);
                            history_index = history.items.items.len;
                        }
                        if (history_index.? > 0) {
                            history_index.? -= 1;
                            const entry = history.items.items[history_index.?];
                            while (cursor_pos > 0) { try stdout.writeAll("\x08 \x08"); cursor_pos -= 1; }
                            for (0..line.len) |_| try stdout.writeAll("\x08 \x08");
                            line = try arena_alloc.dupe(u8, entry);
                            cursor_pos = line.len;
                            try stdout.writeAll(line);
                        }
                    },
                    'B' => { // Down - History
                        if (history_index == null) continue;
                        if (history_index.? < history.items.items.len - 1) {
                            history_index.? += 1;
                            const entry = history.items.items[history_index.?];
                            while (cursor_pos > 0) { try stdout.writeAll("\x08 \x08"); cursor_pos -= 1; }
                            for (0..line.len) |_| try stdout.writeAll("\x08 \x08");
                            line = try arena_alloc.dupe(u8, entry);
                            cursor_pos = line.len;
                            try stdout.writeAll(line);
                        } else {
                            history_index = null;
                            while (cursor_pos > 0) { try stdout.writeAll("\x08 \x08"); cursor_pos -= 1; }
                            for (0..line.len) |_| try stdout.writeAll("\x08 \x08");
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
                    else => {},
                }
            } else {
                cancel.setCancelled();
                try stdout.print("\n^C (cancelled)\n", .{});
                return try allocator.dupe(u8, "");
            }
            continue;
        }

        if (ch == 3) return null; // Ctrl+C

        if (ch == 13 or ch == 10) { // Enter
            // Return to start of line and clear the prompt line completely
            try stdout.writeAll("\r\x1b[K");
            return try allocator.dupe(u8, line);
        }

        if (ch == 127 or ch == 8) { // Backspace
            if (cursor_pos > 0) {
                const next_line = try arena_alloc.alloc(u8, line.len - 1);
                @memcpy(next_line[0 .. cursor_pos - 1], line[0 .. cursor_pos - 1]);
                @memcpy(next_line[cursor_pos - 1 ..], line[cursor_pos..]);
                line = next_line;
                cursor_pos -= 1;
                try stdout.writeAll("\x08 \x08");
                if (cursor_pos < line.len) {
                    try stdout.writeAll(line[cursor_pos..]);
                    try stdout.writeAll(" ");
                    for (0..line.len - cursor_pos + 1) |_| try stdout.writeAll("\x1b[D");
                }
            }
            continue;
        }

        if (ch == 21) { // Ctrl+U - kill whole line
            while (cursor_pos > 0) { try stdout.writeAll("\x08 \x08"); cursor_pos -= 1; }
            for (0..line.len) |_| try stdout.writeAll("\x08 \x08");
            line = try arena_alloc.dupe(u8, &.{});
            cursor_pos = 0;
            continue;
        }

        if (ch == 11) { // Ctrl+K - kill to end
            if (cursor_pos < line.len) {
                const remaining = line.len - cursor_pos;
                for (0..remaining) |_| try stdout.writeAll(" ");
                for (0..remaining) |_| try stdout.writeAll("\x1b[D");
                line = try arena_alloc.dupe(u8, line[0..cursor_pos]);
            }
            continue;
        }

        if (ch >= 32 and ch < 127) { // Char
            const next_line = try arena_alloc.alloc(u8, line.len + 1);
            @memcpy(next_line[0..cursor_pos], line[0..cursor_pos]);
            next_line[cursor_pos] = ch;
            @memcpy(next_line[cursor_pos + 1 ..], line[cursor_pos..]);
            line = next_line;
            try stdout.writeAll(line[cursor_pos..]);
            cursor_pos += 1;
            for (0..line.len - cursor_pos) |_| try stdout.writeAll("\x1b[D");
        }
    }
    return try allocator.dupe(u8, line);
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
