const std = @import("std");
const todo = @import("todo.zig");
const display = @import("display.zig");

const cancel = @import("cancel.zig");

/// Parse the bash command from tool arguments JSON
pub fn parseBashCommandFromArgs(allocator: std.mem.Allocator, arguments_json: []const u8) ?[]u8 {
    const A = struct { command: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const cmd = parsed.value.command orelse return null;
    return allocator.dupe(u8, cmd) catch null;
}

/// Parse the primary path (path or filePath) from tool arguments JSON
pub fn parsePrimaryPathFromArgs(allocator: std.mem.Allocator, arguments_json: []const u8) ?[]u8 {
    const A = struct { path: ?[]const u8 = null, filePath: ?[]const u8 = null };
    var parsed = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const p = parsed.value.path orelse parsed.value.filePath orelse return null;
    return allocator.dupe(u8, p) catch null;
}

pub const ReadParams = struct {
    offset: ?usize = null,
    limit: ?usize = null,
};

/// Check if a tool name is a mutating (file-modifying) tool
pub fn isMutatingToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "write_file") or
        std.mem.eql(u8, name, "replace_in_file") or
        std.mem.eql(u8, name, "edit") or
        std.mem.eql(u8, name, "write") or
        std.mem.eql(u8, name, "apply_patch");
}

/// Parse read file parameters from tool arguments JSON
pub fn parseReadParamsFromArgs(allocator: std.mem.Allocator, arguments_json: []const u8) !?ReadParams {
    const A = struct { offset: ?usize = null, limit: ?usize = null };
    var parsed = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const value = parsed.value;
    if (value.offset == null and value.limit == null) return null;

    return ReadParams{
        .offset = value.offset,
        .limit = value.limit,
    };
}

/// Parse respond_text text from tool arguments JSON (returns pointer to parsed data, not allocated)
/// Note: returned pointer is valid only as long as arguments_json is valid
pub fn parseRespondTextFromArgs(arguments_json: []const u8) ?[]const u8 {
    // Simple JSON parsing without allocation - look for text/message/summary/content fields
    const fields = [_][]const u8{ "\"text\"", "\"message\"", "\"summary\"", "\"content\"" };
    for (fields) |field| {
        if (std.mem.indexOf(u8, arguments_json, field)) |start| {
            // Find the value after the field name
            var val_start = start + field.len;
            // Skip whitespace and colon
            while (val_start < arguments_json.len) {
                const c = arguments_json[val_start];
                if (c == ' ' or c == ':' or c == '\t' or c == '\n' or c == '\r') {
                    val_start += 1;
                } else {
                    break;
                }
            }
            // Check for string value
            if (val_start < arguments_json.len and (arguments_json[val_start] == '"' or arguments_json[val_start] == '\'')) {
                const quote = arguments_json[val_start];
                const str_start = val_start + 1;
                // Find closing quote (handle escaped quotes)
                var end = str_start;
                while (end < arguments_json.len and arguments_json[end] != quote) {
                    if (arguments_json[end] == '\\' and end + 1 < arguments_json.len) {
                        end += 2; // Skip escaped character
                    } else {
                        end += 1;
                    }
                }
                if (end > str_start) {
                    return arguments_json[str_start..end];
                }
            }
        }
    }
    return null;
}

pub const ToolError = error{InvalidToolCommand};
pub const NamedToolError = error{ InvalidToolName, InvalidArguments, IoError, Cancelled };

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

const DEFAULT_READ_OFFSET: usize = 0;
// Default to the maximum bounded chunk so the model doesn't accidentally
// "read-spam" via tiny default chunks when it omits/zeros the limit.
const DEFAULT_READ_LIMIT: usize = 16384;
const MAX_READ_LIMIT: usize = 16384;
const MAX_EDIT_LINES_WITHOUT_CONFIRM: usize = 100;

