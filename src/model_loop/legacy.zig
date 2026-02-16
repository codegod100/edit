const std = @import("std");

const active_module = @import("../context.zig");
const llm = @import("../llm.zig");
const tools = @import("../tools.zig");
const utils = @import("../utils.zig");
const display = @import("../display.zig");
const tool_routing = @import("../tool_routing.zig");
const todo = @import("../todo.zig");
const cancel = @import("../cancel.zig");
const logger = @import("../logger.zig");

const turn = @import("turn.zig");

// Tool output callback type for timeline integration
// Takes a pre-formatted string and adds it to timeline
pub const ToolOutputCallback = *const fn ([]const u8) void;

var g_tool_output_callback: ?ToolOutputCallback = null;

pub fn setToolOutputCallback(callback: ?ToolOutputCallback) void {
    g_tool_output_callback = callback;
}

// Global arena for tool output strings (cleared each turn)
var g_tool_output_arena: ?std.heap.ArenaAllocator = null;

pub fn initToolOutputArena(allocator: std.mem.Allocator) void {
    g_tool_output_arena = std.heap.ArenaAllocator.init(allocator);
}

pub fn deinitToolOutputArena() void {
    if (g_tool_output_arena) |*arena| {
        arena.deinit();
        g_tool_output_arena = null;
    }
}

pub fn toolOutput(comptime fmt: []const u8, args: anytype) void {
    if (g_tool_output_callback) |callback| {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        // Use arena to allocate persistent copy
        if (g_tool_output_arena) |*arena| {
            const copy = arena.allocator().alloc(u8, text.len) catch return;
            @memcpy(copy, text);
            callback(copy);
        }
    }
}

/// Unescape JSON escape sequences in place
fn unescapeJsonString(buf: []u8, input: []const u8) []const u8 {
    var out_idx: usize = 0;
    var in_idx: usize = 0;
    while (in_idx < input.len and out_idx < buf.len) : (in_idx += 1) {
        if (input[in_idx] == '\\' and in_idx + 1 < input.len) {
            const next = input[in_idx + 1];
            switch (next) {
                'n' => {
                    buf[out_idx] = '\n';
                    out_idx += 1;
                    in_idx += 1;
                },
                'r' => {
                    buf[out_idx] = '\r';
                    out_idx += 1;
                    in_idx += 1;
                },
                't' => {
                    buf[out_idx] = '\t';
                    out_idx += 1;
                    in_idx += 1;
                },
                '\\' => {
                    buf[out_idx] = '\\';
                    out_idx += 1;
                    in_idx += 1;
                },
                '"' => {
                    buf[out_idx] = '"';
                    out_idx += 1;
                    in_idx += 1;
                },
                'b' => {
                    buf[out_idx] = 0x08;
                    out_idx += 1;
                    in_idx += 1;
                },
                'f' => {
                    buf[out_idx] = 0x0c;
                    out_idx += 1;
                    in_idx += 1;
                },
                '/' => {
                    buf[out_idx] = '/';
                    out_idx += 1;
                    in_idx += 1;
                },
                else => {
                    buf[out_idx] = input[in_idx];
                    out_idx += 1;
                },
            }
        } else {
            buf[out_idx] = input[in_idx];
            out_idx += 1;
        }
    }
    return buf[0..out_idx];
}

