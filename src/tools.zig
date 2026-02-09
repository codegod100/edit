const std = @import("std");

pub const ToolError = error{InvalidToolCommand};
pub const NamedToolError = error{ InvalidToolName, InvalidArguments, IoError };

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const definitions = [_]ToolDef{
    .{ .name = "bash", .description = "Execute a shell command and return stdout.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"],\"additionalProperties\":false}" },
    .{ .name = "read_file", .description = "Read a file and return its contents.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}" },
    .{ .name = "list_files", .description = "List files and directories in a folder.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}" },
    .{ .name = "write_file", .description = "Write complete file contents to a path.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}" },
    .{ .name = "replace_in_file", .description = "Replace text in a file.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"find\",\"replace\"],\"additionalProperties\":false}" },
    // OpenCode-compatible aliases.
    .{ .name = "read", .description = "Read a file and return its contents.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"}},\"required\":[\"filePath\"],\"additionalProperties\":false}" },
    .{ .name = "list", .description = "List files and directories in a folder.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}" },
    .{ .name = "write", .description = "Write full content to a file path.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"filePath\",\"content\"],\"additionalProperties\":false}" },
    .{ .name = "edit", .description = "Replace oldString with newString in one file.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"},\"oldString\":{\"type\":\"string\"},\"newString\":{\"type\":\"string\"},\"replaceAll\":{\"type\":\"boolean\"}},\"required\":[\"filePath\",\"oldString\",\"newString\"],\"additionalProperties\":false}" },
    .{ .name = "apply_patch", .description = "Apply a structured patch with add/update/delete operations.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"patchText\":{\"type\":\"string\"}},\"required\":[\"patchText\"],\"additionalProperties\":false}" },
};

pub fn list() []const []const u8 {
    return &.{ "bash <command>", "read <path>", "list <path>", "write <path>", "replace <path>", "apply_patch <patch-text>" };
}

pub fn execute(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    if (trimmed.len == 0) return ToolError.InvalidToolCommand;

    if (std.mem.startsWith(u8, trimmed, "read ")) {
        const path = std.mem.trim(u8, trimmed[5..], " \t");
        if (path.len == 0) return ToolError.InvalidToolCommand;
        return readFileAtPath(allocator, path, 1024 * 1024);
    }

    if (std.mem.startsWith(u8, trimmed, "list ")) {
        const path = std.mem.trim(u8, trimmed[5..], " \t");
        if (path.len == 0) return ToolError.InvalidToolCommand;
        const cmd = try std.fmt.allocPrint(allocator, "ls -la {s}", .{path});
        defer allocator.free(cmd);
        return runBash(allocator, cmd);
    }

    if (std.mem.startsWith(u8, trimmed, "bash ")) {
        const command = std.mem.trim(u8, trimmed[5..], " \t");
        if (command.len == 0) return ToolError.InvalidToolCommand;
        return runBash(allocator, command);
    }

    return ToolError.InvalidToolCommand;
}

