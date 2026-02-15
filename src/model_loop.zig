const std = @import("std");
const active_module = @import("context.zig"); // for ActiveModel
const llm = @import("llm.zig");
const tools = @import("tools.zig");
const utils = @import("utils.zig");
const display = @import("display.zig");
const auth = @import("auth.zig");
const tool_routing = @import("tool_routing.zig");
const subagent = @import("subagent.zig");
const todo = @import("todo.zig");
const cancel = @import("cancel.zig");

// Helper to convert tools.ToolDef slice to llm.ToolRouteDef slice
pub fn toolDefsToLlm(defs: []const tools.ToolDef) []const llm.ToolRouteDef {
    return @ptrCast(defs);
}

pub fn isCancelled() bool {
    return cancel.isCancelled();
}

pub fn callModelDirect(
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model_id: []const u8,
    provider_id: []const u8,
    messages_json: []const u8,
    tool_defs: ?[]const llm.ToolRouteDef,
    reasoning_effort: ?[]const u8,
) !llm.ChatResponse {
    return llm.chat(allocator, api_key, model_id, provider_id, messages_json, tool_defs, reasoning_effort);
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
    // We'll manually free context_prompt before each reassignment and at function exit
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
    const soft_limit: usize = 6; // After this, check todos and ask model if we should continue
    var just_received_tool_call: bool = false; // Track if we got TOOL_CALL at soft limit

    while (true) : (step += 1) {
        // Reset flag at start of iteration
        just_received_tool_call = false;

        // Check for cancellation at start of each iteration
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

        // On step 6+, check todos and ask model if we should continue
        // Skip this check if we just received a TOOL_CALL (model wants to continue)
        if (step >= soft_limit and !just_received_tool_call) {
            const todo_summary = todo_list.summary();
            const continue_prompt = try std.fmt.allocPrint(
                allocator,
                "{s}\n\n[SYSTEM] You have completed {d} tool steps. Todo status: {s}.\n\nDo you need more steps to complete the task? If yes, make another tool call. If no, provide the final answer.",
                .{ context_prompt, step, todo_summary },
            );
            defer allocator.free(continue_prompt);

            // Query model to see if it wants to continue
            const check_response = try llm.query(allocator, active.provider_id, active.api_key, active.model_id, continue_prompt, toolDefsToLlm(tools.definitions[0..]));

            // If model returns TOOL_CALL, continue the loop
            if (std.mem.startsWith(u8, check_response, "TOOL_CALL ")) {
                allocator.free(context_prompt);
                context_prompt = try allocator.dupe(u8, check_response);
                allocator.free(check_response);
                just_received_tool_call = true; // Mark that we got a TOOL_CALL
                continue;
            }

            // Model gave final answer, return it
            allocator.free(context_prompt);
            return .{
                .response = check_response,
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 0, // Simplified for now
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

            // Check if response contains inline tool calls (TOOL_CALL format)
            if (std.mem.startsWith(u8, final, "TOOL_CALL ")) {
                // Execute inline tool calls from model response
                const tool_result = try executeInlineToolCalls(allocator, stdout, final, &paths, &tool_calls, todo_list, null);
                allocator.free(final);

                if (tool_result) |result| {
                    // Append tool result to context and continue loop
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
                // Model returned text but we haven't hit max steps yet
                // Add response to context and continue the loop
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

            // Check for inline tool calls
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
                // Model returned text but we haven't hit max steps yet
                // Add response to context and continue the loop
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

        // Check for cancellation before executing tool
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

        // Extract file path for file-related tools
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
            // For mutating tools, show the full output including the colored diff
            try display.printColoredToolEvent(stdout, "tool-meta", step + 1, call_id, routed.?.tool);
            try stdout.print("{s}\n", .{tool_out});
        } else if (tools.isReadToolName(routed.?.tool)) {
            // For read tools, show first few lines with truncation indicator
            try display.printColoredToolEvent(stdout, "tool-meta", step + 1, call_id, routed.?.tool);
            const max_lines: usize = 15;
            var lines_shown: usize = 0;
            var pos: usize = 0;
            var truncated = false;

            // Find position after max_lines
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
                // Count total lines
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

// Simplified bridge-based tool loop - uses Bun AI SDK
pub fn runModel(
    allocator: std.mem.Allocator,
    stdout: anytype,
    active: active_module.ActiveModel,
    raw_user_request: []const u8,
    user_input: []const u8,
    stdout_is_tty: bool,
    todo_list: *todo.TodoList,
    subagent_manager: ?*subagent.SubagentManager,
    system_prompt_override: ?[]const u8,
) !active_module.RunTurnResult {
    const mutation_request = tool_routing.isLikelyFileMutationRequest(raw_user_request);
    const allow_read_first = utils.containsIgnoreCase(raw_user_request, "src/") or
        utils.containsIgnoreCase(raw_user_request, ".zig") or
        utils.containsIgnoreCase(raw_user_request, "build.zig") or
        (std.mem.indexOfScalar(u8, raw_user_request, '@') != null) or
        (std.mem.indexOfScalar(u8, raw_user_request, '/') != null and std.mem.indexOfScalar(u8, raw_user_request, '.') != null);

    // Check API key
    if (active.api_key == null and !std.mem.eql(u8, active.provider_id, "opencode")) {
        try stdout.print("{s}Stop:{s} no API key is configured for provider {s}.\n", .{ display.C_DIM, display.C_RESET, active.provider_id });
        return .{
            .response = try allocator.dupe(u8, "No API key configured for this provider. Run /connect to set it up."),
            .reasoning = try allocator.dupe(u8, ""),
            .tool_calls = 0,
            .error_count = 1,
            .files_touched = null,
        };
    }
    const api_key = active.api_key orelse "";

    const default_system_prompt =
        "You are zagent, an AI coding assistant. Use the function-call tool interface for any tool usage. If no more external tools are needed, call the 'respond_text' tool with your final user-facing answer. For repository work: unless the user gives an explicit target file path, start with bash using rg to locate files/symbols; do not start by reading random files. After rg, read only the most relevant file(s) with explicit offset+limit and use bounded chunks for large files instead of broad scans. Avoid repeating identical tool calls; reuse prior results when possible. Do not call todo_list; the current todo state is already provided.";
    const system_prompt = system_prompt_override orelse default_system_prompt;

    // Build initial messages
    var messages: std.ArrayList(u8) = .empty;
    defer messages.deinit(allocator);
    const w = messages.writer(allocator);
    try w.writeAll("[{\"role\":\"system\",\"content\":\"");
    try utils.writeJsonString(w, system_prompt);
    try w.writeAll("\"},{\"role\":\"user\",\"content\":\"");
    try utils.writeJsonString(w, user_input);
    try w.writeAll("\"}");

    var tool_calls: usize = 0;
    var mutating_tools_executed: usize = 0;
    var no_tool_retries: usize = 0;
    var last_tool_name: ?[]u8 = null;
    defer if (last_tool_name) |v| allocator.free(v);
    var last_tool_args: ?[]u8 = null;
    defer if (last_tool_args) |v| allocator.free(v);
    var repeated_tool_calls: usize = 0;
    var consecutive_empty_rg: usize = 0;
    var last_todo_guidance: ?[]u8 = null;
    defer if (last_todo_guidance) |v| allocator.free(v);
    var rejected_repeated_bash: usize = 0;
    var rejected_repeated_other: usize = 0;
    var has_searched: bool = false;
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    const max_iterations: usize = 30;
    var iteration: usize = 0;

    while (iteration < max_iterations) : (iteration += 1) {
        // Keep the model grounded with live todo state, but avoid spamming the prompt when it hasn't changed.
        const todo_snapshot = try todo_list.list(allocator);
        defer allocator.free(todo_snapshot);
        const todo_guidance = try std.fmt.allocPrint(
            allocator,
            "Todo status: {s}\nCurrent todos:\n{s}\nGuidance: choose the next action based on pending/in_progress todos; update todo status as you complete work.",
            .{ todo_list.summary(), todo_snapshot },
        );
        defer allocator.free(todo_guidance);
        const todo_changed = if (last_todo_guidance) |prev| !std.mem.eql(u8, prev, todo_guidance) else true;
        if (todo_changed) {
            if (last_todo_guidance) |prev| allocator.free(prev);
            last_todo_guidance = try allocator.dupe(u8, todo_guidance);
            try w.writeAll(",{\"role\":\"user\",\"content\":");
            try w.print("{f}", .{std.json.fmt(todo_guidance, .{})});
            try w.writeAll("}");
        }

        // Send current messages (add closing bracket)
        const messages_json = try std.fmt.allocPrint(allocator, "{s}]", .{messages.items});
        defer allocator.free(messages_json);

        // Call the model directly (no bridge)
        const response = try callModelDirect(
            allocator,
            api_key,
            active.model_id,
            active.provider_id,
            messages_json,
            toolDefsToLlm(tools.definitions[0..]),
            active.reasoning_effort,
        );
        defer {
            allocator.free(response.text);
            allocator.free(response.reasoning);
            allocator.free(response.finish_reason);
            for (response.tool_calls) |tc| {
                allocator.free(tc.id);
                allocator.free(tc.tool);
                allocator.free(tc.args);
            }
            allocator.free(response.tool_calls);
        }

        if (stdout_is_tty) {
            // Keep model/tool output from landing on the user's type-ahead prompt line.
            try stdout.print("\n", .{});
        }

        // Add assistant message to history
        try w.writeAll(",{\"role\":\"assistant\",\"content\":");
        try w.print("{f}", .{std.json.fmt(response.text, .{})});

        if (response.tool_calls.len > 0) {
            try w.writeAll(",\"tool_calls\":[");
            for (response.tool_calls, 0..) |tc, i| {
                if (i > 0) try w.writeAll(",");
                try w.writeAll("{\"id\":");
                try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                try w.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                try w.print("{f}", .{std.json.fmt(tc.tool, .{})});
                try w.writeAll(",\"arguments\":");
                try w.print("{f}", .{std.json.fmt(tc.args, .{})});
                try w.writeAll("}}");
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");

        // Execute all tool calls
        if (response.tool_calls.len == 0) {
            const pseudo_tool = tool_routing.hasPseudoToolCallText(response.text);
            if (no_tool_retries < 2) {
                no_tool_retries += 1;
                if (pseudo_tool) {
                    try stdout.print("{s}Stop:{s} model returned pseudo tool text (Tool: ...); requesting strict tool-call format.\n", .{ display.C_DIM, display.C_RESET });
                } else {
                    try stdout.print("{s}Stop:{s} model returned no tool call; requesting required tool-call format.\n", .{ display.C_DIM, display.C_RESET });
                }
                try w.writeAll(",{\"role\":\"user\",\"content\":");
                if (pseudo_tool) {
                    try w.print(
                        "{f}",
                        .{std.json.fmt("Do not output pseudo calls like 'Tool: bash {...}'. Return an actual tool call only via the function-call interface. If done, call respond_text.", .{})},
                    );
                } else {
                    try w.print(
                        "{f}",
                        .{std.json.fmt("Return at least one tool call via the function-call interface. If you are ready to answer finally, call respond_text with {\"text\":\"...\"}. Do not reply with plain text outside tool calls.", .{})},
                    );
                }
                try w.writeAll("}");
                continue;
            }
            const finish_reason = if (response.finish_reason.len > 0) response.finish_reason else "none";
            try stdout.print("{s}Stop:{s} model failed protocol: no tool call after retries (finish_reason={s}).\n", .{ display.C_DIM, display.C_RESET, finish_reason });
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
                last_tool_name = try allocator.dupe(u8, tc.tool);
                last_tool_args = try allocator.dupe(u8, tc.args);
            }

            const is_bash = std.mem.eql(u8, tc.tool, "bash");
            const repeat_threshold: usize = if (is_bash) 1 else 3;
            if (repeated_tool_calls >= repeat_threshold) {
                try stdout.print("{s}Note:{s} repeated identical tool call detected; requesting a different next action.\n", .{ display.C_DIM, display.C_RESET });
                // Important: always "answer" tool calls in the transcript. If we reject a tool call
                // without adding a tool-result message, the conversation ends up with unresolved
                // tool calls and models tend to spin repeating the same action.
                try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                try w.writeAll(",\"content\":");
                try w.print(
                    "{f}",
                    .{std.json.fmt("Tool call rejected: repeated identical tool call. Reuse the previous result and choose a different next action (or finish with respond_text).", .{})},
                );
                try w.writeAll("}");

                if (is_bash) {
                    rejected_repeated_bash += 1;
                } else {
                    rejected_repeated_other += 1;
                }

                // If the model repeats the same bash command even after rejection, it's effectively stuck.
                // Stop early instead of burning the full iteration budget.
                if (rejected_repeated_bash >= 2 or rejected_repeated_other >= 6) {
                    try stdout.print("{s}Stop:{s} model is stuck repeating the same tool call.\n", .{ display.C_DIM, display.C_RESET });
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

            // Guardrail: if we don't have a concrete target file, don't let the model "blind read" files
            // before a search. This is the main cause of read-spam on repo questions.
            if (tools.isReadToolName(tc.tool) and !has_searched and !allow_read_first) {
                try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                try w.writeAll(",\"content\":");
                try w.print(
                    "{f}",
                    .{std.json.fmt("Tool call rejected: run bash with rg to locate the right files/symbols first. Do not read files until after you have search results (unless the user provided an explicit file path).", .{})},
                );
                try w.writeAll("}");
                continue;
            }

            if (std.mem.eql(u8, tc.tool, "subagent_spawn") and subagent_manager != null) {
                const A = struct {
                    type: ?[]const u8 = null,
                    description: ?[]const u8 = null,
                    context: ?[]const u8 = null,
                };
                var p = std.json.parseFromSlice(A, allocator, tc.args, .{ .ignore_unknown_fields = true }) catch {
                    try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                    try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                    try w.writeAll(",\"content\":");
                    try w.print("{f}", .{std.json.fmt("{\"error\":\"InvalidArguments\"}", .{})});
                    try w.writeAll("}");
                    continue;
                };
                defer p.deinit();

                const task_type_str = p.value.type orelse "coder";
                const task_type = subagent.parseSubagentType(task_type_str) orelse subagent.SubagentType.coder;
                const desc = p.value.description orelse "subagent task";

                const id = subagent_manager.?.createTask(task_type, desc, p.value.context) catch |err| {
                    const msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"Failed to create subagent task: {s}\"}}", .{@errorName(err)});
                    defer allocator.free(msg);
                    try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                    try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                    try w.writeAll(",\"content\":");
                    try w.print("{f}", .{std.json.fmt(msg, .{})});
                    try w.writeAll("}");
                    continue;
                };

                const args_ptr = std.heap.page_allocator.create(SubagentThreadArgs) catch null;
                if (args_ptr == null) {
                    const msg = "{\"error\":\"Failed to allocate subagent runner\"}";
                    try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                    try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                    try w.writeAll(",\"content\":");
                    try w.print("{f}", .{std.json.fmt(msg, .{})});
                    try w.writeAll("}");
                    continue;
                }

                const id_owned = std.heap.page_allocator.dupe(u8, id) catch null;
                const desc_owned = std.heap.page_allocator.dupe(u8, desc) catch null;
                const ctx_owned = if (p.value.context) |c| std.heap.page_allocator.dupe(u8, c) catch null else null;
                const prov_owned = std.heap.page_allocator.dupe(u8, active.provider_id) catch null;
                const model_owned = std.heap.page_allocator.dupe(u8, active.model_id) catch null;
                const key_owned = if (active.api_key) |k| std.heap.page_allocator.dupe(u8, k) catch null else null;
                const effort_owned = if (active.reasoning_effort) |e| std.heap.page_allocator.dupe(u8, e) catch null else null;

                if (id_owned == null or desc_owned == null or prov_owned == null or model_owned == null) {
                    if (id_owned) |v| std.heap.page_allocator.free(v);
                    if (desc_owned) |v| std.heap.page_allocator.free(v);
                    if (ctx_owned) |v| std.heap.page_allocator.free(v);
                    if (prov_owned) |v| std.heap.page_allocator.free(v);
                    if (model_owned) |v| std.heap.page_allocator.free(v);
                    if (key_owned) |v| std.heap.page_allocator.free(v);
                    if (effort_owned) |v| std.heap.page_allocator.free(v);
                    std.heap.page_allocator.destroy(args_ptr.?);
                    const msg = "{\"error\":\"Failed to allocate subagent strings\"}";
                    try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                    try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                    try w.writeAll(",\"content\":");
                    try w.print("{f}", .{std.json.fmt(msg, .{})});
                    try w.writeAll("}");
                    continue;
                }

                args_ptr.?.* = .{
                    .manager = subagent_manager.?,
                    .id = id_owned.?,
                    .task_type = task_type,
                    .description = desc_owned.?,
                    .parent_context = ctx_owned,
                    .active = .{
                        .provider_id = prov_owned.?,
                        .model_id = model_owned.?,
                        .api_key = key_owned,
                        .reasoning_effort = effort_owned,
                    },
                };

                const th = std.Thread.spawn(.{}, subagentThreadMain, .{args_ptr.?}) catch |err| {
                    args_ptr.?.deinit(std.heap.page_allocator);
                    std.heap.page_allocator.destroy(args_ptr.?);
                    const msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"Failed to start subagent thread: {s}\"}}", .{@errorName(err)});
                    defer allocator.free(msg);
                    try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                    try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                    try w.writeAll(",\"content\":");
                    try w.print("{f}", .{std.json.fmt(msg, .{})});
                    try w.writeAll("}");
                    continue;
                };
                th.detach();

                try stdout.print("• subagent {s} {s}\n", .{ task_type_str, id });

                const sys_prompt = subagent.SubagentManager.getSystemPrompt(task_type);
                const out = try std.fmt.allocPrint(
                    allocator,
                    "{{\"id\":\"{s}\",\"status\":\"running\",\"type\":\"{s}\",\"system_prompt\":{f}}}",
                    .{ id, task_type_str, std.json.fmt(sys_prompt, .{}) },
                );
                defer allocator.free(out);

                try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                try w.writeAll(",\"content\":");
                try w.print("{f}", .{std.json.fmt(out, .{})});
                try w.writeAll("}");
                continue;
            }

            // Compact tool output
            if (std.mem.eql(u8, tc.tool, "bash")) {
                if (tools.parseBashCommandFromArgs(allocator, tc.args)) |cmd| {
                    defer allocator.free(cmd);
                    const c = std.mem.trim(u8, cmd, " \t\r\n");
                    const is_rg = std.mem.eql(u8, c, "rg") or std.mem.startsWith(u8, c, "rg ");
                    if (is_rg) {
                        try stdout.print("• Search {s}\n", .{cmd});
                    } else {
                        try stdout.print("• Ran {s}\n", .{cmd});
                    }
                    if (is_rg) has_searched = true;
                } else {
                    try stdout.print("• Ran {s}\n", .{tc.tool});
                }
            } else if (tools.parsePrimaryPathFromArgs(allocator, tc.args)) |path| {
                defer allocator.free(path);
                if (std.mem.eql(u8, tc.tool, "read") or std.mem.eql(u8, tc.tool, "read_file")) {
                    if (try tools.parseReadParamsFromArgs(allocator, tc.args)) |params| {
                        if (params.offset) |off| {
                            try stdout.print("• {s} {s} [{d}:{d}]\n", .{ tc.tool, path, off, params.limit orelse 0 });
                        } else {
                            try stdout.print("• {s} {s}\n", .{ tc.tool, path });
                        }
                    } else {
                        try stdout.print("• {s} {s}\n", .{ tc.tool, path });
                    }
                } else {
                    try stdout.print("• {s} {s}\n", .{ tc.tool, path });
                }
            } else {
                try stdout.print("• {s}\n", .{tc.tool});
            }

            if (std.mem.eql(u8, tc.tool, "respond_text")) {
                if (mutation_request and mutating_tools_executed == 0) {
                    try stdout.print("{s}Stop:{s} respond_text rejected: edit request requires at least one mutating tool execution first.\n", .{ display.C_DIM, display.C_RESET });
                    try w.writeAll(",{\"role\":\"user\",\"content\":");
                    try w.print(
                        "{f}",
                        .{std.json.fmt("You must run at least one mutating tool (write_file/replace_in_file/edit/write/apply_patch) before respond_text for this request.", .{})},
                    );
                    try w.writeAll("}");
                    continue;
                }
                const final_text = tools.executeNamed(allocator, tc.tool, tc.args, todo_list, subagent_manager) catch |err| {
                    try stdout.print("{s}  error: {s}{s}\n", .{ display.C_RED, @errorName(err), display.C_RESET });
                    return .{
                        .response = try allocator.dupe(u8, "respond_text arguments were invalid."),
                        .reasoning = try allocator.dupe(u8, response.reasoning),
                        .tool_calls = tool_calls,
                        .error_count = 1,
                        .files_touched = try utils.joinPaths(allocator, paths.items),
                    };
                };
                return .{
                    .response = final_text,
                    .reasoning = try allocator.dupe(u8, response.reasoning),
                    .tool_calls = tool_calls,
                    .error_count = 0,
                    .files_touched = try utils.joinPaths(allocator, paths.items),
                };
            }
            if (tools.isMutatingToolName(tc.tool)) mutating_tools_executed += 1;

            const result = tools.executeNamed(allocator, tc.tool, tc.args, todo_list, subagent_manager) catch |err| {
                try stdout.print("{s}  error: {s}{s}\n", .{ display.C_RED, @errorName(err), display.C_RESET });
                const err_msg = try std.fmt.allocPrint(allocator, "Tool {s} failed: {s}", .{ tc.tool, @errorName(err) });
                defer allocator.free(err_msg);

                try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
                try w.print("{f}", .{std.json.fmt(tc.id, .{})});
                try w.writeAll(",\"content\":");
                try w.print("{f}", .{std.json.fmt(err_msg, .{})});
                try w.writeAll("}");
                continue;
            };
            defer allocator.free(result);

            // Don't print file contents for reads. Keep output compact; the model still gets the
            // full content via the tool-result message in the transcript.
            if (!tools.isReadToolName(tc.tool) and result.len > 0) {
                if (std.mem.eql(u8, tc.tool, "bash")) {
                    try display.printTruncatedCommandOutput(stdout, result);
                    // Tool result is still added to the transcript below.
                } else {
                    var it = std.mem.splitScalar(u8, result, '\n');
                    while (it.next()) |line| {
                        if (line.len == 0) continue;
                        try stdout.print("  {s}{s}{s}\n", .{ display.C_GREY, line, display.C_RESET });
                    }
                }
            }

            // Add tool result to history
            try w.writeAll(",{\"role\":\"tool\",\"tool_call_id\":");
            try w.print("{f}", .{std.json.fmt(tc.id, .{})});
            try w.writeAll(",\"content\":");
            try w.print("{f}", .{std.json.fmt(result, .{})});
            try w.writeAll("}");

            // Optimization: if the model keeps running rg with no matches, nudge it to stop burning steps.
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
                                    try w.writeAll(",{\"role\":\"user\",\"content\":");
                                    try w.print(
                                        "{f}",
                                        .{std.json.fmt("rg returned no matches multiple times. Do not keep varying the pattern. Instead, inspect likely files (e.g. list src/, open README/config), or ask the user for the exact symbol/file to change.", .{})},
                                    );
                                    try w.writeAll("}");
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

            // Track paths
            if (tools.parsePrimaryPathFromArgs(allocator, tc.args)) |p| {
                if (!utils.containsPath(paths.items, p)) {
                    try paths.append(allocator, p);
                } else {
                    allocator.free(p);
                }
            }
        }
    }

    try stdout.print("{s}Stop:{s} reached maximum step limit ({d}).\n", .{ display.C_DIM, display.C_RESET, max_iterations });
    return .{
        .response = try allocator.dupe(u8, "Reached maximum iterations. Task may be incomplete."),
        .reasoning = try allocator.dupe(u8, ""),
        .tool_calls = tool_calls,
        .error_count = 0,
        .files_touched = try utils.joinPaths(allocator, paths.items),
    };
}

pub fn executeInlineToolCalls(
    allocator: std.mem.Allocator,
    stdout: anytype,
    response: []const u8,
    paths: *std.ArrayList([]u8),
    tool_calls: *usize,
    todo_list: *todo.TodoList,
    subagent_manager: ?*subagent.SubagentManager,
) !?[]u8 {
    var result_buf: std.ArrayList(u8) = .empty;
    defer result_buf.deinit(allocator);

    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "TOOL_CALL ")) continue;

        // Parse: TOOL_CALL name args
        const after_prefix = trimmed[10..]; // Skip "TOOL_CALL "
        const space_idx = std.mem.indexOfScalar(u8, after_prefix, ' ') orelse continue;
        const tool_name = after_prefix[0..space_idx];
        const args = std.mem.trim(u8, after_prefix[space_idx..], " \t");

        if (!tools.isKnownToolName(tool_name)) continue;

        tool_calls.* += 1;

        // Track path
        if (tools.parsePrimaryPathFromArgs(allocator, args)) |p| {
            var found = false;
            for (paths.items) |existing| {
                if (std.mem.eql(u8, existing, p)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try paths.append(allocator, p);
            } else {
                allocator.free(p);
            }
        }

        // Extract file path, bash command, or read params from args for display
        const file_path = tools.parsePrimaryPathFromArgs(allocator, args);
        defer if (file_path) |fp| allocator.free(fp);
        const bash_cmd = if (std.mem.eql(u8, tool_name, "bash"))
            tools.parseBashCommandFromArgs(allocator, args)
        else
            null;
        defer if (bash_cmd) |bc| allocator.free(bc);
        const read_params = if (std.mem.eql(u8, tool_name, "read") or std.mem.eql(u8, tool_name, "read_file"))
            try tools.parseReadParamsFromArgs(allocator, args)
        else
            null;

        // Execute tool
        try stdout.print("• {s}", .{tool_name});
        if (file_path) |fp| {
            try stdout.print(" {s}file={s}{s}", .{ display.C_CYAN, fp, display.C_RESET });
        }
        if (bash_cmd) |bc| {
            // Truncate long commands
            const max_cmd_len = 60;
            const display_cmd = if (bc.len > max_cmd_len) bc[0..max_cmd_len] else bc;
            const suffix = if (bc.len > max_cmd_len) "..." else "";
            try stdout.print(" {s}cmd=\"{s}{s}\"{s}", .{ display.C_CYAN, display_cmd, suffix, display.C_RESET });
        }
        if (read_params) |rp| {
            if (rp.offset) |off| {
                try stdout.print(" {s}offset={d}{s}", .{ display.C_DIM, off, display.C_RESET });
            }
            if (rp.limit) |lim| {
                try stdout.print(" {s}limit={d}{s}", .{ display.C_DIM, lim, display.C_RESET });
            }
        }
        try stdout.print("\n", .{});

        const tool_out = tools.executeNamed(allocator, tool_name, args, todo_list, subagent_manager) catch |err| {
            try result_buf.writer(allocator).print("Tool {s} failed: {s}\n", .{ tool_name, @errorName(err) });
            continue;
        };
        defer allocator.free(tool_out);

        // For mutating tools, print diff to stdout for user visibility
        if (tools.isMutatingToolName(tool_name)) {
            try stdout.print("{s}\n", .{tool_out});
        }

        try result_buf.writer(allocator).print("Tool {s} result:\n{s}\n", .{ tool_name, tool_out });
    }

    if (result_buf.items.len == 0) return null;
    const value = try result_buf.toOwnedSlice(allocator);
    return @as(?[]u8, value);
}

const SubagentThreadArgs = struct {
    manager: *subagent.SubagentManager,
    id: []u8,
    task_type: subagent.SubagentType,
    description: []u8,
    parent_context: ?[]u8,
    active: active_module.ActiveModel,

    fn deinit(self: *SubagentThreadArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        if (self.parent_context) |c| allocator.free(c);
        allocator.free(self.active.provider_id);
        allocator.free(self.active.model_id);
        if (self.active.api_key) |k| allocator.free(k);
        if (self.active.reasoning_effort) |e| allocator.free(e);
    }
};

fn buildSubagentSystemPrompt(allocator: std.mem.Allocator, task_type: subagent.SubagentType) ![]u8 {
    const base = subagent.SubagentManager.getSystemPrompt(task_type);
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\nUse the function-call tool interface for any tool usage. Prefer bash+rg before reading files unless the user gave an explicit path. Read using explicit offset+limit. Avoid repeating identical tool calls. Finish by calling respond_text.",
        .{base},
    );
}

fn subagentThreadMain(args_ptr: *SubagentThreadArgs) void {
    const allocator = std.heap.page_allocator;
    defer {
        args_ptr.deinit(allocator);
        allocator.destroy(args_ptr);
    }
    const args = args_ptr.*;

    // Mark running ASAP.
    _ = args.manager.updateStatus(args.id, .running);

    var todo_list = todo.TodoList.init(allocator);
    defer todo_list.deinit();
    if (todo_list.add(args.description)) |new_id| {
        _ = todo_list.update(new_id, .in_progress) catch {};
    } else |_| {}

    const sys_prompt = buildSubagentSystemPrompt(allocator, args.task_type) catch null;
    defer if (sys_prompt) |s| allocator.free(s);

    const input = blk: {
        if (args.parent_context) |ctx| {
            break :blk std.fmt.allocPrint(
                allocator,
                "Subagent task:\n{s}\n\nParent context:\n{s}",
                .{ args.description, ctx },
            ) catch null;
        }
        break :blk allocator.dupe(u8, args.description) catch null;
    };
    defer if (input) |s| allocator.free(s);

    const NullOut = struct {
        pub fn writeAll(_: *@This(), _: []const u8) !void {}
        pub fn print(_: *@This(), comptime _: []const u8, _: anytype) !void {}
    };
    var out = NullOut{};

    if (input == null) {
        _ = args.manager.setError(args.id, "subagent: failed to allocate input") catch {};
        _ = args.manager.updateStatus(args.id, .failed);
        return;
    }

    var result = runModel(
        allocator,
        &out,
        args.active,
        args.description,
        input.?,
        false,
        &todo_list,
        null,
        sys_prompt,
    ) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "subagent: run failed: {s}", .{@errorName(err)}) catch null;
        if (msg) |m| {
            defer allocator.free(m);
            _ = args.manager.setError(args.id, m) catch {};
        } else {
            _ = args.manager.setError(args.id, "subagent: run failed") catch {};
        }
        _ = args.manager.updateStatus(args.id, .failed);
        return;
    };
    defer result.deinit(allocator);

    if (result.error_count == 0) {
        _ = args.manager.setResult(args.id, result.response, result.tool_calls) catch {};
        _ = args.manager.updateStatus(args.id, .completed);
    } else {
        _ = args.manager.setError(args.id, result.response) catch {};
        _ = args.manager.updateStatus(args.id, .failed);
    }
}
