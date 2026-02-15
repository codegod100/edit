const std = @import("std");
const active_module = @import("../context.zig");
const llm = @import("../llm.zig");
const tools = @import("../tools.zig");
const utils = @import("../utils.zig");
const display = @import("../display.zig");
const tool_routing = @import("../tool_routing.zig");
const todo = @import("../todo.zig");
const cancel = @import("../cancel.zig");

pub fn toolDefsToLlm(defs: []const tools.ToolDef) []const llm.ToolRouteDef {
    return @ptrCast(defs);
}

pub fn isCancelled() bool {
    return cancel.isCancelled();
}

pub fn runModelTurnWithTools(
    allocator: std.mem.Allocator,
    stdout: anytype,
    active: active_module.ActiveModel,
    raw_user_request: []const u8,
    user_input: []const u8,
    todo_list: *todo.TodoList,
) !active_module.RunTurnResult {
    var context_prompt = try allocator.dupe(u8, user_input);
    var forced_repo_probe_done = false;
    var forced_mutation_probe_done = false;
    var forced_completion_probe_done = false;
    const repo_specific = tool_routing.isLikelyRepoSpecificQuestion(raw_user_request);
    const mutation_request = tool_routing.isLikelyFileMutationRequest(raw_user_request);
    const multi_step_mutation = tool_routing.isLikelyMultiStepMutationRequest(raw_user_request);
    var tool_calls: usize = 0;
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var step: usize = 0;
    const soft_limit: usize = 6;
    var just_received_tool_call: bool = false;

    while (true) : (step += 1) {
        just_received_tool_call = false;

        if (isCancelled()) {
            allocator.free(context_prompt);
            return .{
                .response = try allocator.dupe(u8, "Operation cancelled by user."),
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }

        if (step >= soft_limit and !just_received_tool_call) {
            const todo_summary = todo_list.summary();
            const continue_prompt = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n[SYSTEM] You have completed {d} tool steps. Todo status: {s}.\n\nDo you need more steps to complete the task? If yes, make another tool call. If no, provide the final answer.",
                .{ context_prompt, step, todo_summary },
            );
            defer allocator.free(continue_prompt);

            const check_response = try llm.query(allocator, active.provider_id, active.api_key, active.model_id, continue_prompt, toolDefsToLlm(tools.definitions[0..]));

            if (std.mem.startsWith(u8, check_response, "TOOL_CALL ")) {
                allocator.free(context_prompt);
                context_prompt = try allocator.dupe(u8, check_response);
                allocator.free(check_response);
                just_received_tool_call = true;
                continue;
            }

            allocator.free(context_prompt);
            return .{
                .response = check_response,
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }

        const route_prompt = try tool_routing.buildToolRoutingPrompt(allocator, context_prompt);
        defer allocator.free(route_prompt);

        var routed = try tool_routing.inferToolCallWithModel(allocator, stdout, active, route_prompt, false);
        if (routed == null and step == 0 and repo_specific and !forced_repo_probe_done) {
            forced_repo_probe_done = true;
            try stdout.print("{s}»{s} ", .{ display.C_DIM, display.C_RESET });
            const strict_prompt = try tool_routing.buildStrictToolRoutingPrompt(allocator, context_prompt);
            defer allocator.free(strict_prompt);
            routed = try tool_routing.inferToolCallWithModel(allocator, stdout, active, strict_prompt, true);
        }

        if (routed == null and step == 0 and mutation_request and !forced_mutation_probe_done) {
            forced_mutation_probe_done = true;
            try stdout.print("{s}✎{s} ", .{ display.C_DIM, display.C_RESET });
            const strict_mutation_prompt = try tool_routing.buildStrictMutationToolRoutingPrompt(allocator, context_prompt);
            defer allocator.free(strict_mutation_prompt);
            routed = try tool_routing.inferToolCallWithModel(allocator, stdout, active, strict_mutation_prompt, true);
        }

        if (routed == null and step == 0 and mutation_request) {
            try stdout.print("{s}ƒ{s} ", .{ display.C_DIM, display.C_RESET });
            routed = try tool_routing.inferToolCallWithTextFallback(allocator, active, context_prompt, true);
        }

        if (routed == null and mutation_request and !forced_completion_probe_done and step < soft_limit) {
            var touched: std.ArrayList([]const u8) = .empty;
            defer touched.deinit(allocator);
            for (paths.items) |p| try touched.append(allocator, p);

            const missing_required = tool_routing.hasUnmetRequiredEdits(raw_user_request, touched.items);
            if ((multi_step_mutation and tool_calls < 2) or missing_required) {
                forced_completion_probe_done = true;
                const completion_prompt = try std.fmt.allocPrint(
                    allocator,
                    "The user requested multiple edits. Completed tool calls so far: {d}. Touched paths: {s}. You must continue with a real tool call to complete remaining requested edits, especially any missing required files like .gitignore when requested.\n\nCurrent request:\n{s}",
                    .{ tool_calls, if (try utils.joinPaths(allocator, paths.items)) |jp| blk: {
                        defer allocator.free(jp);
                        break :blk jp;
                    } else "(none)", raw_user_request },
                );
                defer allocator.free(completion_prompt);
                routed = try tool_routing.inferToolCallWithModel(allocator, stdout, active, completion_prompt, true);
                if (routed == null) {
                    routed = try tool_routing.inferToolCallWithTextFallback(allocator, active, completion_prompt, true);
                }
            }
        }

        if (routed == null) {
            try stdout.print("{s}—{s}\n", .{ display.C_YELLOW, display.C_RESET });

            if (mutation_request and tool_calls == 0) {
                allocator.free(context_prompt);
                return .{
                    .response = try allocator.dupe(
                        u8,
                        "Your request looks like a file edit, but I couldn't determine what to write. Please be more specific—include a filename and the content or change you want.",
                    ),
                    .reasoning = try allocator.dupe(u8, ""),
                    .tool_calls = 0,
                    .error_count = 1,
                    .files_touched = null,
                };
            }

            if (mutation_request) {
                var touched: std.ArrayList([]const u8) = .empty;
                defer touched.deinit(allocator);
                for (paths.items) |p| try touched.append(allocator, p);
                if (tool_routing.hasUnmetRequiredEdits(raw_user_request, touched.items) or (multi_step_mutation and tool_calls < 2)) {
                    allocator.free(context_prompt);
                    return .{
                        .response = try allocator.dupe(
                            u8,
                            "I completed only part of the requested edits. Please specify which remaining file(s) to modify and what changes to make.",
                        ),
                        .reasoning = try allocator.dupe(u8, ""),
                        .tool_calls = tool_calls,
                        .error_count = 1,
                        .files_touched = try utils.joinPaths(allocator, paths.items),
                    };
                }
            }

            const final = try llm.query(allocator, active.provider_id, active.api_key, active.model_id, context_prompt, toolDefsToLlm(tools.definitions[0..]));

            if (std.mem.startsWith(u8, final, "TOOL_CALL ")) {
                const tool_result = try executeInlineToolCalls(allocator, stdout, final, &paths, &tool_calls, todo_list, null);
                allocator.free(final);

                if (tool_result) |result| {
                    const next_prompt = try std.fmt.allocPrint(
                        allocator,
                        "{s}\n\nTool execution result:\n{s}\n\nContinue with next action if needed.",
                        .{ context_prompt, result },
                    );
                    allocator.free(result);
                    context_prompt = next_prompt;
                    continue;
                }
            } else if (step < soft_limit) {
                try stdout.print("{s}...continuing{s}\n", .{ display.C_DIM, display.C_RESET });
                const next_prompt = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n\nAssistant response:\n{s}\n\nContinue with your task. Use tools if needed.",
                    .{ context_prompt, final },
                );
                allocator.free(final);
                context_prompt = next_prompt;
                continue;
            }

            allocator.free(context_prompt);
            return .{
                .response = final,
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }
        defer {
            var r = routed.?;
            r.deinit();
        }

        if (!tools.isKnownToolName(routed.?.tool)) {
            const final = try llm.query(allocator, active.provider_id, active.api_key, active.model_id, context_prompt, toolDefsToLlm(tools.definitions[0..]));

            if (std.mem.startsWith(u8, final, "TOOL_CALL ")) {
                const tool_result = try executeInlineToolCalls(allocator, stdout, final, &paths, &tool_calls, todo_list, null);
                allocator.free(final);
                if (tool_result) |result| {
                    allocator.free(result);
                    allocator.free(context_prompt);
                    return .{
                        .response = try allocator.dupe(u8, "Executed tool from model response."),
                        .reasoning = try allocator.dupe(u8, ""),
                        .tool_calls = tool_calls,
                        .error_count = 0,
                        .files_touched = try utils.joinPaths(allocator, paths.items),
                    };
                }
            } else if (step < soft_limit) {
                try stdout.print("{s}...continuing{s}\n", .{ display.C_DIM, display.C_RESET });
                const next_prompt = try std.fmt.allocPrint(
                    allocator,
                    "{s}\n\nAssistant response:\n{s}\n\nContinue with your task. Use tools if needed.",
                    .{ context_prompt, final },
                );
                allocator.free(final);
                context_prompt = next_prompt;
                continue;
            }

            allocator.free(context_prompt);
            return .{
                .response = final,
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }

        if (isCancelled()) {
            allocator.free(context_prompt);
            return .{
                .response = try allocator.dupe(u8, "Operation cancelled by user during tool execution."),
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }

        tool_calls += 1;
        if (tools.parsePrimaryPathFromArgs(allocator, routed.?.arguments_json)) |p| {
            if (!utils.containsPath(paths.items, p)) {
                try paths.append(allocator, p);
            } else {
                allocator.free(p);
            }
        }

        const call_id = try std.fmt.allocPrint(allocator, "toolcall-{d}", .{step + 1});
        defer allocator.free(call_id);

        try display.printColoredToolEvent(stdout, "tool-input-start", step + 1, call_id, routed.?.tool);
        try display.printColoredToolEvent(stdout, "tool-call", step + 1, call_id, routed.?.tool);

        const started_ms = std.time.milliTimestamp();
        const file_path = tools.parsePrimaryPathFromArgs(allocator, routed.?.arguments_json);

        const tool_out = tools.executeNamed(allocator, routed.?.tool, routed.?.arguments_json, todo_list, null) catch |err| {
            const failed_ms = std.time.milliTimestamp();
            const duration_ms = failed_ms - started_ms;
            const err_line = try display.buildToolResultEventLine(allocator, step + 1, call_id, routed.?.tool, "error", 0, duration_ms, file_path);
            defer allocator.free(err_line);
            if (file_path) |fp| allocator.free(fp);
            try stdout.print("{s}\n", .{err_line});
            allocator.free(context_prompt);
            return .{
                .response = try std.fmt.allocPrint(
                    allocator,
                    "Tool execution failed at step {d} ({s}): {s}",
                    .{ step + 1, routed.?.tool, @errorName(err) },
                ),
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 1,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        };
        defer allocator.free(tool_out);

        const finished_ms = std.time.milliTimestamp();
        const duration_ms = finished_ms - started_ms;
        const ok_line = try display.buildToolResultEventLine(allocator, step + 1, call_id, routed.?.tool, "ok", tool_out.len, duration_ms, file_path);
        defer allocator.free(ok_line);
        if (file_path) |fp| allocator.free(fp);
        try stdout.print("{s}\n", .{ok_line});

        if (tools.isMutatingToolName(routed.?.tool)) {
            try display.printColoredToolEvent(stdout, "tool-meta", step + 1, call_id, routed.?.tool);
            try stdout.print("{s}\n", .{tool_out});
        } else if (tools.isReadToolName(routed.?.tool)) {
            try display.printColoredToolEvent(stdout, "tool-meta", step + 1, call_id, routed.?.tool);
            const max_lines: usize = 15;
            var lines_shown: usize = 0;
            var pos: usize = 0;
            var truncated = false;

            while (pos < tool_out.len and lines_shown < max_lines) {
                if (tool_out[pos] == '\n') {
                    lines_shown += 1;
                }
                pos += 1;
            }

            if (pos < tool_out.len) {
                truncated = true;
            }

            if (truncated) {
                var total_lines: usize = 1;
                for (tool_out) |ch| {
                    if (ch == '\n') total_lines += 1;
                }
                try stdout.print("{s}\n[...truncated, showing {d} of {d} lines]\n", .{ tool_out[0..pos], max_lines, total_lines });
            } else {
                try stdout.print("{s}\n", .{tool_out});
            }
        }

        const capped = if (tool_out.len > 4000) tool_out[0..4000] else tool_out;
        const next_prompt = try std.fmt.allocPrint(
            allocator,
            "{s}\n\nTool events:\n- event=tool-input-start step={d} call_id={s} tool={s}\n- event=tool-call step={d} call_id={s} tool={s}\n- {s}\nArguments JSON: {s}\nTool output:\n{s}\n\nYou may call another tool if needed. Otherwise return the final user-facing answer.",
            .{ context_prompt, step + 1, call_id, routed.?.tool, step + 1, call_id, routed.?.tool, ok_line, routed.?.arguments_json, capped },
        );
        allocator.free(context_prompt);
        context_prompt = next_prompt;
    }
}

// Forward declaration - implemented in tools.zig
pub fn executeInlineToolCalls(
    allocator: std.mem.Allocator,
    stdout: anytype,
    response: []const u8,
    paths: *std.ArrayList([]u8),
    tool_calls: *usize,
    todo_list: *todo.TodoList,
    subagent_manager: ?*@import("../subagent.zig").SubagentManager,
) !?[]u8 {
    return @import("tools.zig").executeInlineToolCalls(allocator, stdout, response, paths, tool_calls, todo_list, subagent_manager);
}