pub fn executeNamed(allocator: std.mem.Allocator, name: []const u8, arguments_json: []const u8) ![]u8 {
    if (std.mem.eql(u8, name, "bash")) {
        const A = struct { command: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        return runBash(allocator, p.value.command orelse return NamedToolError.InvalidArguments);
    }

    if (std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "read")) {
        const A = struct { path: ?[]const u8 = null, filePath: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse p.value.filePath orelse return NamedToolError.InvalidArguments;
        return readFileAtPath(allocator, path, 1024 * 1024);
    }

    if (std.mem.eql(u8, name, "list_files") or std.mem.eql(u8, name, "list")) {
        const A = struct { path: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse ".";
        const cmd = try std.fmt.allocPrint(allocator, "ls -la {s}", .{path});
        defer allocator.free(cmd);
        return runBash(allocator, cmd);
    }

    if (std.mem.eql(u8, name, "write_file") or std.mem.eql(u8, name, "write")) {
        const A = struct { path: ?[]const u8 = null, filePath: ?[]const u8 = null, content: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse p.value.filePath orelse return NamedToolError.InvalidArguments;
        const content = p.value.content orelse return NamedToolError.InvalidArguments;
        try writeFileAtPath(path, content);
        const diag = try zigFmtDiagnostics(allocator, path);
        defer if (diag) |d| allocator.free(d);
        return std.fmt.allocPrint(allocator, "Wrote file successfully.{s}", .{diag orelse ""});
    }

    if (std.mem.eql(u8, name, "replace_in_file") or std.mem.eql(u8, name, "edit")) {
        const A = struct {
            path: ?[]const u8 = null,
            filePath: ?[]const u8 = null,
            find: ?[]const u8 = null,
            oldString: ?[]const u8 = null,
            replace: ?[]const u8 = null,
            newString: ?[]const u8 = null,
            all: ?bool = null,
            replaceAll: ?bool = null,
        };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();

        const path = p.value.path orelse p.value.filePath orelse return NamedToolError.InvalidArguments;
        const find = p.value.find orelse p.value.oldString orelse return NamedToolError.InvalidArguments;
        const repl = p.value.replace orelse p.value.newString orelse return NamedToolError.InvalidArguments;
        const replace_all = p.value.all orelse p.value.replaceAll orelse false;

        const original = try readFileAtPath(allocator, path, 4 * 1024 * 1024);
        defer allocator.free(original);

        const next = try replaceTextStrict(allocator, original, find, repl, replace_all);
        defer allocator.free(next);

        try writeFileAtPath(path, next);
        const diag = try zigFmtDiagnostics(allocator, path);
        defer if (diag) |d| allocator.free(d);
        return std.fmt.allocPrint(allocator, "Edit applied successfully.{s}", .{diag orelse ""});
    }

    if (std.mem.eql(u8, name, "apply_patch")) {
        const A = struct { patchText: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const text = p.value.patchText orelse return NamedToolError.InvalidArguments;
        const out = try applyPatchText(allocator, text);
        const diag = try collectPatchDiagnostics(allocator, text);
        defer if (diag) |d| allocator.free(d);
        if (diag) |d| {
            defer allocator.free(out);
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ out, d });
        }
        return out;
    }

    return NamedToolError.InvalidToolName;
}

fn readFileAtPath(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const resolved = try resolveWorkspacePath(allocator, path);
    defer allocator.free(resolved);
    var file = try std.fs.openFileAbsolute(resolved, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn writeFileAtPath(path: []const u8, content: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const resolved = try resolveWorkspacePath(allocator, path);
    defer allocator.free(resolved);

    if (std.fs.path.dirname(resolved)) |dir| {
        if (dir.len > 0) {
            std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    var file = try std.fs.createFileAbsolute(resolved, .{});
    defer file.close();
    try file.writeAll(content);
}

fn deleteFileAtPath(path: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const resolved = try resolveWorkspacePath(allocator, path);
    defer allocator.free(resolved);
    return std.fs.deleteFileAbsolute(resolved);
}

fn moveFileAtPath(old_path: []const u8, new_path: []const u8) !void {
    const content = try readFileAtPath(std.heap.page_allocator, old_path, 16 * 1024 * 1024);
    defer std.heap.page_allocator.free(content);
    try writeFileAtPath(new_path, content);
    try deleteFileAtPath(old_path);
}

fn resolveWorkspacePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const abs = if (std.fs.path.isAbsolute(raw_path))
        try allocator.dupe(u8, raw_path)
    else
        try std.fs.path.resolve(allocator, &.{ cwd, raw_path });

    if (!pathWithinBase(cwd, abs)) {
        allocator.free(abs);
        return NamedToolError.InvalidArguments;
    }
    return abs;
}

fn pathWithinBase(base: []const u8, candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, base)) return false;
    if (candidate.len == base.len) return true;
    return candidate[base.len] == '/';
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    if (needle.len == 0) return 0;
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |idx| {
        count += 1;
        pos = idx + needle.len;
    }
    return count;
}

fn replaceTextStrict(allocator: std.mem.Allocator, original: []const u8, find: []const u8, repl: []const u8, replace_all: bool) ![]u8 {
    if (find.len == 0) return NamedToolError.InvalidArguments;
    const matches = countOccurrences(original, find);
    if (matches == 0) {
        const fuzzy = try replaceByTrimmedLines(allocator, original, find, repl);
        if (fuzzy) |value| return value;
        return allocator.dupe(u8, "no-op: pattern not found");
    }
    if (!replace_all and matches > 1) return NamedToolError.InvalidArguments;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, original, cursor, find)) |idx| {
        try out.appendSlice(allocator, original[cursor..idx]);
        try out.appendSlice(allocator, repl);
        cursor = idx + find.len;
        if (!replace_all) break;
    }
    try out.appendSlice(allocator, original[cursor..]);
    return out.toOwnedSlice(allocator);
}

fn replaceByTrimmedLines(allocator: std.mem.Allocator, original: []const u8, find: []const u8, repl: []const u8) !?[]u8 {
    var original_lines = std.ArrayList([]const u8).empty;
    defer original_lines.deinit(allocator);
    var find_lines = std.ArrayList([]const u8).empty;
    defer find_lines.deinit(allocator);

    var oit = std.mem.splitScalar(u8, original, '\n');
    while (oit.next()) |line| try original_lines.append(allocator, std.mem.trimRight(u8, line, "\r"));
    var fit = std.mem.splitScalar(u8, find, '\n');
    while (fit.next()) |line| try find_lines.append(allocator, std.mem.trimRight(u8, line, "\r"));
    if (find_lines.items.len == 0) return null;

    var match_start: ?usize = null;
    var i: usize = 0;
    while (i + find_lines.items.len <= original_lines.items.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < find_lines.items.len) : (j += 1) {
            const a = std.mem.trim(u8, original_lines.items[i + j], " \t");
            const b = std.mem.trim(u8, find_lines.items[j], " \t");
            if (!std.mem.eql(u8, a, b)) {
                ok = false;
                break;
            }
        }
        if (ok) {
            if (match_start != null) return NamedToolError.InvalidArguments;
            match_start = i;
        }
    }
    if (match_start == null) return null;

    const start_byte = lineStartByteOffset(original, match_start.?);
    const end_byte = lineStartByteOffset(original, match_start.? + find_lines.items.len);
    const out = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ original[0..start_byte], repl, original[end_byte..] });
    return @as(?[]u8, out);
}

