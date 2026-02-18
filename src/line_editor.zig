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
    partial_input: ?[]const u8,
) !?[]u8 {
    const sanitizeFallback = struct {
        fn run(alloc: std.mem.Allocator, raw: ?[]u8) !?[]u8 {
            if (raw == null) return null;
            const line = raw.?;
            defer alloc.free(line);

            var t = std.mem.trim(u8, line, " \t\r\n");
            if (t.len == 0) return try alloc.dupe(u8, "");

            // Remove accidental ANSI escape sequences and orphaned CSI tails
            // (e.g. "[A" from Up arrow) that can leak during Ctrl+C transitions.
            while (true) {
                if (t.len >= 2 and t[0] == 0x1b and t[1] == '[') {
                    var i: usize = 2;
                    while (i < t.len) : (i += 1) {
                        const c = t[i];
                        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) {
                            i += 1;
                            break;
                        }
                    }
                    if (i > 2 and i <= t.len) {
                        t = std.mem.trimLeft(u8, t[i..], " \t");
                        continue;
                    }
                }

                if (t.len >= 2 and t[0] == '[' and ((t[1] >= 'A' and t[1] <= 'Z') or (t[1] >= 'a' and t[1] <= 'z'))) {
                    t = std.mem.trimLeft(u8, t[2..], " \t");
                    continue;
                }
                break;
            }

            return try alloc.dupe(u8, t);
        }
    }.run;

    const original = std.posix.tcgetattr(stdin_file.handle) catch {
        const line = try stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
        return sanitizeFallback(allocator, line);
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
        if (err != error.ProcessOrphaned) {
            std.log.debug("Failed to set raw mode: {any}", .{err});
        }
        const line = stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024) catch null;
        return sanitizeFallback(allocator, line);
    };
    defer std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};

    // Enable bracketed paste
    _ = stdout.writeAll("\x1b[?2004h") catch {};
    defer _ = stdout.writeAll("\x1b[?2004l") catch {};

    // Use arena for line editing to simplify memory management
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var line: []u8 = &.{};
    var cursor_pos: usize = 0;

    if (partial_input) |pi| {
        line = try arena_alloc.dupe(u8, pi);
        cursor_pos = line.len;
    }

    var buf: [1]u8 = undefined;
    
    // History navigation state
    var history_index: ?usize = null;
    var saved_line: []u8 = &.{};

    // Display initial prompt and any partial input
    try stdout.writeAll(prompt);
    if (line.len > 0) try stdout.writeAll(line);

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
                    '2' => { // Bracketed Paste [200~
                        var p_buf: [8]u8 = undefined;
                        var p_len: usize = 0;
                        while (p_len < 8) {
                            const rn = stdin_file.read(p_buf[p_len..p_len+1]) catch 0;
                            if (rn == 0) break;
                            p_len += 1;
                            if (p_buf[p_len-1] == '~') break;
                        }
                        if (p_len >= 3 and std.mem.eql(u8, p_buf[0..3], "00~")) {
                            while (true) {
                                var pch_buf: [1]u8 = undefined;
                                const pn = stdin_file.read(&pch_buf) catch 0;
                                if (pn == 0) break;
                                const pch = pch_buf[0];
                                if (pch == 27) {
                                    var esc_seq: [5]u8 = undefined;
                                    const en = stdin_file.read(&esc_seq) catch 0;
                                    if (en == 5 and std.mem.eql(u8, &esc_seq, "[201~")) break;
                                }
                                const next_line = try arena_alloc.alloc(u8, line.len + 1);
                                @memcpy(next_line[0..cursor_pos], line[0..cursor_pos]);
                                next_line[cursor_pos] = pch;
                                @memcpy(next_line[cursor_pos + 1 ..], line[cursor_pos..]);
                                line = next_line;
                                try stdout.writeAll(line[cursor_pos..cursor_pos+1]);
                                cursor_pos += 1;
                            }
                            continue;
                        }
                    },
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
                            const entry_raw = history.items.items[history_index.?];
                            const entry = context.normalizeHistoryLine(entry_raw);
                            try stdout.writeAll("\r\x1b[K");
                            try stdout.writeAll(prompt);
                            line = try arena_alloc.dupe(u8, entry);
                            cursor_pos = line.len;
                            try stdout.writeAll(line);
                        }
                    },
                    'B' => { // Down - History
                        if (history_index == null) continue;
                        if (history_index.? < history.items.items.len - 1) {
                            history_index.? += 1;
                            const entry_raw = history.items.items[history_index.?];
                            const entry = context.normalizeHistoryLine(entry_raw);
                            try stdout.writeAll("\r\x1b[K");
                            try stdout.writeAll(prompt);
                            line = try arena_alloc.dupe(u8, entry);
                            cursor_pos = line.len;
                            try stdout.writeAll(line);
                        } else {
                            history_index = null;
                            try stdout.writeAll("\r\x1b[K");
                            try stdout.writeAll(prompt);
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
            // Return to start of line and clear the prompt input completely.
            // Multiline pastes may have echoed multiple physical lines due '\n'.
            try stdout.writeAll("\r\x1b[K");
            var nl_count: usize = 0;
            for (line) |c| {
                if (c == '\n') nl_count += 1;
            }
            var i: usize = 0;
            while (i < nl_count) : (i += 1) {
                try stdout.writeAll("\x1b[1A\r\x1b[K");
            }
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
            try stdout.writeAll(prompt);
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
    partial: *std.ArrayListUnmanaged(u8),
    out_lines: *std.ArrayListUnmanaged([]u8),
) void {
    if (!stdin_file.isTty()) return;

    const O_NONBLOCK = if (builtin.os.tag == .linux)
        @as(u32, 0o4000)
    else if (builtin.os.tag == .macos)
        @as(u32, 0x0004)
    else
        @as(u32, 0);

    const original_flags = std.posix.fcntl(stdin_file.handle, std.posix.F.GETFL, 0) catch return;
    const already_nonblocking = (original_flags & O_NONBLOCK) != 0;
    
    if (!already_nonblocking) {
        _ = std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags | O_NONBLOCK) catch return;
    }
    defer if (!already_nonblocking) {
        _ = std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags) catch {};
    };

    var buf: [1024]u8 = undefined;
    const stdout_fd = std.posix.STDOUT_FILENO;

    while (true) {
        const n = std.posix.read(stdin_file.handle, &buf) catch 0;
        if (n == 0) break;

        for (buf[0..n]) |ch| {
            if (ch == 27) { // ESC
                cancel.setCancelled();
                continue;
            }

            if (ch == 13 or ch == 10) { // Enter
                if (partial.items.len > 0) {
                    const line = allocator.dupe(u8, partial.items) catch continue;
                    out_lines.append(allocator, line) catch {
                        allocator.free(line);
                        continue;
                    };
                    partial.clearRetainingCapacity();
                    _ = std.posix.write(stdout_fd, "\n") catch 0;
                }
                continue;
            }

            if (ch == 127 or ch == 8) { // Backspace
                if (partial.items.len > 0) {
                    _ = partial.pop();
                    _ = std.posix.write(stdout_fd, "\x08 \x08") catch 0;
                }
                continue;
            }

            if (ch == 21) { // Ctrl+U
                while (partial.items.len > 0) {
                    _ = partial.pop();
                    _ = std.posix.write(stdout_fd, "\x08 \x08") catch 0;
                }
                continue;
            }

            if (ch >= 32 and ch < 127) { // Printable ASCII
                if (partial.items.len == 0) {
                    _ = std.posix.write(stdout_fd, "> ") catch 0;
                }
                partial.append(allocator, ch) catch continue;
                var echo_buf = [1]u8{ch};
                _ = std.posix.write(stdout_fd, &echo_buf) catch 0;
            }
        }
    }
}