// Simplified bridge-based tool loop - uses Bun AI SDK
pub fn runModel(
    allocator: std.mem.Allocator,
    stdout: anytype,
    active: active_module.ActiveModel,
    raw_user_request: []const u8,
    user_input: []const u8,
    stdout_is_tty: bool,
    todo_list: *todo.TodoList,
    custom_system_prompt: ?[]const u8,
) !active_module.RunTurnResult {
    _ = stdout_is_tty;

    // Use an arena for the entire turn to simplify memory management
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const mutation_request = tool_routing.isLikelyFileMutationRequest(raw_user_request);
    var mutating_tools_executed: usize = 0;

    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer paths.deinit(arena_alloc);
    // Note: paths items are allocated from arena, so no need to free individually

    var w: std.ArrayListUnmanaged(u8) = .empty;
    defer w.deinit(arena_alloc);

    const system_prompt = custom_system_prompt orelse "You are a highly capable software engineering assistant. Your goal is to help the user with their task efficiently and accurately.\n\n" ++
        "1. **Analyze First**: Before making changes, use `grep` and `read_file` to understand the existing codebase, architectural patterns, and naming conventions. Mimic the style and structure of the project.\n" ++
        "2. **Plan Your Work**: For multi-step tasks, you MUST use `todo_add` to create a detailed plan. Update your progress with `todo_update` as you complete each step. Break down complex tasks into smaller, manageable chunks.\n" ++
        "3. **Be Precise**: When editing files, provide exact matches for `find` or `oldString`. Avoid introducing redundant or messy code. If you notice a pattern (like provider IDs), follow it strictly.\n" ++
        "4. **Tools & Output**: Use `bash` with `rg` for searching. Read files with `offset` and `limit`. You will receive tool outputs with ANSI colors removed for clarity. Always verify your changes if possible.\n" ++
        "5. **Finish Cleanly**: Once the task is complete, provide a concise summary of your actions via `respond_text`.";

    // Build messages array (without system field - that goes in separate system param for most APIs)
    try w.appendSlice(arena_alloc, "[");

    try w.writer(arena_alloc).print(
        "{{\"role\":\"system\",\"content\":{f}}},",
        .{std.json.fmt(system_prompt, .{})},
    );

    try w.writer(arena_alloc).print(
        "{{\"role\":\"user\",\"content\":{f}}}",
        .{std.json.fmt(user_input, .{})},
    );

    var tool_calls: usize = 0;
    var no_tool_retries: usize = 0;
    var last_tool_name: ?[]u8 = null;
    var last_tool_args: ?[]u8 = null;
    defer {
        if (last_tool_name) |v| allocator.free(v);
        if (last_tool_args) |v| allocator.free(v);
    }
    var repeated_tool_calls: usize = 0;
    var rejected_repeated_bash: usize = 0;
    var rejected_repeated_other: usize = 0;
    var consecutive_empty_rg: usize = 0;

    const max_iterations: usize = 12;
    var iter: usize = 0;

    while (iter < max_iterations) : (iter += 1) {
        if (turn.isCancelled()) {
            return .{
                .response = try allocator.dupe(u8, "Operation cancelled by user."),
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }

        try w.appendSlice(arena_alloc, "]");

        const messages_json = w.items;
        const response = try llm.chat(
            arena_alloc,
            active.api_key orelse "",
            active.model_id,
            active.provider_id,
            messages_json,
            turn.toolDefsToLlm(tools.definitions[0..]),
            active.reasoning_effort,
        );
        
        if (turn.isCancelled()) {
            return .{
                .response = try allocator.dupe(u8, "Operation cancelled by user."),
                .reasoning = try allocator.dupe(u8, response.reasoning),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }

        // Response is arena-allocated, no need to deinit individual fields

        try w.replaceRange(arena_alloc, w.items.len - 1, 1, "");

        // Add assistant's message with tool_calls to conversation
        try w.writer(arena_alloc).writeAll(",{\"role\":\"assistant\",\"tool_calls\":[");
        for (response.tool_calls, 0..) |tc, i| {
            if (i > 0) try w.writer(arena_alloc).writeAll(",");
            // Format: {"id":"...","type":"function","function":{"name":"...","arguments":"..."}}
            try w.writer(arena_alloc).print("{{\"id\":{f},\"type\":\"function\",\"function\":{{\"name\":{f},\"arguments\":{f}}}}}", .{
                std.json.fmt(tc.id, .{}),
                std.json.fmt(tc.tool, .{}),
                std.json.fmt(tc.args, .{}),
            });
        }
        try w.writer(arena_alloc).writeAll("]}");

        if (response.tool_calls.len == 0) {
            const trimmed_text = std.mem.trim(u8, response.text, " \t\r\n");
            if (trimmed_text.len > 0) {
                toolOutput("{s}⛬{s} {s}", .{ display.C_CYAN, display.C_RESET, response.text });
                return .{
                    .response = try allocator.dupe(u8, response.text),
                    .reasoning = try allocator.dupe(u8, response.reasoning),
                    .tool_calls = tool_calls,
                    .error_count = 0,
                    .files_touched = try utils.joinPaths(allocator, paths.items),
                };
            }
            no_tool_retries += 1;
            if (no_tool_retries <= 2) {
                try w.appendSlice(
                    arena_alloc,
                    ",{\"role\":\"user\",\"content\":",
                );
                if (no_tool_retries == 1) {
                    try w.writer(arena_alloc).print(
                        "{f}",
                        .{std.json.fmt("You did not call any tools. You must use the function-call tool interface.", .{})},
                    );
                } else {
                    try w.writer(arena_alloc).print(
                        "{f}",
                        .{std.json.fmt("Return at least one tool call via the function-call interface. If you are ready to answer finally, call respond_text with {\"text\":\"...\"}. Do not reply with plain text outside tool calls.", .{})},
                    );
                }
                try w.appendSlice(arena_alloc, "}");
                continue;
            }
            const finish_reason = if (response.finish_reason.len > 0) response.finish_reason else "none";
            const msg = "Model did not return required tool-call format. Try again or switch model/provider.";
            toolOutput("{s}Stop:{s} model failed protocol: no tool call after retries (finish_reason={s}).", .{ display.C_DIM, display.C_RESET, finish_reason });
            toolOutput("{s}Error:{s} {s}", .{ display.C_RED, display.C_RESET, msg });
            return .{
                .response = try allocator.dupe(u8, msg),
                .reasoning = try allocator.dupe(u8, response.reasoning),
                .tool_calls = tool_calls,
                .error_count = 1,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }
        no_tool_retries = 0;

        for (response.tool_calls) |tc| {
            const is_same_as_prev = blk: {
                if (last_tool_name == null or last_tool_args == null) break :blk false;
                break :blk std.mem.eql(u8, last_tool_name.?, tc.tool) and std.mem.eql(u8, last_tool_args.?, tc.args);
            };
            if (is_same_as_prev) {
                repeated_tool_calls += 1;
            } else {
                repeated_tool_calls = 0;
                if (last_tool_name) |v| allocator.free(v);
                if (last_tool_args) |v| allocator.free(v);
                last_tool_name = allocator.dupe(u8, tc.tool) catch |err| {
                    last_tool_name = null;
                    last_tool_args = null;
                    return err;
                };
                last_tool_args = allocator.dupe(u8, tc.args) catch |err| {
                    allocator.free(last_tool_name.?);
                    last_tool_name = null;
                    last_tool_args = null;
                    return err;
                };
            }

            const is_bash = std.mem.eql(u8, tc.tool, "bash");
            const repeat_threshold: usize = if (is_bash) 1 else 3;
            if (repeated_tool_calls >= repeat_threshold) {
                toolOutput("{s}Note:{s} repeated identical tool call detected; requesting a different next action.", .{ display.C_DIM, display.C_RESET });
                try w.appendSlice(arena_alloc, ",{\"role\":\"tool\",\"tool_call_id\":");
                try w.writer(arena_alloc).print("{f}", .{std.json.fmt(tc.id, .{})});
                try w.appendSlice(arena_alloc, ",\"content\":");
                try w.writer(arena_alloc).print(
                    "{f}",
                    .{std.json.fmt("Tool call rejected: repeated identical tool call. Reuse the previous result and choose a different next action (or finish with respond_text).", .{})},
                );
                try w.appendSlice(arena_alloc, "}");

                if (is_bash) {
                    rejected_repeated_bash += 1;
                } else {
                    rejected_repeated_other += 1;
                }

                if (rejected_repeated_bash >= 2 or rejected_repeated_other >= 6) {
                    toolOutput("{s}Stop:{s} model is stuck repeating the same tool call.", .{ display.C_DIM, display.C_RESET });
                    return .{
                        .response = try allocator.dupe(u8, "Model kept repeating the same tool call even after rejection. Try rephrasing the request, or switch model/provider."),
                        .reasoning = try allocator.dupe(u8, response.reasoning),
                        .tool_calls = tool_calls,
                        .error_count = 1,
                        .files_touched = try utils.joinPaths(allocator, paths.items),
                    };
                }
                continue;
            }

            tool_calls += 1;

            if (std.mem.eql(u8, tc.tool, "subagent_spawn")) {
                // Subagent support removed - return error
                const msg = "{\"error\":\"Subagent support has been removed\"}";
                try w.appendSlice(arena_alloc, ",{\"role\":\"tool\",\"tool_call_id\":");
                try w.writer(arena_alloc).print("{f}", .{std.json.fmt(tc.id, .{})});
                try w.appendSlice(arena_alloc, ",\"content\":");
                try w.writer(arena_alloc).print("{f}", .{std.json.fmt(msg, .{})});
                try w.appendSlice(arena_alloc, "}");
                continue;
            }

            // Update spinner state based on tool type
            if (std.mem.eql(u8, tc.tool, "bash")) {
                if (tools.parseBashCommandFromArgs(allocator, tc.args)) |cmd| {
                    defer allocator.free(cmd);
                    const c = std.mem.trim(u8, cmd, " \t\r\n");
                    const is_rg = std.mem.eql(u8, c, "rg") or std.mem.startsWith(u8, c, "rg ");
                    if (is_rg) {
                        // Only truncate if really long (80 chars)
                        const display_cmd = if (cmd.len > 80) cmd[cmd.len - 80 ..] else cmd;
                        display.setSpinnerStateWithText(.search, display_cmd);
                        toolOutput("• Search {s}", .{cmd});
                    } else {
                        const display_cmd = if (cmd.len > 80) cmd[cmd.len - 80 ..] else cmd;
                        display.setSpinnerStateWithText(.bash, display_cmd);
                        toolOutput("• Ran {s}", .{cmd});
                    }
                } else {
                    display.setSpinnerState(.bash);
                    toolOutput("• Ran {s}", .{tc.tool});
                }
            } else if (tools.parsePrimaryPathFromArgs(arena_alloc, tc.args)) |path| {
                defer arena_alloc.free(path);
                if (std.mem.eql(u8, tc.tool, "read") or std.mem.eql(u8, tc.tool, "read_file")) {
                    const display_path = if (path.len > 80) path[path.len - 80 ..] else path;
                    display.setSpinnerStateWithText(.reading, display_path);
                    if (try tools.parseReadParamsFromArgs(arena_alloc, tc.args)) |params| {
                        if (params.offset) |off| {
                            toolOutput("• {s} {s} [{d}:{d}]", .{ tc.tool, path, off, params.limit orelse 0 });
                        } else {
                            toolOutput("• {s} {s}", .{ tc.tool, path });
                        }
                    } else {
                        toolOutput("• {s} {s}", .{ tc.tool, path });
                    }
                } else {
                    const display_path = if (path.len > 80) path[path.len - 80 ..] else path;
                    display.setSpinnerStateWithText(.writing, display_path);
                    toolOutput("• {s} {s}", .{ tc.tool, path });
                }
            } else if (std.mem.eql(u8, tc.tool, "respond_text")) {
                display.setSpinnerState(.thinking);
                // Extract and show the text content
                const text = tools.parseRespondTextFromArgs(tc.args) orelse "(empty)";
                // Unescape JSON escape sequences (\n -> newline, etc.)
                var unescape_buf: [4096]u8 = undefined;
                const unescaped = unescapeJsonString(&unescape_buf, text);
                toolOutput("{s}⛬{s} {s}", .{ display.C_CYAN, display.C_RESET, unescaped });
            } else {
                display.setSpinnerStateWithText(.tool, tc.tool);
                toolOutput("• {s}", .{tc.tool});
            }

            if (std.mem.eql(u8, tc.tool, "respond_text")) {
                if (mutation_request and mutating_tools_executed == 0) {
                    toolOutput("{s}Note:{s} request seems to require a file change, but no mutating tools were run.", .{ display.C_YELLOW, display.C_RESET });
                    try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
                    try w.writer(arena_alloc).print(
                        "{f}",
                        .{std.json.fmt("Your plan mentioned a file change, but you haven't executed any mutating tools (like write_file, edit, etc.) yet. Please execute the necessary tools to apply the changes before calling respond_text. If no change is actually needed, please explain why.", .{})},
                    );
                    try w.appendSlice(arena_alloc, "}");
                    continue;
                }
                const final_text = tools.executeNamed(arena_alloc, tc.tool, tc.args, todo_list) catch |err| {
                    toolOutput("{s}  error: {s}{s}", .{ display.C_RED, @errorName(err), display.C_RESET });
                    return .{
                        .response = try allocator.dupe(u8, "respond_text arguments were invalid."),
                        .reasoning = try allocator.dupe(u8, response.reasoning),
                        .tool_calls = tool_calls,
                        .error_count = 1,
                        .files_touched = try utils.joinPaths(allocator, paths.items),
                    };
                };
                return .{
                    .response = try allocator.dupe(u8, final_text),
                    .reasoning = try allocator.dupe(u8, response.reasoning),
                    .tool_calls = tool_calls,
                    .error_count = 0,
                    .files_touched = try utils.joinPaths(allocator, paths.items),
                };
            }
            if (tools.isMutatingToolName(tc.tool)) mutating_tools_executed += 1;

            const result = tools.executeNamed(arena_alloc, tc.tool, tc.args, todo_list) catch |err| {
                toolOutput("{s}  error: {s}{s}", .{ display.C_RED, @errorName(err), display.C_RESET });
                const err_msg = try std.fmt.allocPrint(allocator, "Tool {s} failed: {s}", .{ tc.tool, @errorName(err) });
                defer allocator.free(err_msg);

                try w.appendSlice(arena_alloc, ",{\"role\":\"tool\",\"tool_call_id\":");
                try w.writer(arena_alloc).print("{f}", .{std.json.fmt(tc.id, .{})});
                try w.appendSlice(arena_alloc, ",\"content\":");
                try w.writer(arena_alloc).print("{f}", .{std.json.fmt(err_msg, .{})});
                try w.appendSlice(arena_alloc, "}");
                continue;
            };
            defer arena_alloc.free(result);

            if (result.len > 0) {
                try display.printTruncatedCommandOutput(stdout, result);
            }

            const clean_result = try display.stripAnsi(arena_alloc, result);
            // clean_result is in arena, no need to free

            try w.appendSlice(arena_alloc, ",{\"role\":\"tool\",\"tool_call_id\":");
            try w.writer(arena_alloc).print("{f}", .{std.json.fmt(tc.id, .{})});
            try w.appendSlice(arena_alloc, ",\"content\":");
            try w.writer(arena_alloc).print("{f}", .{std.json.fmt(clean_result, .{})});
            try w.appendSlice(arena_alloc, "}");

            if (std.mem.eql(u8, tc.tool, "bash")) {
                const A = struct { command: ?[]const u8 = null };
                if (std.json.parseFromSlice(A, allocator, tc.args, .{ .ignore_unknown_fields = true })) |p| {
                    defer p.deinit();
                    if (p.value.command) |cmd_raw| {
                        const cmd = std.mem.trim(u8, cmd_raw, " \t\r\n");
                        const is_rg = std.mem.eql(u8, cmd, "rg") or std.mem.startsWith(u8, cmd, "rg ");
                        if (is_rg) {
                            const out_trimmed = std.mem.trim(u8, result, " \t\r\n");
                            const effectively_empty = out_trimmed.len == 0 or std.mem.eql(u8, out_trimmed, "[exit 1]");
                            if (effectively_empty) {
                                consecutive_empty_rg += 1;
                                if (consecutive_empty_rg >= 2) {
                                    try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
                                    try w.writer(arena_alloc).print(
                                        "{f}",
                                        .{std.json.fmt("rg returned no matches multiple times. Do not keep varying the pattern. Instead, inspect likely files (e.g. list src/, open README/config), or ask the user for the exact symbol/file to change.", .{})},
                                    );
                                    try w.appendSlice(arena_alloc, "}");
                                }
                            } else {
                                consecutive_empty_rg = 0;
                            }
                        } else {
                            consecutive_empty_rg = 0;
                        }
                    }
                } else |_| {}
            } else {
                consecutive_empty_rg = 0;
            }

            if (tools.parsePrimaryPathFromArgs(arena_alloc, tc.args)) |p| {
                if (!utils.containsPath(paths.items, p)) {
                    try paths.append(arena_alloc, p);
                } else {
                    arena_alloc.free(p);
                }
            }
        }
    }

    toolOutput("{s}Stop:{s} reached maximum step limit ({d}).", .{ display.C_DIM, display.C_RESET, max_iterations });
    const msg = "Reached maximum iterations. Task may be incomplete.";
    toolOutput("{s}Note:{s} {s}", .{ display.C_YELLOW, display.C_RESET, msg });

    return .{
        .response = try allocator.dupe(u8, msg),
        .reasoning = try allocator.dupe(u8, ""),
        .tool_calls = tool_calls,
        .error_count = 0,
        .files_touched = try utils.joinPaths(allocator, paths.items),
    };
}