fn lineStartByteOffset(text: []const u8, line_index: usize) usize {
    if (line_index == 0) return 0;
    var line: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            if (line == line_index) return i + 1;
        }
    }
    return text.len;
}

fn zigFmtDiagnostics(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (!std.mem.endsWith(u8, path, ".zig")) return null;
    const resolved = try resolveWorkspacePath(allocator, path);
    defer allocator.free(resolved);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "fmt", "--check", resolved },
        .max_output_bytes = 128 * 1024,
    });
    if (result.term == .Exited and result.term.Exited == 0) {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        return null;
    }
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const out = try std.fmt.allocPrint(allocator, "\n\nFormatter diagnostics:\n{s}{s}", .{ result.stdout, result.stderr });
    return @as(?[]u8, out);
}

fn collectPatchDiagnostics(allocator: std.mem.Allocator, patch_text: []const u8) !?[]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var it = std.mem.splitScalar(u8, patch_text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "*** Add File: ")) {
            const path = std.mem.trim(u8, line[14..], " \t");
            const diag = try zigFmtDiagnostics(allocator, path);
            if (diag) |d| {
                defer allocator.free(d);
                try out.appendSlice(allocator, d);
            }
        } else if (std.mem.startsWith(u8, line, "*** Update File: ")) {
            const path = std.mem.trim(u8, line[17..], " \t");
            const diag = try zigFmtDiagnostics(allocator, path);
            if (diag) |d| {
                defer allocator.free(d);
                try out.appendSlice(allocator, d);
            }
        } else if (std.mem.startsWith(u8, line, "*** Move to: ")) {
            const path = std.mem.trim(u8, line[13..], " \t");
            const diag = try zigFmtDiagnostics(allocator, path);
            if (diag) |d| {
                defer allocator.free(d);
                try out.appendSlice(allocator, d);
            }
        }
    }

    if (out.items.len == 0) return null;
    const value = try out.toOwnedSlice(allocator);
    return @as(?[]u8, value);
}

const HunkLine = struct {
    kind: u8,
    text: []const u8,
};