pub fn discardPendingInput(stdin_file: std.fs.File) void {
    if (!stdin_file.isTty()) return;

    const O_NONBLOCK = if (builtin.os.tag == .linux)
        @as(u32, 0o4000)
    else if (builtin.os.tag == .macos)
        @as(u32, 0x0004)
    else
        @as(u32, 0);

    const original_flags = std.posix.fcntl(stdin_file.handle, std.posix.F.GETFL, 0) catch return;
    const already_nonblocking = (original_flags & O_NONBLOCK) != 0;

    if (!already_nonblocking) {
        _ = std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags | O_NONBLOCK) catch return;
    }
    defer if (!already_nonblocking) {
        _ = std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags) catch {};
    };

    var buf: [256]u8 = undefined;
    var saw_esc = false;
    var esc_grace_retries: usize = 0;
    while (true) {
        const n = std.posix.read(stdin_file.handle, &buf) catch 0;
        if (n == 0) {
            // If we just saw ESC, wait briefly for the rest of the sequence
            // so we don't leak trailing bytes like "[A" to the parent shell.
            if (saw_esc and esc_grace_retries < 4) {
                esc_grace_retries += 1;
                std.Thread.sleep(2 * std.time.ns_per_ms);
                continue;
            }
            break;
        }
        esc_grace_retries = 0;
        for (buf[0..n]) |b| {
            if (b == 0x1b) {
                saw_esc = true;
                break;
            }
        }
    }
}