pub const definitions = [_]ToolDef{
    .{ .name = "bash", .description = "Execute a shell command and return stdout.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"],\"additionalProperties\":false}" },
    // Keep schema minimal/strict for providers that validate JSON Schema tightly.
    .{ .name = "respond_text", .description = "Return a final plain-text response to the user when no further tools are needed.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"],\"additionalProperties\":false}" },
    .{ .name = "read_file", .description = "Read a file and return its contents. Always provide offset and limit for bounded reads.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\",\"description\":\"Number of bytes to skip from the start (always include; use 0 first)\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum bytes to read (always include; use <=16384)\"}},\"required\":[\"path\",\"offset\",\"limit\"],\"additionalProperties\":false}" },
    .{ .name = "list_files", .description = "List files and directories in a folder.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}" },
    .{ .name = "write_file", .description = "Write complete file contents to a path.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"],\"additionalProperties\":false}" },
    .{ .name = "replace_in_file", .description = "Replace text in a file. Large edits (>100 lines) require confirm=true.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"},\"all\":{\"type\":\"boolean\"},\"confirm\":{\"type\":\"boolean\"}},\"required\":[\"path\",\"find\",\"replace\"],\"additionalProperties\":false}" },
    // OpenCode-compatible aliases.
    .{ .name = "read", .description = "Read a file and return its contents. Always provide offset and limit for bounded reads.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\",\"description\":\"Number of bytes to skip from the start (always include; use 0 first)\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum bytes to read (always include; use <=16384)\"}},\"required\":[\"filePath\",\"offset\",\"limit\"],\"additionalProperties\":false}" },
    .{ .name = "list", .description = "List files and directories in a folder.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"],\"additionalProperties\":false}" },
    .{ .name = "write", .description = "Write full content to a file path.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"filePath\",\"content\"],\"additionalProperties\":false}" },
    .{ .name = "edit", .description = "Replace oldString with newString in one file. Large edits (>100 lines) require confirm=true.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"filePath\":{\"type\":\"string\"},\"oldString\":{\"type\":\"string\"},\"newString\":{\"type\":\"string\"},\"replaceAll\":{\"type\":\"boolean\"},\"confirm\":{\"type\":\"boolean\"}},\"required\":[\"filePath\",\"oldString\",\"newString\"],\"additionalProperties\":false}" },
    .{ .name = "apply_patch", .description = "Apply a structured patch with add/update/delete operations.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"patchText\":{\"type\":\"string\"}},\"required\":[\"patchText\"],\"additionalProperties\":false}" },
    // Todo tools for tracking progress
    .{ .name = "todo_add", .description = "Add a new task to the todo list to track progress.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"description\":{\"type\":\"string\",\"description\":\"Task description\"}},\"required\":[\"description\"],\"additionalProperties\":false}" },
    .{ .name = "todo_update", .description = "Update the status of a todo item (pending/in_progress/done).", .parameters_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"Todo item ID\"},\"status\":{\"type\":\"string\",\"description\":\"New status: pending, in_progress, or done\"}},\"required\":[\"id\",\"status\"],\"additionalProperties\":false}" },
    .{ .name = "todo_list", .description = "List all todo items with their current status.", .parameters_json = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" },
    .{ .name = "todo_remove", .description = "Remove a todo item by ID.", .parameters_json = "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"Todo item ID to remove\"}},\"required\":[\"id\"],\"additionalProperties\":false}" },
    .{ .name = "todo_clear_done", .description = "Clear all completed todo items.", .parameters_json = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}" },
    .{
        .name = "set_status",
        .description = "Updates the spinner with a high-level summary of what you are currently doing (e.g., 'Debugging build failure', 'Refactoring types'). Use this to keep the user informed of your intent.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"status\":{\"type\":\"string\",\"description\":\"A concise, human-readable summary of the current activity\"}},\"required\":[\"status\"],\"additionalProperties\":false}",
    },
    .{
        .name = "get_file_outline",
        .description = "Retrieves a structural outline of a source file (functions, structs, etc.) to understand its architecture without reading the full implementation.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"The path to the file to outline\"}},\"required\":[\"path\"],\"additionalProperties\":false}",
    },
    .{
        .name = "web_fetch",
        .description = "Fetch the text content of a URL.",
        .parameters_json = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"],\"additionalProperties\":false}",
    },
};

pub fn list() []const []const u8 {
    // Return the actual tool names from `definitions` so callers (e.g. REPL help)
    // don't drift from the registered tools.
    comptime {
        // Keep this function comptime-friendly.
        _ = definitions;
    }

    // Build a comptime list of tool names.
    // Note: returning `[]const []const u8` is fine since `definitions` is static.
    var names: [definitions.len][]const u8 = undefined;
    for (definitions, 0..) |d, i| names[i] = d.name;
    return names[0..];
}