fn applyPatchText(allocator: std.mem.Allocator, patch_text: []const u8) ![]u8 {
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, patch_text, '\n');
    while (it.next()) |raw| {
        try lines.append(allocator, std.mem.trimRight(u8, raw, "\r"));
    }

    if (lines.items.len < 2) return NamedToolError.InvalidArguments;
    if (!std.mem.eql(u8, std.mem.trim(u8, lines.items[0], " \t"), "*** Begin Patch")) return NamedToolError.InvalidArguments;

    var end_idx: ?usize = null;
    for (lines.items, 0..) |line, idx| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), "*** End Patch")) {
            end_idx = idx;
            break;
        }
    }
    if (end_idx == null or end_idx.? <= 0) return NamedToolError.InvalidArguments;

    var i: usize = 1;
    var summary = std.ArrayList(u8).empty;
    defer summary.deinit(allocator);

    while (i < end_idx.?) {
        const line = lines.items[i];
        if (line.len == 0) {
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Add File: ")) {
            const path = std.mem.trim(u8, line[14..], " \t");
            i += 1;

            var content_lines = std.ArrayList([]const u8).empty;
            defer content_lines.deinit(allocator);
            while (i < end_idx.? and !std.mem.startsWith(u8, lines.items[i], "*** ")) : (i += 1) {
                const cl = lines.items[i];
                if (cl.len == 0 or cl[0] != '+') return NamedToolError.InvalidArguments;
                try content_lines.append(allocator, cl[1..]);
            }

            const content = try joinLines(allocator, content_lines.items, true);
            defer allocator.free(content);
            try writeFileAtPath(path, content);
            try summary.writer(allocator).print("A {s}\n", .{path});
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Delete File: ")) {
            const path = std.mem.trim(u8, line[17..], " \t");
            i += 1;
            try deleteFileAtPath(path);
            try summary.writer(allocator).print("D {s}\n", .{path});
            continue;
        }

        if (std.mem.startsWith(u8, line, "*** Update File: ")) {
            const path = std.mem.trim(u8, line[17..], " \t");
            i += 1;

            var move_to: ?[]const u8 = null;
            if (i < end_idx.? and std.mem.startsWith(u8, lines.items[i], "*** Move to: ")) {
                move_to = std.mem.trim(u8, lines.items[i][13..], " \t");
                i += 1;
            }

            const original = try readFileAtPath(allocator, path, 8 * 1024 * 1024);
            defer allocator.free(original);
            const original_trailing_nl = original.len > 0 and original[original.len - 1] == '\n';

            var original_lines = std.ArrayList([]const u8).empty;
            defer original_lines.deinit(allocator);
            var oit = std.mem.splitScalar(u8, original, '\n');
            while (oit.next()) |raw| {
                try original_lines.append(allocator, std.mem.trimRight(u8, raw, "\r"));
            }
            if (original_trailing_nl and original_lines.items.len > 0 and original_lines.items[original_lines.items.len - 1].len == 0) {
                _ = original_lines.pop();
            }

            var out_lines = std.ArrayList([]const u8).empty;
            defer out_lines.deinit(allocator);
            var cursor: usize = 0;

            while (i < end_idx.? and !std.mem.startsWith(u8, lines.items[i], "*** ")) {
                if (lines.items[i].len == 0) {
                    i += 1;
                    continue;
                }
                if (!std.mem.startsWith(u8, lines.items[i], "@@")) return NamedToolError.InvalidArguments;
                i += 1;

                var hunk = std.ArrayList(HunkLine).empty;
                defer hunk.deinit(allocator);
                while (i < end_idx.? and !std.mem.startsWith(u8, lines.items[i], "@@") and !std.mem.startsWith(u8, lines.items[i], "*** ")) : (i += 1) {
                    const hl = lines.items[i];
                    if (hl.len == 0) return NamedToolError.InvalidArguments;
                    const kind = hl[0];
                    if (kind != ' ' and kind != '+' and kind != '-') return NamedToolError.InvalidArguments;
                    try hunk.append(allocator, .{ .kind = kind, .text = hl[1..] });
                }
                if (hunk.items.len == 0) continue;

                var anchor: ?[]const u8 = null;
                for (hunk.items) |hl| {
                    if (hl.kind != '+') {
                        anchor = hl.text;
                        break;
                    }
                }

                if (anchor) |a| {
                    var seek = cursor;
                    var found: ?usize = null;
                    while (seek < original_lines.items.len) : (seek += 1) {
                        if (std.mem.eql(u8, original_lines.items[seek], a)) {
                            found = seek;
                            break;
                        }
                    }
                    if (found == null) return NamedToolError.InvalidArguments;
                    var j = cursor;
                    while (j < found.?) : (j += 1) {
                        try out_lines.append(allocator, original_lines.items[j]);
                    }
                    cursor = found.?;
                }

                for (hunk.items) |hl| {
                    switch (hl.kind) {
                        ' ' => {
                            if (cursor >= original_lines.items.len) return NamedToolError.InvalidArguments;
                            if (!std.mem.eql(u8, original_lines.items[cursor], hl.text)) return NamedToolError.InvalidArguments;
                            try out_lines.append(allocator, original_lines.items[cursor]);
                            cursor += 1;
                        },
                        '-' => {
                            if (cursor >= original_lines.items.len) return NamedToolError.InvalidArguments;
                            if (!std.mem.eql(u8, original_lines.items[cursor], hl.text)) return NamedToolError.InvalidArguments;
                            cursor += 1;
                        },
                        '+' => try out_lines.append(allocator, hl.text),
                        else => return NamedToolError.InvalidArguments,
                    }
                }
            }

            while (cursor < original_lines.items.len) : (cursor += 1) {
                try out_lines.append(allocator, original_lines.items[cursor]);
            }

            const new_content = try joinLines(allocator, out_lines.items, original_trailing_nl);
            defer allocator.free(new_content);

            const target = move_to orelse path;
            try writeFileAtPath(target, new_content);
            if (move_to != null and !std.mem.eql(u8, target, path)) {
                try deleteFileAtPath(path);
                try summary.writer(allocator).print("M {s} -> {s}\n", .{ path, target });
            } else {
                try summary.writer(allocator).print("M {s}\n", .{path});
            }
            continue;
        }

        return NamedToolError.InvalidArguments;
    }

    if (summary.items.len == 0) return allocator.dupe(u8, "patch rejected: empty patch");
    return std.fmt.allocPrint(allocator, "Success. Updated the following files:\n{s}", .{summary.items});
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8, trailing_newline: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    for (lines, 0..) |line, idx| {
        try out.appendSlice(allocator, line);
        if (idx + 1 < lines.len) try out.append(allocator, '\n');
    }
    if (trailing_newline and (lines.len > 0 or out.items.len > 0)) {
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn runBash(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", command },
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stderr);
    return result.stdout;
}

