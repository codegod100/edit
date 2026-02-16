const std = @import("std");
const active_module = @import("../context.zig");
const llm = @import("../llm.zig");
const tools = @import("../tools.zig");
const utils = @import("../utils.zig");
const display = @import("../display.zig");
const tool_routing = @import("../tool_routing.zig");
const todo = @import("../todo.zig");
const cancel = @import("../cancel.zig");

const turn = @import("turn.zig");

// Tool output callback type for timeline integration
// Takes a pre-formatted string and adds it to timeline
pub const ToolOutputCallback = *const fn ([]const u8) void;

var g_tool_output_callback: ?ToolOutputCallback = null;

pub fn setToolOutputCallback(callback: ?ToolOutputCallback) void {
    g_tool_output_callback = callback;
}

pub fn toolOutput(comptime fmt: []const u8, args: anytype) void {
    if (g_tool_output_callback) |callback| {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        callback(text);
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
                'n' => { buf[out_idx] = '\n'; out_idx += 1; in_idx += 1; },
                'r' => { buf[out_idx] = '\r'; out_idx += 1; in_idx += 1; },
                't' => { buf[out_idx] = '\t'; out_idx += 1; in_idx += 1; },
                '\\' => { buf[out_idx] = '\\'; out_idx += 1; in_idx += 1; },
                '"' => { buf[out_idx] = '"'; out_idx += 1; in_idx += 1; },
                'b' => { buf[out_idx] = 0x08; out_idx += 1; in_idx += 1; },
                'f' => { buf[out_idx] = 0x0c; out_idx += 1; in_idx += 1; },
                '/' => { buf[out_idx] = '/'; out_idx += 1; in_idx += 1; },
                else => { buf[out_idx] = input[in_idx]; out_idx += 1; },
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

    var paths: std.ArrayList([]u8) = .empty;
    defer paths.deinit(arena_alloc);
    // Note: paths items are allocated from arena, so no need to free individually

    var w: std.ArrayList(u8) = .empty;
    defer w.deinit(arena_alloc);

    const system_prompt = custom_system_prompt orelse "You are a helpful assistant with access to tools. Use the provided tool interface for any file operations, searching, or bash commands. Prefer bash+rg before reading files unless the user gave an explicit path. Read using explicit offset+limit. Avoid repeating identical tool calls. Finish by calling respond_text. For complex multi-step tasks, use todo_add to create a plan and todo_update to track progress.";

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
            no_tool_retries += 1;
            if (no_tool_retries <= 2) {
                try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":",
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
            toolOutput("{s}Stop:{s} model failed protocol: no tool call after retries (finish_reason={s}).", .{ display.C_DIM, display.C_RESET, finish_reason });
            return .{
                .response = try allocator.dupe(u8, "Model did not return required tool-call format. Try again or switch model/provider."),
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
                display.setSpinnerState(.tool);
                toolOutput("• {s}", .{tc.tool});
            }

            if (std.mem.eql(u8, tc.tool, "respond_text")) {
                if (mutation_request and mutating_tools_executed == 0) {
                    toolOutput("{s}Stop:{s} respond_text rejected: edit request requires at least one mutating tool execution first.", .{ display.C_DIM, display.C_RESET });
                    try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
                    try w.writer(arena_alloc).print(
                        "{f}",
                        .{std.json.fmt("You must run at least one mutating tool (write_file/replace_in_file/edit/write/apply_patch) before respond_text for this request.", .{})},
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

            if (!tools.isReadToolName(tc.tool) and result.len > 0) {
                if (std.mem.eql(u8, tc.tool, "bash")) {
                    try display.printTruncatedCommandOutput(stdout, result);
                } else {
                    var it = std.mem.splitScalar(u8, result, '\n');
                    while (it.next()) |line| {
                        if (line.len == 0) continue;
                        toolOutput("  {s}{s}{s}", .{ display.C_GREY, line, display.C_RESET });
                    }
                }
            }

            try w.appendSlice(arena_alloc, ",{\"role\":\"tool\",\"tool_call_id\":");
            try w.writer(arena_alloc).print("{f}", .{std.json.fmt(tc.id, .{})});
            try w.appendSlice(arena_alloc, ",\"content\":");
            try w.writer(arena_alloc).print("{f}", .{std.json.fmt(result, .{})});
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

    return .{
        .response = try allocator.dupe(u8, "Reached maximum iterations. Task may be incomplete."),
        .reasoning = try allocator.dupe(u8, ""),
        .tool_calls = tool_calls,
        .error_count = 0,
        .files_touched = try utils.joinPaths(allocator, paths.items),
    };
}