pub fn isKnownToolName(name: []const u8) bool {
    for (definitions) |def| {
        if (std.mem.eql(u8, def.name, name)) return true;
    }
    return false;
}

pub fn isReadToolName(name: []const u8) bool {
    return std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "read");
}

pub fn execute(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, spec, " \t\r\n");
    if (trimmed.len == 0) return ToolError.InvalidToolCommand;

    if (std.mem.startsWith(u8, trimmed, "web_fetch ")) {
        const url = std.mem.trim(u8, trimmed[10..], " \t");
        if (url.len == 0) return ToolError.InvalidToolCommand;

        return fetchAndStripUrl(allocator, url);
    }

    if (std.mem.startsWith(u8, trimmed, "read ")) {
        const path = std.mem.trim(u8, trimmed[5..], " \t");
        if (path.len == 0) return ToolError.InvalidToolCommand;
        return readFileAtPathWithOffset(allocator, path, DEFAULT_READ_OFFSET, DEFAULT_READ_LIMIT);
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

pub fn executeNamed(allocator: std.mem.Allocator, name: []const u8, arguments_json: []const u8, todo_list: *todo.TodoList) ![]u8 {
    if (cancel.isCancelled()) return NamedToolError.Cancelled;
    if (std.mem.eql(u8, name, "bash")) {
        const A = struct { command: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        return runBash(allocator, p.value.command orelse return NamedToolError.InvalidArguments);
    }

    if (std.mem.eql(u8, name, "web_fetch")) {
        const A = struct { url: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const url = p.value.url orelse return NamedToolError.InvalidArguments;

        return fetchAndStripUrl(allocator, url);
    }

    if (std.mem.eql(u8, name, "respond_text")) {
        const A = struct {
            text: ?[]const u8 = null,
            message: ?[]const u8 = null,
            summary: ?[]const u8 = null,
            content: ?[]const u8 = null,
        };
        if (std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true })) |p| {
            defer p.deinit();
            const msg = p.value.text orelse p.value.message orelse p.value.summary orelse p.value.content orelse "";
            return allocator.dupe(u8, msg);
        } else |_| {
            // Fallback for non-strict payloads: best-effort extraction.
            const msg = parseRespondTextFromArgs(arguments_json) orelse "";
            return allocator.dupe(u8, msg);
        }
    }

    if (std.mem.eql(u8, name, "read_file") or std.mem.eql(u8, name, "read")) {
        const A = struct { path: ?[]const u8 = null, filePath: ?[]const u8 = null, file_path: ?[]const u8 = null, file_name: ?[]const u8 = null, offset: ?usize = null, limit: ?usize = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse p.value.filePath orelse p.value.file_path orelse p.value.file_name orelse return NamedToolError.InvalidArguments;
        const offset = p.value.offset orelse DEFAULT_READ_OFFSET;
        const limit_raw = p.value.limit orelse DEFAULT_READ_LIMIT;
        const normalized_limit = if (limit_raw == 0) DEFAULT_READ_LIMIT else limit_raw;
        const limit = @min(normalized_limit, MAX_READ_LIMIT);
        return readFileAtPathWithOffset(allocator, path, offset, limit) catch |err| {
            // Return snarky error to guide model back on track
            if (err == NamedToolError.InvalidArguments) {
                return std.fmt.allocPrint(allocator, "WTF? '{s}' is outside the workspace! Stay in the current project directory.", .{path});
            }
            return std.fmt.allocPrint(allocator, "Bruh, file '{s}' doesn't exist. Did you forget src/ prefix? Error: {s}", .{ path, @errorName(err) });
        };
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
        const A = struct {
            path: ?[]const u8 = null,
            filePath: ?[]const u8 = null,
            file_path: ?[]const u8 = null,
            content: ?[]const u8 = null,
        };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse p.value.filePath orelse p.value.file_path orelse return NamedToolError.InvalidArguments;
        const content = p.value.content orelse return NamedToolError.InvalidArguments;

        const before = readFileAtPath(allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (before) |b| allocator.free(b);

        try writeFileAtPath(path, content);
        const diff = try renderMiniDiff(allocator, path, before orelse "", content);
        defer allocator.free(diff);
        const diag = try zigFmtDiagnostics(allocator, path);
        defer if (diag) |d| allocator.free(d);
        return std.fmt.allocPrint(allocator, "Wrote file: {s}\n{s}{s}", .{ path, diff, diag orelse "" });
    }

    if (std.mem.eql(u8, name, "replace_in_file") or std.mem.eql(u8, name, "edit")) {
        const A = struct {
            path: ?[]const u8 = null,
            filePath: ?[]const u8 = null,
            file_path: ?[]const u8 = null,
            find: ?[]const u8 = null,
            oldString: ?[]const u8 = null,
            old_string: ?[]const u8 = null,
            old: ?[]const u8 = null,
            replace: ?[]const u8 = null,
            newString: ?[]const u8 = null,
            new_string: ?[]const u8 = null,
            new: ?[]const u8 = null,
            all: ?bool = null,
            replaceAll: ?bool = null,
            confirm: ?bool = null,
        };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();

        const path = p.value.path orelse p.value.filePath orelse p.value.file_path orelse return NamedToolError.InvalidArguments;
        const find = p.value.find orelse p.value.oldString orelse p.value.old_string orelse p.value.old orelse return NamedToolError.InvalidArguments;
        const repl = p.value.replace orelse p.value.newString orelse p.value.new_string orelse p.value.new orelse return NamedToolError.InvalidArguments;
        const replace_all = p.value.all orelse p.value.replaceAll orelse false;
        const confirmed = p.value.confirm orelse false;

        const original = try readFileAtPath(allocator, path, 4 * 1024 * 1024);
        defer allocator.free(original);

        const next = replaceTextStrict(allocator, original, find, repl, replace_all) catch |err| switch (err) {
            NamedToolError.InvalidArguments => {
                const matches = countOccurrences(original, find);
                if (matches == 0) {
                    return std.fmt.allocPrint(
                        allocator,
                        "Replace failed: pattern not found in {s}. Use exact text for 'find' (including punctuation/indentation), or include more surrounding context.",
                        .{path},
                    );
                }
                if (!replace_all and matches > 1) {
                    return std.fmt.allocPrint(
                        allocator,
                        "Replace failed: pattern matched {d} locations in {s}. Provide a more specific 'find' string or set all=true/replaceAll=true.",
                        .{ matches, path },
                    );
                }
                return std.fmt.allocPrint(allocator, "Replace failed in {s}: invalid replace arguments.", .{path});
            },
            else => return err,
        };
        defer allocator.free(next);

        const edited_lines = countEditedLines(original, next);
        if (edited_lines > MAX_EDIT_LINES_WITHOUT_CONFIRM and !confirmed) {
            return std.fmt.allocPrint(
                allocator,
                "CONFIRM_REQUIRED: edit would modify {d} lines in {s} (limit {d}). Re-run the same edit with {{\"confirm\":true}} to proceed.",
                .{ edited_lines, path, MAX_EDIT_LINES_WITHOUT_CONFIRM },
            );
        }

        try writeFileAtPath(path, next);
        const diff = try renderMiniDiff(allocator, path, original, next);
        defer allocator.free(diff);
        const diag = try zigFmtDiagnostics(allocator, path);
        defer if (diag) |d| allocator.free(d);
        return std.fmt.allocPrint(allocator, "Edited file: {s}\n{s}{s}", .{ path, diff, diag orelse "" });
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

    // Todo tools
    if (std.mem.eql(u8, name, "todo_add")) {
        const A = struct { description: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const desc = p.value.description orelse return NamedToolError.InvalidArguments;

        const id = try todo_list.add(desc);

        // Show the list automatically
        const list_out = try todo_list.list(allocator);
        defer allocator.free(list_out);
        try display.printTruncatedCommandOutput(null, list_out);

        return std.fmt.allocPrint(allocator, "Added todo {s}: {s}", .{ id, desc });
    }

    if (std.mem.eql(u8, name, "todo_list")) {
        return todo_list.list(allocator);
    }

    if (std.mem.eql(u8, name, "todo_update")) {
        const A = struct { id: ?[]const u8 = null, status: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const id = p.value.id orelse return NamedToolError.InvalidArguments;
        const status_str = p.value.status orelse return NamedToolError.InvalidArguments;

        const status = std.meta.stringToEnum(todo.TodoStatus, status_str) orelse return NamedToolError.InvalidArguments;

        const success = try todo_list.update(id, status);
        if (success) {
            // If setting to in_progress, update spinner status automatically
            if (status == .in_progress) {
                for (todo_list.items.items) |item| {
                    if (std.mem.eql(u8, item.id, id)) {
                        display.setSpinnerStateWithText(.thinking, item.description);
                        break;
                    }
                }
            }

            // Show the list automatically
            const list_out = try todo_list.list(allocator);
            defer allocator.free(list_out);
            try display.printTruncatedCommandOutput(null, list_out);

            return std.fmt.allocPrint(allocator, "Updated todo {s} to {s}", .{ id, status_str });
        } else {
            return std.fmt.allocPrint(allocator, "Todo {s} not found", .{id});
        }
    }

    if (std.mem.eql(u8, name, "todo_remove")) {
        const A = struct { id: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const id = p.value.id orelse return NamedToolError.InvalidArguments;

        const success = try todo_list.remove(id);
        if (success) {
            return std.fmt.allocPrint(allocator, "Removed todo {s}", .{id});
        } else {
            return std.fmt.allocPrint(allocator, "Todo {s} not found", .{id});
        }
    }

    if (std.mem.eql(u8, name, "todo_clear_done")) {
        todo_list.clearDone();
        return std.fmt.allocPrint(allocator, "Cleared all completed todos", .{});
    }

    if (std.mem.eql(u8, name, "set_status")) {
        const A = struct { status: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const status = p.value.status orelse return NamedToolError.InvalidArguments;
        display.setSpinnerStateWithText(.thinking, status);
        return std.fmt.allocPrint(allocator, "Status updated to: {s}", .{status});
    }

    if (std.mem.eql(u8, name, "get_file_outline")) {
        const A = struct { path: ?[]const u8 = null };
        var p = std.json.parseFromSlice(A, allocator, arguments_json, .{ .ignore_unknown_fields = true }) catch return NamedToolError.InvalidArguments;
        defer p.deinit();
        const path = p.value.path orelse return NamedToolError.InvalidArguments;
        return getFileOutline(allocator, path);
    }

    // Subagent tools removed
    if (std.mem.startsWith(u8, name, "subagent_")) {
        return allocator.dupe(u8, "{\"error\":\"Subagent support has been removed\"}");
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

fn readFileAtPathWithOffset(allocator: std.mem.Allocator, path: []const u8, offset: usize, limit: usize) ![]u8 {
    const resolved = try resolveWorkspacePath(allocator, path);
    defer allocator.free(resolved);
    var file = try std.fs.openFileAbsolute(resolved, .{});
    defer file.close();

    // Get file info to check size
    const stat = try file.stat();
    const file_size = stat.size;

    // Handle offset larger than file size
    if (offset >= file_size) {
        return allocator.dupe(u8, "[offset beyond file end]");
    }

    // Seek to offset
    try file.seekTo(offset);

    // Calculate how many bytes to read
    const bytes_remaining = file_size - offset;
    const bytes_to_read = @min(limit, bytes_remaining);

    // Read the content
    const content = try allocator.alloc(u8, bytes_to_read);
    errdefer allocator.free(content);
    const len = try file.readAll(content);
    if (len < bytes_to_read) {
        const trimmed = try allocator.realloc(content, len);
        return trimmed;
    }

    // If we only read part of the file, add a note
    if (offset > 0 or content.len < bytes_remaining) {
        const prefix = if (offset > 0) try std.fmt.allocPrint(allocator, "[showing bytes {} to {} of {} total]\n\n", .{ offset, offset + content.len, file_size }) else "";
        defer if (offset > 0) allocator.free(prefix);

        const suffix = if (content.len < bytes_remaining) "\n\n[...truncated, more content available]" else "";

        if (offset > 0 or content.len < bytes_remaining) {
            const result = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, content, suffix });
            allocator.free(content);
            return result;
        }
    }

    return content;
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
        return NamedToolError.InvalidArguments; // Pattern not found
    }
    if (!replace_all and matches > 1) return NamedToolError.InvalidArguments;

    var out: std.ArrayListUnmanaged(u8) = .empty;
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
    var original_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer original_lines.deinit(allocator);
    var find_lines: std.ArrayListUnmanaged([]const u8) = .empty;
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
    var out: std.ArrayListUnmanaged(u8) = .empty;
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
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
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
    var summary: std.ArrayListUnmanaged(u8) = .empty;
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

            var content_lines: std.ArrayListUnmanaged([]const u8) = .empty;
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

            var original_lines: std.ArrayListUnmanaged([]const u8) = .empty;
            defer original_lines.deinit(allocator);
            var oit = std.mem.splitScalar(u8, original, '\n');
            while (oit.next()) |raw| {
                try original_lines.append(allocator, std.mem.trimRight(u8, raw, "\r"));
            }
            if (original_trailing_nl and original_lines.items.len > 0 and original_lines.items[original_lines.items.len - 1].len == 0) {
                _ = original_lines.pop();
            }

            var out_lines: std.ArrayListUnmanaged([]const u8) = .empty;
            defer out_lines.deinit(allocator);
            var cursor: usize = 0;

            while (i < end_idx.? and !std.mem.startsWith(u8, lines.items[i], "*** ")) {
                if (lines.items[i].len == 0) {
                    i += 1;
                    continue;
                }
                if (!std.mem.startsWith(u8, lines.items[i], "@@")) return NamedToolError.InvalidArguments;
                i += 1;

                var hunk: std.ArrayListUnmanaged(HunkLine) = .empty;
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
    var out: std.ArrayListUnmanaged(u8) = .empty;
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

fn renderMiniDiff(allocator: std.mem.Allocator, path: []const u8, before: []const u8, after: []const u8) ![]u8 {
    if (std.mem.eql(u8, before, after)) {
        return allocator.dupe(u8, "(no textual change)\n");
    }

    var before_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer before_lines.deinit(allocator);
    var after_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer after_lines.deinit(allocator);

    var bit = std.mem.splitScalar(u8, before, '\n');
    while (bit.next()) |line| try before_lines.append(allocator, std.mem.trimRight(u8, line, "\r"));
    var ait = std.mem.splitScalar(u8, after, '\n');
    while (ait.next()) |line| try after_lines.append(allocator, std.mem.trimRight(u8, line, "\r"));

    if (before.len > 0 and before[before.len - 1] == '\n' and before_lines.items.len > 0 and before_lines.items[before_lines.items.len - 1].len == 0) {
        _ = before_lines.pop();
    }
    if (after.len > 0 and after[after.len - 1] == '\n' and after_lines.items.len > 0 and after_lines.items[after_lines.items.len - 1].len == 0) {
        _ = after_lines.pop();
    }

    var prefix: usize = 0;
    while (prefix < before_lines.items.len and prefix < after_lines.items.len and std.mem.eql(u8, before_lines.items[prefix], after_lines.items[prefix])) : (prefix += 1) {}

    var bs = before_lines.items.len;
    var as = after_lines.items.len;
    while (bs > prefix and as > prefix and std.mem.eql(u8, before_lines.items[bs - 1], after_lines.items[as - 1])) {
        bs -= 1;
        as -= 1;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    const c_reset = "\x1b[0m";
    const c_head = "\x1b[36m";
    const c_hunk = "\x1b[33m";
    const c_del = "\x1b[31m";
    const c_add = "\x1b[32m";
    try w.print("{s}--- a/{s}{s}\n{s}+++ b/{s}{s}\n{s}@@ -{d},{d} +{d},{d} @@{s}\n", .{ c_head, path, c_reset, c_head, path, c_reset, c_hunk, prefix + 1, bs - prefix, prefix + 1, as - prefix, c_reset });

    var i = prefix;
    while (i < bs) : (i += 1) {
        try w.print("{s}-{s}{s}\n", .{ c_del, before_lines.items[i], c_reset });
    }
    i = prefix;
    while (i < as) : (i += 1) {
        try w.print("{s}+{s}{s}\n", .{ c_add, after_lines.items[i], c_reset });
    }
    try w.print("", .{});
    return out.toOwnedSlice(allocator);
}

fn countEditedLines(before: []const u8, after: []const u8) usize {
    if (std.mem.eql(u8, before, after)) return 0;

    var before_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer before_lines.deinit(std.heap.page_allocator);
    var after_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer after_lines.deinit(std.heap.page_allocator);

    var bit = std.mem.splitScalar(u8, before, '\n');
    while (bit.next()) |line| before_lines.append(std.heap.page_allocator, std.mem.trimRight(u8, line, "\r")) catch return MAX_EDIT_LINES_WITHOUT_CONFIRM + 1;
    var ait = std.mem.splitScalar(u8, after, '\n');
    while (ait.next()) |line| after_lines.append(std.heap.page_allocator, std.mem.trimRight(u8, line, "\r")) catch return MAX_EDIT_LINES_WITHOUT_CONFIRM + 1;

    if (before.len > 0 and before[before.len - 1] == '\n' and before_lines.items.len > 0 and before_lines.items[before_lines.items.len - 1].len == 0) {
        _ = before_lines.pop();
    }
    if (after.len > 0 and after[after.len - 1] == '\n' and after_lines.items.len > 0 and after_lines.items[after_lines.items.len - 1].len == 0) {
        _ = after_lines.pop();
    }

    var prefix: usize = 0;
    while (prefix < before_lines.items.len and prefix < after_lines.items.len and std.mem.eql(u8, before_lines.items[prefix], after_lines.items[prefix])) : (prefix += 1) {}

    var bs = before_lines.items.len;
    var as = after_lines.items.len;
    while (bs > prefix and as > prefix and std.mem.eql(u8, before_lines.items[bs - 1], after_lines.items[as - 1])) {
        bs -= 1;
        as -= 1;
    }

    const removed = bs - prefix;
    const added = as - prefix;
    return @max(removed, added);
}

fn runBash(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    if (cancel.isCancelled()) return NamedToolError.Cancelled;
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", command },
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    // Include exit status when non-zero; models often re-run commands when output is empty.
    switch (result.term) {
        .Exited => |code| {
            if (code != 0) try w.print("[exit {d}]\n", .{code});
        },
        .Signal => |sig| {
            try w.print("[signal {d}]\n", .{sig});
        },
        .Stopped => |sig| {
            try w.print("[stopped {d}]\n", .{sig});
        },
        .Unknown => {},
    }

    if (result.stdout.len > 0) {
        try w.writeAll(result.stdout);
        if (result.stdout[result.stdout.len - 1] != '\n') try w.writeByte('\n');
    }
    if (result.stderr.len > 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try w.writeByte('\n');
        try w.writeAll("[stderr]\n");
        try w.writeAll(result.stderr);
    }

    return out.toOwnedSlice(allocator);
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

    var todo_list = todo.TodoList.init(allocator);
    defer todo_list.deinit();
    const out = try executeNamed(allocator, "edit", args, &todo_list);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Replace failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "matched") != null);
}

test "apply_patch rejects empty patch" {
    const allocator = std.testing.allocator;
    var todo_list2 = todo.TodoList.init(allocator);
    defer todo_list2.deinit();
    const output = try executeNamed(allocator, "apply_patch", "{\"patchText\":\"*** Begin Patch\\n*** End Patch\"}", &todo_list2);
    defer allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "empty patch") != null);
}

test "path guard rejects parent traversal" {
    const allocator = std.testing.allocator;
    var todo_list3 = todo.TodoList.init(allocator);
    defer todo_list3.deinit();
    const out = try executeNamed(allocator, "read_file", "{\"path\":\"../outside.txt\"}", &todo_list3);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "outside the workspace") != null);
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

test "render mini diff includes path headers" {
    const allocator = std.testing.allocator;
    const diff = try renderMiniDiff(allocator, "src/demo.zig", "const x = 1;\n", "const x = 2;\n");
    defer allocator.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "--- a/src/demo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+const x = 2;") != null);
}

test "count edited lines tracks changed block size" {
    try std.testing.expectEqual(@as(usize, 1), countEditedLines("a\nb\nc\n", "a\nx\nc\n"));
    try std.testing.expectEqual(@as(usize, 3), countEditedLines("a\nb\nc\n", "a\nx\ny\nz\n"));
}

fn getFileOutline(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const content = try readFileAtPath(allocator, path, 4 * 1024 * 1024);
    defer allocator.free(content);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("Outline of {s}:\n", .{path});

    var it = std.mem.splitScalar(u8, content, '\n');
    var line_num: usize = 1;
    while (it.next()) |line| : (line_num += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Simple heuristics for common languages (Zig, TS, Python, Go)
        const is_decl = std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "const ") or
            std.mem.startsWith(u8, trimmed, "pub const ") or
            std.mem.startsWith(u8, trimmed, "struct ") or
            std.mem.startsWith(u8, trimmed, "pub struct ") or
            std.mem.startsWith(u8, trimmed, "interface ") or
            std.mem.startsWith(u8, trimmed, "class ") or
            std.mem.startsWith(u8, trimmed, "def ") or
            std.mem.startsWith(u8, trimmed, "type ");

        if (is_decl) {
            // Only include the declaration line, but skip very long ones
            const cap = @min(trimmed.len, 120);
            try w.print("{d:4}: {s}\n", .{ line_num, trimmed[0..cap] });
        }
    }

    if (out.items.len <= "Outline of :\n".len + path.len) {
        try w.writeAll("(no major declarations found)\n");
    }

    return out.toOwnedSlice(allocator);
}

fn fetchAndStripUrl(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const cmd = try std.fmt.allocPrint(allocator, "curl -sL \"{s}\"", .{url});
    defer allocator.free(cmd);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", cmd },
        .max_output_bytes = 10 * 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    // If curl failed (exit code != 0)
    if (result.term == .Exited and result.term.Exited != 0) {
        allocator.free(result.stdout);
        return std.fmt.allocPrint(allocator, "Error fetching URL (exit code {d}): {s}", .{result.term.Exited, result.stderr});
    }

    if (result.stdout.len == 0 and result.stderr.len > 0) {
        allocator.free(result.stdout);
        return std.fmt.allocPrint(allocator, "Error fetching URL: {s}", .{result.stderr});
    }

    const stripped = try stripHtml(allocator, result.stdout);
    allocator.free(result.stdout);
    return stripped;
}

fn stripHtml(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            if (isTagStart(html, i, "script")) {
                i = findTagEnd(html, i, "script");
            } else if (isTagStart(html, i, "style")) {
                i = findTagEnd(html, i, "style");
            } else {
                // Skip generic tag
                while (i < html.len and html[i] != '>') : (i += 1) {}
                if (i < html.len) i += 1;
            }
        } else {
            try out.append(allocator, html[i]);
            i += 1;
        }
    }

    return collapseWhitespace(allocator, out.items);
}