test "edit fails on ambiguous single replace" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const file_path = try std.fs.path.join(allocator, &.{ path, "ambiguous.txt" });
    defer allocator.free(file_path);

    var file = try std.fs.createFileAbsolute(file_path, .{});
    try file.writeAll("const x = 1;\nconst x = 1;\n");
    file.close();

    const args = try std.fmt.allocPrint(
        allocator,
        "{{\"filePath\":\"{s}\",\"oldString\":\"const \",\"newString\":\"const \",\"replaceAll\":false}}",
        .{file_path},
    );
    defer allocator.free(args);

    const out = executeNamed(allocator, "edit", args);
    try std.testing.expectError(NamedToolError.InvalidArguments, out);
}

test "apply_patch rejects empty patch" {
    const allocator = std.testing.allocator;
    const output = try executeNamed(allocator, "apply_patch", "{\"patchText\":\"*** Begin Patch\\n*** End Patch\"}");
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "empty patch") != null);
}

test "path guard rejects parent traversal" {
    const allocator = std.testing.allocator;
    const out = executeNamed(allocator, "read_file", "{\"path\":\"../outside.txt\"}");
    try std.testing.expectError(NamedToolError.InvalidArguments, out);
}

test "edit supports trimmed line fallback replacement" {
    const allocator = std.testing.allocator;
    const original =
        "fn main() {\n" ++
        "    const x = 1;\n" ++
        "}\n";
    const find =
        "const x = 1;\n";
    const repl =
        "    const x = 2;\n";

    const replaced = try replaceTextStrict(allocator, original, find, repl, false);
    defer allocator.free(replaced);
    try std.testing.expect(std.mem.indexOf(u8, replaced, "const x = 2;") != null);
}
