const std = @import("std");
const builtin = @import("builtin");
const cancel = @import("cancel.zig");
const mentions = @import("mentions.zig");
const context = @import("context.zig");
const terminal = @import("terminal.zig");

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

    // Check if stdin is a TTY
    if (!std.posix.isatty(stdin_file.handle)) {
        const line = try stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
        return sanitizeFallback(allocator, line);
    }

    // Use unified terminal manager for raw mode
    terminal.get().pushRaw();
    defer terminal.get().popRaw();

    // Enable bracketed paste
    stdout.writeAll("\x1b[?2004h") catch {};
    defer stdout.writeAll("\x1b[?2004l") catch {};

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
        // Check for exit request (double Ctrl+C)
        if (cancel.shouldExit()) {
            return null;
        }
        
        const n = stdin_file.read(&buf) catch |err| {
            // Input interrupted (Ctrl+C) or other error - return gracefully
            if (err == error.InputOutput or err == error.WouldBlock or err == error.NotOpenForReading) {
                cancel.setCancelled();
                break;
            }
            return err;
        };
        if (n == 0) break;

        const ch = buf[0];

        // Escape sequence (arrow keys, home/end, etc.)
        if (ch == 27) {
            var seq_buf: [2]u8 = undefined;
            const seq_n = stdin_file.read(&seq_buf) catch 0;
            if (seq_n == 0) continue;
            if (seq_n < 2) {
                consumeEscapeTail(stdin_file.handle);
                continue;
            }

            const prefix = seq_buf[0];
            const key = seq_buf[1];
            if (prefix != '[' and prefix != 'O') {
                consumeEscapeTail(stdin_file.handle);
                continue;
            }

            switch (key) {
                '2' => if (prefix == '[') { // Bracketed Paste [200~
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
        _ = std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags) catch 0;
    };

    var buf: [1024]u8 = undefined;
    const stdout_fd = std.posix.STDOUT_FILENO;

    while (true) {
        const n = std.posix.read(stdin_file.handle, &buf) catch 0;
        if (n == 0) break;

        var i: usize = 0;
        while (i < n) {
            const ch = buf[i];
            if (ch == 27) { // ESC
                cancel.setCancelled();
                const consumed_local = consumeEscapeTailInBuffer(buf[i + 1 .. n]);
                if (consumed_local == (n - (i + 1)) and consumed_local > 0) {
                    // Sequence may continue in unread bytes; finish from fd.
                    consumeEscapeTail(stdin_file.handle);
                }
                i += 1 + consumed_local;
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
                i += 1;
                continue;
            }

            if (ch == 127 or ch == 8) { // Backspace
                if (partial.items.len > 0) {
                    _ = partial.pop();
                    _ = std.posix.write(stdout_fd, "\x08 \x08") catch 0;
                }
                i += 1;
                continue;
            }

            if (ch == 21) { // Ctrl+U
                while (partial.items.len > 0) {
                    _ = partial.pop();
                    _ = std.posix.write(stdout_fd, "\x08 \x08") catch 0;
                }
                i += 1;
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
            i += 1;
        }
    }
}

/// Consume ESC tail bytes from a buffer slice that starts immediately after ESC.
/// Returns how many bytes were consumed from `tail`.
fn consumeEscapeTailInBuffer(tail: []const u8) usize {
    if (tail.len == 0) return 0;

    // Common prefixes: CSI '[' and SS3 'O'
    if (tail[0] == '[' or tail[0] == 'O') {
        var j: usize = 1;
        while (j < tail.len) : (j += 1) {
            const b = tail[j];
            if (b >= 0x40 and b <= 0x7E) {
                return j + 1;
            }
        }
        // No final byte in this buffer yet; consumed what we have.
        return tail.len;
    }

    // Alt-modified single-byte keys often come as ESC + <byte>.
    return 1;
}

/// After reading ESC (0x1B), best-effort consume trailing bytes of the same
/// terminal escape sequence so fragments like "[A" or "[O" do not leak into
/// the queued input and prompt echo.
fn consumeEscapeTail(stdin_fd: std.posix.fd_t) void {
    var retries: usize = 0;
    var buf: [1]u8 = undefined;
    var started = false;

    while (retries < 4) {
        const n = std.posix.read(stdin_fd, &buf) catch 0;
        if (n == 0) {
            retries += 1;
            std.Thread.sleep(2 * std.time.ns_per_ms);
            continue;
        }

        retries = 0;
        const b = buf[0];

        // CSI and SS3 prefixes are common for arrows/function/home/end keys.
        if (!started and (b == '[' or b == 'O')) {
            started = true;
            continue;
        }

        if (!started) {
            // Single-byte Alt-modified key or other short sequence.
            break;
        }

        // Final byte for CSI/SS3 is typically in 0x40..0x7E.
        if (b >= 0x40 and b <= 0x7E) break;
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
        std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags | O_NONBLOCK) catch return;
    }
    defer if (!already_nonblocking) {
        std.posix.fcntl(stdin_file.handle, std.posix.F.SETFL, original_flags) catch {};
    };

    var buf: [256]u8 = undefined;
    var saw_sequence_start = false;
    var grace_retries: usize = 0;
    const base_grace_limit: usize = 8; // ~16ms
    const sequence_grace_limit: usize = 30; // ~60ms once sequence bytes are seen
    while (true) {
        const n = std.posix.read(stdin_file.handle, &buf) catch 0;
        if (n == 0) {
            // Keep a short grace window even before seeing ESC, because
            // sequence tails can arrive a few ms later during process teardown.
            const limit = if (saw_sequence_start) sequence_grace_limit else base_grace_limit;
            if (grace_retries < limit) {
                grace_retries += 1;
                std.Thread.sleep(2 * std.time.ns_per_ms);
                continue;
            }
            break;
        }
        grace_retries = 0;
        for (buf[0..n]) |b| {
            // Also treat orphaned CSI/SS3 tails as sequence starts (e.g. "[A")
            // because ESC may have already been consumed elsewhere.
            if (b == 0x1b or b == '[' or b == 'O') saw_sequence_start = true;
        }
    }
}