fn isTagStart(html: []const u8, index: usize, tag: []const u8) bool {
    if (index + 1 + tag.len >= html.len) return false;
    // Case insensitive check
    for (tag, 0..) |c, j| {
        if (std.ascii.toLower(html[index + 1 + j]) != c) return false;
    }
    // Check if next char is space, slash or >
    const next = html[index + 1 + tag.len];
    return next == ' ' or next == '/' or next == '>' or next == '\t' or next == '\n' or next == '\r';
}

fn findTagEnd(html: []const u8, start: usize, tag: []const u8) usize {
    var i = start + 1;
    while (i < html.len) {
        if (html[i] == '<' and i + 1 < html.len and html[i+1] == '/') {
             // Check for </tag>
             var match = true;
             if (i + 2 + tag.len > html.len) { match = false; }
             else {
                 for (tag, 0..) |c, j| {
                     if (std.ascii.toLower(html[i + 2 + j]) != c) { match = false; break; }
                 }
             }
             if (match) {
                 // Find closure of this tag
                 while (i < html.len and html[i] != '>') : (i += 1) {}
                 if (i < html.len) i += 1;
                 return i;
             }
        }
        i += 1;
    }
    return html.len;
}

fn collapseWhitespace(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    var space = false;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!space) {
                try out.append(allocator, ' ');
                space = true;
            }
        } else {
            try out.append(allocator, c);
            space = false;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "stripHtml removes tags and scripts" {
    const allocator = std.testing.allocator;
    const input =
        "<html>\n" ++
        "<head><title>Test</title><script>var x = 1;</script></head>\n" ++
        "<body>\n" ++
        "  <h1>Hello   World</h1>\n" ++
        "  <p>Text</p>\n" ++
        "  <style>body { color: red; }</style>\n" ++
        "</body>\n" ++
        "</html>";

    const stripped = try stripHtml(allocator, input);
    defer allocator.free(stripped);

    // Check if it contains key text and no tags
    try std.testing.expect(std.mem.indexOf(u8, stripped, "Test") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "Hello World") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "Text") != null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "<script") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "var x") == null);
    try std.testing.expect(std.mem.indexOf(u8, stripped, "color: red") == null);
}
