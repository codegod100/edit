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

const ArtifactSnapshot = struct {
    path: []u8,
    content: []u8,
};

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
        var buf: [4096]u8 = undefined;
        // Use fmt ++ "\n" to ensure a newline is always present
        const text = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
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
    // Web and other entry points can inherit a stale global cancel flag.
    // Always start each model turn from a clean cancellation state.
    cancel.resetCancelled();
    cancel.beginProcessing();

    // Use an arena for the entire turn to simplify memory management
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    try logger.transcriptWrite("\n>>> User: {s}\n", .{user_input});

    const mutation_request = tool_routing.isLikelyFileMutationRequest(raw_user_request);
    const skill_request = isSkillCreationRequest(raw_user_request);
    const objective_request = isObjectiveMetricsRequest(raw_user_request);
    var required_output_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer required_output_paths.deinit(arena_alloc);
    try collectRequiredOutputPaths(arena_alloc, raw_user_request, &required_output_paths);
    var mutating_tools_executed: usize = 0;
    var ran_verification_since_mutation = false;
    var saw_tool_error = false;
    var perf_threshold_active = false;
    var perf_fix_edit_made = false;
    var perf_fix_rechecked = false;
    var perf_close_miss_active = false;
    var perf_close_miss_gap_percent: f64 = 0.0;
    var correctness_failure_active = false;
    var correctness_fix_edit_made = false;
    var correctness_fix_rechecked = false;
    var latest_verification_has_metrics = false;
    var latest_verification_had_failure = false;
    var latest_verification_metric_snapshot: []const u8 = "";
    var best_single_gap_percent: ?f64 = null;
    var perf_metric_regressed = false;
    var perf_metric_regression_percent: f64 = 0.0;
    var single_numeric_threshold_active = false;
    var last_single_gap_percent: ?f64 = null;
    var single_metric_no_improve_cycles: usize = 0;
    var single_metric_extra_extension_used = false;
    var objective_drift_notice_sent = false;
    var golden_verify_seen = false;
    var objective_needs_golden_verify = false;
    var objective_golden_prompt_sent = false;
    var objective_script_write_count: usize = 0;
    var latest_correctness_failure_snapshot: []const u8 = "";
    var invariant_check_seen = false;
    var objective_needs_invariant_check = false;
    var objective_invariant_prompt_sent = false;
    var correctness_was_clean_once = false;
    var correctness_regressed = false;
    var artifact_prompt_sent = false;
    var best_verification_score: f64 = 1.0e30;
    var has_best_artifact_snapshot = false;
    var best_artifact_snapshots: std.ArrayListUnmanaged(ArtifactSnapshot) = .empty;
    defer {
        for (best_artifact_snapshots.items) |it| {
            allocator.free(it.path);
            allocator.free(it.content);
        }
        best_artifact_snapshots.deinit(allocator);
    }

    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    defer paths.deinit(arena_alloc);
    // Note: paths items are allocated from arena, so no need to free individually

    var w: std.ArrayListUnmanaged(u8) = .empty;
    defer w.deinit(arena_alloc);

    const system_prompt = custom_system_prompt orelse "You are a highly capable software engineering assistant. Your goal is to help the user with their task efficiently and accurately.\n\n" ++
        "1. **Analyze First**: Before making changes, use `grep` and `read_file` to understand the existing codebase, architectural patterns, and naming conventions. Mimic the style and structure of the project.\n" ++
        "2. **Plan & Update**: Use `todo_*` tools only when the user asks for explicit planning or the task is genuinely complex. Avoid plan spam; focus on doing the work.\n" ++
        "3. **Be Precise**: When editing files, provide exact matches for `find` or `oldString`. Avoid introducing redundant or messy code. If you notice a pattern (like provider IDs), follow it strictly.\n" ++
        "4. **Tools & Output**: Use `bash` with `rg` for searching. Read files with `offset` and `limit`. Never scan the entire filesystem (`find /`, recursive `/` searches). Stay in the project/task workspace. You will receive tool outputs with ANSI colors removed for clarity. Always verify your changes if possible.\n" ++
        "5. **Skill Requests**: If user asks to create a skill, you must create a `SKILL.md` file under `.zagent/skills/<skill-name>/SKILL.md` (project-local) or `skills/<skill-name>/SKILL.md` in config. Do not create language/source files instead of `SKILL.md`.\n" ++
        "6. **Start in Task Root**: First inspect the current working directory and likely task roots (for example `/app/task_file` when present) before broad discovery.\n" ++
        "7. **Numeric Targets**: When tests expose numeric thresholds (cost/latency/percent), extract the failing metric, perform a focused optimization edit, then re-run the failing check(s) before finishing.\n" ++
        "8. **Finish Cleanly**: Once the task is complete, provide a concise summary of your actions via `respond_text`.";

    // Build messages array
    if (std.mem.startsWith(u8, user_input, "[") and std.mem.endsWith(u8, user_input, "]")) {
        // user_input is already a JSON array of messages (likely from context.buildContextMessagesJson)
        // We take it but remove the trailing ']' because the loop expects to append more turns
        try w.appendSlice(arena_alloc, user_input[0 .. user_input.len - 1]);
    } else {
        try w.appendSlice(arena_alloc, "[");

        try w.writer(arena_alloc).print(
            "{{\"role\":\"system\",\"content\":{f}}},",
            .{std.json.fmt(system_prompt, .{})},
        );

        try w.writer(arena_alloc).print(
            "{{\"role\":\"user\",\"content\":{f}}}",
            .{std.json.fmt(user_input, .{})},
        );
    }

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

    var max_iterations: usize = if (objective_request) 50 else 35;
    var adaptive_extensions_used: usize = 0;
    const max_adaptive_extensions: usize = 2;
    var stagnant_iterations: usize = 0;
    var prev_paths_len: usize = 0;
    var prev_mutating_tools_executed: usize = 0;
    var prev_perf_fix_rechecked = false;
    var prev_correctness_fix_rechecked = false;
    var iter: usize = 0;

    while (iter < max_iterations) : (iter += 1) {
        if (iter == 0 and skill_request) {
            try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
            try w.writer(arena_alloc).print(
                "{f}",
                .{std.json.fmt("This is a skill-creation task. Create a `SKILL.md` file under `.zagent/skills/<skill-name>/SKILL.md` (project-local) or `skills/<skill-name>/SKILL.md` in config. Do not create a language demo/source file as a substitute.", .{})},
            );
            try w.appendSlice(arena_alloc, "}");
        }

        // Keep loop behavior simple; avoid enforcing plan tooling.

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
        if (response.reasoning.len > 0) {
            const trimmed_reasoning = std.mem.trim(u8, response.reasoning, " \t\r\n");
            if (trimmed_reasoning.len > 0) {
                try logger.transcriptWrite("\n[Reasoning]\n{s}\n", .{trimmed_reasoning});
                display.addTimelineEntry("{s}--- Thinking ---{s}\n", .{ display.C_THINKING, display.C_RESET });
                display.addWrappedTimelineEntry(display.C_REASONING_BG ++ display.C_REASONING_FG, trimmed_reasoning, display.C_RESET);
                display.addTimelineEntry("{s}\n", .{display.C_RESET});
            }
        }

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
                try logger.transcriptWrite("\n<<< Assistant: {s}\n", .{response.text});
                try display.addAssistantMessage(allocator, response.text);
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

        // BATCH TOOL EXECUTION: Process all tool calls in parallel (sequentially in code, but in one turn)
        var turn_results: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (turn_results.items) |r| arena_alloc.free(r);
            turn_results.deinit(arena_alloc);
        }

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
                const msg = "Tool call rejected: repeated identical tool call. Reuse the previous result and choose a different next action (or finish with respond_text).";
                try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));

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

            try logger.transcriptWrite("\n[Tool Call] {s}({s})\n", .{ tc.tool, tc.args });

            if (std.mem.eql(u8, tc.tool, "subagent_spawn")) {
                const msg = "{\"error\":\"Subagent support has been removed\"}";
                try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                continue;
            }

            // Update spinner state based on tool type
            if (std.mem.eql(u8, tc.tool, "bash")) {
                if (tools.parseBashCommandFromArgs(allocator, tc.args)) |cmd| {
                    defer allocator.free(cmd);
                    const c = std.mem.trim(u8, cmd, " \t\r\n");
                    const is_rg = std.mem.eql(u8, c, "rg") or std.mem.startsWith(u8, c, "rg ");
                    const display_cmd = if (cmd.len > 60) cmd[0..60] else cmd;
                    if (is_rg) {
                        display.setSpinnerStateWithText(.search, display_cmd);
                        toolOutput("• Search {s}", .{cmd});
                    } else {
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
                    display.setSpinnerState(.reading);
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
                    display.setSpinnerState(.writing);
                    toolOutput("• {s} {s}", .{ tc.tool, path });
                }
            } else if (std.mem.eql(u8, tc.tool, "respond_text")) {
                display.setSpinnerState(.thinking);
                toolOutput("• respond_text", .{});
            } else {
                display.setSpinnerState(.tool);
                toolOutput("• {s}", .{tc.tool});
            }

            if (std.mem.eql(u8, tc.tool, "respond_text")) {
                if (skill_request and !pathsContainSkillFile(paths.items)) {
                    toolOutput("{s}Note:{s} skill request not satisfied yet; missing SKILL.md output.", .{ display.C_YELLOW, display.C_RESET });
                    const msg = "You are handling a skill-creation request. Before finishing, create a `SKILL.md` file under `.zagent/skills/<skill-name>/SKILL.md` (or config `skills/<skill-name>/SKILL.md`). Do not return a source-code demo file in place of a skill.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (mutation_request and mutating_tools_executed == 0) {
                    toolOutput("{s}Note:{s} request seems to require a file change, but no mutating tools were run.", .{ display.C_YELLOW, display.C_RESET });
                    const msg = "Your plan mentioned a file change, but you haven't executed any mutating tools (like write_file, edit, etc.) yet. Please execute the necessary tools to apply the changes before calling respond_text. If no change is actually needed, please explain why.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (mutation_request and mutating_tools_executed > 0 and !ran_verification_since_mutation) {
                    toolOutput("{s}Note:{s} run at least one verification/check command after edits before finishing.", .{ display.C_YELLOW, display.C_RESET });
                    const msg = "You made edits but have not run a verification/check command yet. Run a quick local check (tests/build/lint/smoke command) before calling respond_text.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (saw_tool_error) {
                    toolOutput("{s}Note:{s} recent tool errors detected; resolve or explain before finishing.", .{ display.C_YELLOW, display.C_RESET });
                    const msg = "Recent tool execution reported errors. Resolve the errors (or explain why they are non-blocking) before calling respond_text.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (correctness_failure_active and !correctness_fix_edit_made) {
                    const msg = "Verification shows correctness/feasibility failures. Make a focused correctness fix first (schema/shape/consistency), then re-run the failing correctness check.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (correctness_failure_active and correctness_fix_edit_made and !correctness_fix_rechecked) {
                    const msg = "You edited for correctness, but have not re-run the failing correctness check yet. Re-run it before finishing.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (correctness_failure_active and latest_verification_had_failure) {
                    const msg = "Correctness is still failing. Do not continue optimization yet; fix correctness failures first, then verify again.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (perf_threshold_active and !perf_fix_edit_made) {
                    toolOutput("{s}Note:{s} threshold failure is still active; perform a focused optimization edit first.", .{ display.C_YELLOW, display.C_RESET });
                    const msg = "A numeric threshold/performance failure was detected. Make a focused optimization edit before finishing.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (perf_threshold_active and perf_fix_edit_made and !perf_fix_rechecked) {
                    toolOutput("{s}Note:{s} threshold fix not rechecked yet; run the failing check(s) before finishing.", .{ display.C_YELLOW, display.C_RESET });
                    const msg = "You edited for a threshold failure but have not re-run the failing check(s). Re-run targeted failing tests/metrics before finishing.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (perf_close_miss_active and perf_threshold_active and perf_fix_rechecked) {
                    toolOutput("{s}Note:{s} still within close-miss range ({d:.2}%). Do one more focused optimization + recheck before finishing.", .{ display.C_YELLOW, display.C_RESET, perf_close_miss_gap_percent });
                    const msg = try std.fmt.allocPrint(arena_alloc, "Single numeric threshold miss remains ({d:.2}% over target). Perform one more minimal targeted optimization and re-run the failing check before finishing.", .{perf_close_miss_gap_percent});
                    try turn_results.append(arena_alloc, msg);
                    continue;
                }
                if (objective_request and mutating_tools_executed > 0 and !latest_verification_has_metrics) {
                    const msg = "Objective/threshold task detected, but no metric snapshot was found in verification output yet. Re-run a targeted evaluator/test command and capture current numeric metrics before finishing.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (objective_request and mutating_tools_executed > 0 and !golden_verify_seen) {
                    const msg = "Objective task requires at least one definitive verifier run (e.g., pytest/verify script) after edits. Run it before finishing.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (objective_request and required_output_paths.items.len > 0 and !requiredArtifactsExistPaths(required_output_paths.items)) {
                    const msg = "Required output artifacts mentioned in the prompt are missing. Create/update them before finishing.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (objective_request and mutating_tools_executed > 0 and !invariant_check_seen) {
                    const msg = "Objective task requires a structural invariant check after edits (e.g., shape/schema/consistency check). Run it before finishing.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (objective_request and latest_verification_has_metrics and latest_verification_had_failure) {
                    const msg = try std.fmt.allocPrint(arena_alloc, "Latest verification still shows failing objective metrics/tests: {s}. Continue focused optimization and recheck before finishing.", .{latest_verification_metric_snapshot});
                    try turn_results.append(arena_alloc, msg);
                    continue;
                }
                if (objective_request and single_numeric_threshold_active and last_single_gap_percent != null) {
                    const msg = try std.fmt.allocPrint(arena_alloc, "Single metric still failing. Include explicit best-known gap ({d:.2}% over target) and the next strategy in your update; do not finish yet.", .{last_single_gap_percent.?});
                    try turn_results.append(arena_alloc, msg);
                    continue;
                }
                if (objective_request and correctness_regressed) {
                    const msg = "Correctness regressed after a previously clean check. Revert/repair the recent change and rerun structural invariant checks before finishing.";
                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                    continue;
                }
                if (objective_request and perf_metric_regressed) {
                    const msg = try std.fmt.allocPrint(arena_alloc, "Metric regression detected (+{d:.2}% vs best known gap). Revert or adjust strategy, then rerun failing check before finishing.", .{perf_metric_regression_percent});
                    try turn_results.append(arena_alloc, msg);
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
                try display.addAssistantMessage(arena_alloc, final_text);
                return .{
                    .response = try allocator.dupe(u8, final_text),
                    .reasoning = try allocator.dupe(u8, response.reasoning),
                    .tool_calls = tool_calls,
                    .error_count = 0,
                    .files_touched = try utils.joinPaths(allocator, paths.items),
                };
            }
            if (tools.isMutatingToolName(tc.tool)) {
                if (objective_request and (std.mem.eql(u8, tc.tool, "write_file") or std.mem.eql(u8, tc.tool, "edit_file"))) {
                    if (tools.parsePrimaryPathFromArgs(arena_alloc, tc.args)) |pp| {
                        defer arena_alloc.free(pp);
                        const is_script = std.mem.indexOf(u8, pp, "/scripts/") != null or std.mem.startsWith(u8, pp, "scripts/");
                        if (is_script) {
                            if (single_numeric_threshold_active) {
                                const msg = "Single-metric optimization mode is active. Do not edit analysis scripts; edit the primary solution file directly and rerun verification.";
                                try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                                continue;
                            }
                            objective_script_write_count += 1;
                            if (objective_script_write_count > 2) {
                                const msg = "Too many script-file edits for an objective task. Stop adding analysis scripts and switch to direct solution-file edit -> definitive verify loops.";
                                try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                                continue;
                            }
                        }
                    }
                }
                mutating_tools_executed += 1;
                ran_verification_since_mutation = false;
                if (objective_request) {
                    objective_needs_golden_verify = true;
                    objective_golden_prompt_sent = false;
                    objective_needs_invariant_check = true;
                    objective_invariant_prompt_sent = false;
                }
                if (correctness_failure_active) {
                    correctness_fix_edit_made = true;
                    correctness_fix_rechecked = false;
                }
                if (perf_threshold_active) {
                    perf_fix_edit_made = true;
                    perf_fix_rechecked = false;
                }
            }

            if (std.mem.eql(u8, tc.tool, "bash")) {
                if (tools.parseBashCommandFromArgs(allocator, tc.args)) |cmd_raw| {
                    defer allocator.free(cmd_raw);
                    const cmd = std.mem.trim(u8, cmd_raw, " \t\r\n");
                    if (isGlobalFilesystemScanCommand(cmd)) {
                        const msg = "Rejected: global filesystem scan command. Stay within the project/task workspace and use targeted paths.";
                        try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                        continue;
                    }
                }
            }

            const result = tools.executeNamed(arena_alloc, tc.tool, tc.args, todo_list) catch |err| {
                toolOutput("{s}  error: {s}{s}", .{ display.C_RED, @errorName(err), display.C_RESET });
                saw_tool_error = true;
                const err_msg = try std.fmt.allocPrint(arena_alloc, "Tool {s} failed: {s}", .{ tc.tool, @errorName(err) });
                try turn_results.append(arena_alloc, err_msg);
                continue;
            };
            saw_tool_error = false;

            if (result.len > 0) {
                try display.printTruncatedCommandOutput(stdout, result);
            }

            const no_ansi = try display.stripAnsi(arena_alloc, result);
            defer arena_alloc.free(no_ansi);
            const clean_result = try utils.sanitizeTextForModel(arena_alloc, no_ansi, 128 * 1024);
            try logger.transcriptWrite("[Result]\n{s}\n", .{clean_result});
            try turn_results.append(arena_alloc, clean_result);
            arena_alloc.free(result);

            if (std.mem.eql(u8, tc.tool, "bash")) {
                const A = struct { command: ?[]const u8 = null };
                if (std.json.parseFromSlice(A, arena_alloc, tc.args, .{ .ignore_unknown_fields = true })) |p| {
                    if (p.value.command) |cmd_raw| {
                        const cmd = std.mem.trim(u8, cmd_raw, " \t\r\n");
                        const is_rg = std.mem.eql(u8, cmd, "rg") or std.mem.startsWith(u8, cmd, "rg ");
                        if (is_rg) {
                            const out_trimmed = std.mem.trim(u8, clean_result, " \t\r\n");
                            const effectively_empty = out_trimmed.len == 0 or std.mem.eql(u8, out_trimmed, "[exit 1]");
                            if (effectively_empty) {
                                consecutive_empty_rg += 1;
                            } else {
                                consecutive_empty_rg = 0;
                            }
                        } else {
                            consecutive_empty_rg = 0;
                        }
                        if (isLikelyVerificationCommand(cmd)) {
                            ran_verification_since_mutation = true;
                            if (isGoldenVerificationCommand(cmd)) {
                                golden_verify_seen = true;
                                objective_needs_golden_verify = false;
                            }
                            if (isInvariantVerificationCommand(cmd, clean_result)) {
                                invariant_check_seen = true;
                                objective_needs_invariant_check = false;
                            }
                            const insight = analyzeVerificationOutput(clean_result);
                            latest_verification_has_metrics = insight.has_metrics;
                            latest_verification_had_failure = insight.has_failure;
                            latest_verification_metric_snapshot = try buildMetricSnapshot(arena_alloc, clean_result);
                            if (looksLikeCorrectnessFailure(clean_result)) {
                                latest_correctness_failure_snapshot = try buildFailureSnapshot(arena_alloc, clean_result);
                                if (correctness_was_clean_once) correctness_regressed = true;
                                correctness_failure_active = true;
                                correctness_fix_edit_made = false;
                                correctness_fix_rechecked = false;
                                // Correctness failures invalidate optimization progress until fixed.
                                perf_threshold_active = false;
                                perf_fix_edit_made = false;
                                perf_fix_rechecked = false;
                                perf_close_miss_active = false;
                                perf_close_miss_gap_percent = 0.0;
                                const msg = try std.fmt.allocPrint(arena_alloc, "Correctness/feasibility failure detected: {s}. Fix this invariant first, then rerun the failing correctness check before optimization.", .{latest_correctness_failure_snapshot});
                                try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                            } else if (correctness_failure_active) {
                                correctness_fix_rechecked = true;
                                if (!looksLikeAnyFailure(clean_result)) {
                                    correctness_failure_active = false;
                                    correctness_fix_edit_made = false;
                                    correctness_fix_rechecked = false;
                                    latest_correctness_failure_snapshot = "";
                                    correctness_was_clean_once = true;
                                    correctness_regressed = false;
                                }
                            }
                            const threshold = analyzeThresholdFailure(clean_result);
                            if (!correctness_failure_active and threshold.detected) {
                                perf_threshold_active = true;
                                perf_fix_edit_made = false;
                                perf_fix_rechecked = false;
                                perf_close_miss_active = false;
                                perf_close_miss_gap_percent = 0.0;
                                single_numeric_threshold_active = threshold.single_numeric;
                                if (threshold.single_numeric and threshold.gap_percent != null and threshold.gap_percent.? <= 5.0) {
                                    perf_close_miss_active = true;
                                    perf_close_miss_gap_percent = threshold.gap_percent.?;
                                    const msg = try std.fmt.allocPrint(
                                        arena_alloc,
                                        "Single numeric threshold miss detected ({d:.2}% over target). Make one focused optimization edit, then rerun only the failing check.",
                                        .{perf_close_miss_gap_percent},
                                    );
                                    try turn_results.append(arena_alloc, msg);
                                    if (best_single_gap_percent == null or perf_close_miss_gap_percent < best_single_gap_percent.?) {
                                        best_single_gap_percent = perf_close_miss_gap_percent;
                                        perf_metric_regressed = false;
                                        perf_metric_regression_percent = 0.0;
                                    } else {
                                        const regression = perf_close_miss_gap_percent - best_single_gap_percent.?;
                                        perf_metric_regressed = regression > 0.25;
                                        perf_metric_regression_percent = if (best_single_gap_percent.? > 0.0) (regression / best_single_gap_percent.?) * 100.0 else 0.0;
                                        if (perf_metric_regressed) {
                                            const warn = try std.fmt.allocPrint(arena_alloc, "Current numeric gap regressed to {d:.2}% over target (best was {d:.2}%). Prefer a smaller, targeted edit and rerun.", .{ perf_close_miss_gap_percent, best_single_gap_percent.? });
                                            try turn_results.append(arena_alloc, warn);
                                        }
                                    }
                                } else {
                                    const msg = "Threshold/performance failure detected. Prioritize objective optimization, then rerun only failing checks.";
                                    try turn_results.append(arena_alloc, try arena_alloc.dupe(u8, msg));
                                }
                                if (threshold.single_numeric and threshold.gap_percent != null) {
                                    const current_gap = threshold.gap_percent.?;
                                    if (last_single_gap_percent == null or current_gap + 0.05 < last_single_gap_percent.?) {
                                        single_metric_no_improve_cycles = 0;
                                    } else {
                                        single_metric_no_improve_cycles += 1;
                                    }
                                    last_single_gap_percent = current_gap;
                                    if (single_metric_no_improve_cycles >= 2) {
                                        const msg = try std.fmt.allocPrint(
                                            arena_alloc,
                                            "Single-metric gap is not improving (current {d:.2}% over target). Change strategy now (different batching/shape tradeoff), then rerun the same failing check.",
                                            .{current_gap},
                                        );
                                        try turn_results.append(arena_alloc, msg);
                                    }
                                }
                            } else if (perf_threshold_active) {
                                perf_fix_rechecked = true;
                                if (!looksLikeAnyFailure(clean_result)) {
                                    perf_threshold_active = false;
                                    perf_fix_edit_made = false;
                                    perf_fix_rechecked = false;
                                    perf_close_miss_active = false;
                                    perf_close_miss_gap_percent = 0.0;
                                    perf_metric_regressed = false;
                                    perf_metric_regression_percent = 0.0;
                                    single_numeric_threshold_active = false;
                                    last_single_gap_percent = null;
                                    single_metric_no_improve_cycles = 0;
                                }
                            }

                            if (objective_request and required_output_paths.items.len > 0 and requiredArtifactsExistPaths(required_output_paths.items)) {
                                const score = verificationScore(clean_result);
                                if (score + 0.001 < best_verification_score) {
                                    try captureArtifactSnapshots(allocator, required_output_paths.items, &best_artifact_snapshots);
                                    best_verification_score = score;
                                    has_best_artifact_snapshot = true;
                                    toolOutput("{s}Note:{s} saved improved output snapshot (score {d:.2}).", .{ display.C_DIM, display.C_RESET, score });
                                }
                            }
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

        // Add all tool results to conversation
        for (response.tool_calls, 0..) |tc, i| {
            const clean_result = turn_results.items[i];

            try w.appendSlice(arena_alloc, ",{\"role\":\"tool\",\"tool_call_id\":");
            try w.writer(arena_alloc).print("{f}", .{std.json.fmt(tc.id, .{})});
            try w.appendSlice(arena_alloc, ",\"content\":");
            try w.writer(arena_alloc).print("{f}", .{std.json.fmt(clean_result, .{})});
            try w.appendSlice(arena_alloc, "}");

            if (consecutive_empty_rg >= 2 and i == response.tool_calls.len - 1) {
                try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
                try w.writer(arena_alloc).print(
                    "{f}",
                    .{std.json.fmt("rg returned no matches multiple times. Do not keep varying the pattern. Instead, inspect likely files (e.g. list src/, open README/config), or ask the user for the exact symbol/file to change.", .{})},
                );
                try w.appendSlice(arena_alloc, "}");
            }
        }

        // Progress-aware step control:
        // - extend a bit when signals indicate meaningful progress
        // - stop early when signals indicate we're stuck
        const progress_signal =
            (paths.items.len > prev_paths_len) or
            (mutating_tools_executed > prev_mutating_tools_executed) or
            (perf_fix_rechecked and !prev_perf_fix_rechecked) or
            (correctness_fix_rechecked and !prev_correctness_fix_rechecked);

        if (progress_signal) {
            stagnant_iterations = 0;
        } else {
            stagnant_iterations += 1;
        }

        prev_paths_len = paths.items.len;
        prev_mutating_tools_executed = mutating_tools_executed;
        prev_perf_fix_rechecked = perf_fix_rechecked;
        prev_correctness_fix_rechecked = correctness_fix_rechecked;

        if (iter >= 10 and stagnant_iterations >= 8) {
            if (objective_request and !correctness_failure_active and (perf_threshold_active or latest_verification_had_failure)) {
                try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
                try w.writer(arena_alloc).print(
                    "{f}",
                    .{std.json.fmt("Continue optimization despite slow progress. Apply one focused cost/latency improvement and rerun the failing threshold check.", .{})},
                );
                try w.appendSlice(arena_alloc, "}");
                stagnant_iterations = 0;
                continue;
            }
            if (objective_request) {
                stagnant_iterations = 0;
                try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
                try w.writer(arena_alloc).print(
                    "{f}",
                    .{std.json.fmt("Do not stop for stagnation on this objective task. Continue with focused edit -> verify loops until required outputs exist and checks pass.", .{})},
                );
                try w.appendSlice(arena_alloc, "}");
                continue;
            }
            if (objective_request and mutating_tools_executed > 0 and !objective_drift_notice_sent) {
                objective_drift_notice_sent = true;
                try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
                try w.writer(arena_alloc).print(
                    "{f}",
                    .{std.json.fmt("Avoid broad exploration. From now on, do tight edit -> targeted verify loops on the primary solution files and optimize the failing objective metric directly.", .{})},
                );
                try w.appendSlice(arena_alloc, "}");
            }
            const msg = "Stopping early: no meaningful progress in recent steps. Try a narrower instruction or different model.";
            toolOutput("{s}Stop:{s} {s}", .{ display.C_YELLOW, display.C_RESET, msg });
            return .{
                .response = try allocator.dupe(u8, msg),
                .reasoning = try allocator.dupe(u8, ""),
                .tool_calls = tool_calls,
                .error_count = 0,
                .files_touched = try utils.joinPaths(allocator, paths.items),
            };
        }

        const should_extend_for_completion =
            mutation_request and mutating_tools_executed > 0 and
            (!ran_verification_since_mutation or correctness_failure_active or perf_threshold_active or perf_close_miss_active);

        if (iter == max_iterations - 1 and adaptive_extensions_used < max_adaptive_extensions and (progress_signal or should_extend_for_completion)) {
            adaptive_extensions_used += 1;
            max_iterations += 10;
            toolOutput("{s}Note:{s} extending step budget to {d} for completion/verification.", .{ display.C_YELLOW, display.C_RESET, max_iterations });
            try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
            try w.writer(arena_alloc).print(
                "{f}",
                .{std.json.fmt("Continue with focused edits/checks and finish only after verification is complete.", .{})},
            );
            try w.appendSlice(arena_alloc, "}");
        }
        if (iter == max_iterations - 1 and objective_request and single_numeric_threshold_active and !single_metric_extra_extension_used) {
            single_metric_extra_extension_used = true;
            max_iterations += 20;
            toolOutput("{s}Note:{s} single-metric threshold mode active; granting one-time extension to {d} steps.", .{ display.C_YELLOW, display.C_RESET, max_iterations });
            try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
            try w.writer(arena_alloc).print(
                "{f}",
                .{std.json.fmt("One metric remains. Stay in direct solution-file optimization mode and rerun the same failing check until the gap closes.", .{})},
            );
            try w.appendSlice(arena_alloc, "}");
        }
        if (objective_request and objective_needs_golden_verify and !objective_golden_prompt_sent) {
            objective_golden_prompt_sent = true;
            try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
            try w.writer(arena_alloc).print(
                "{f}",
                .{std.json.fmt("Run a definitive verifier command now (e.g., pytest/verify script), then use its failing assertions to drive the next focused edit.", .{})},
            );
            try w.appendSlice(arena_alloc, "}");
        }
        if (objective_request and objective_needs_invariant_check and !objective_invariant_prompt_sent) {
            objective_invariant_prompt_sent = true;
            try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
            try w.writer(arena_alloc).print(
                "{f}",
                .{std.json.fmt("Run a structural invariant check now (shape/schema/consistency constraints). If it fails, repair those violations before further optimization.", .{})},
            );
            try w.appendSlice(arena_alloc, "}");
        }
        if (objective_request and !artifact_prompt_sent and required_output_paths.items.len > 0 and !requiredArtifactsExistPaths(required_output_paths.items)) {
            artifact_prompt_sent = true;
            try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
            try w.writer(arena_alloc).print(
                "{f}",
                .{std.json.fmt("Required outputs mentioned in the prompt are missing. Create/update those output files now, then run definitive verification.", .{})},
            );
            try w.appendSlice(arena_alloc, "}");
        }
        if (iter == max_iterations - 1 and adaptive_extensions_used < max_adaptive_extensions and perf_close_miss_active) {
            adaptive_extensions_used += 1;
            max_iterations += 10;
            toolOutput("{s}Note:{s} close threshold miss ({d:.2}%) near step limit; extending budget to {d} steps.", .{ display.C_YELLOW, display.C_RESET, perf_close_miss_gap_percent, max_iterations });
            try w.appendSlice(arena_alloc, ",{\"role\":\"user\",\"content\":");
            try w.writer(arena_alloc).print(
                "{f}",
                .{std.json.fmt("You are very close to passing numeric thresholds. Apply one small targeted optimization and rerun the failing check before finishing.", .{})},
            );
            try w.appendSlice(arena_alloc, "}");
        }
    }

    toolOutput("{s}Stop:{s} Step limit reached ({d}).", .{ display.C_RED, display.C_RESET, max_iterations });
    if (objective_request and has_best_artifact_snapshot) {
        restoreArtifactSnapshots(&best_artifact_snapshots) catch {};
        toolOutput("{s}Note:{s} restored best-known output snapshot before exiting.", .{ display.C_YELLOW, display.C_RESET });
    }
    const msg = "Task paused (max steps). Use 'continue' to resume or give new instructions.";
    toolOutput("{s}»{s} {s}", .{ display.C_RED, display.C_RESET, msg });

    return .{
        .response = try allocator.dupe(u8, msg),
        .reasoning = try allocator.dupe(u8, ""),
        .tool_calls = tool_calls,
        .error_count = 0,
        .files_touched = try utils.joinPaths(allocator, paths.items),
    };
}

fn pathsContainSkillFile(paths: []const []u8) bool {
    for (paths) |p| {
        if (std.mem.endsWith(u8, p, "/SKILL.md")) return true;
        if (std.mem.eql(u8, p, "SKILL.md")) return true;
        if (std.mem.indexOf(u8, p, ".zagent/skills/") != null and std.mem.endsWith(u8, p, "SKILL.md")) return true;
        if (std.mem.indexOf(u8, p, "/skills/") != null and std.mem.endsWith(u8, p, "SKILL.md")) return true;
    }
    return false;
}

fn isSkillCreationRequest(raw_user_request: []const u8) bool {
    const has_skill = utils.containsIgnoreCase(raw_user_request, "skill");
    const has_create_verb = utils.containsIgnoreCase(raw_user_request, "create") or
        utils.containsIgnoreCase(raw_user_request, "make") or
        utils.containsIgnoreCase(raw_user_request, "build") or
        utils.containsIgnoreCase(raw_user_request, "write");
    const has_explicit_path = utils.containsIgnoreCase(raw_user_request, "SKILL.md") or
        utils.containsIgnoreCase(raw_user_request, "/skills/");
    return (has_skill and has_create_verb) or has_explicit_path;
}

fn isGlobalFilesystemScanCommand(cmd: []const u8) bool {
    const c = std.mem.trim(u8, cmd, " \t\r\n");
    return std.mem.indexOf(u8, c, "find /") != null or
        std.mem.indexOf(u8, c, "find\t/") != null or
        std.mem.indexOf(u8, c, "ls -R /") != null or
        std.mem.indexOf(u8, c, "du -a /") != null or
        std.mem.indexOf(u8, c, "grep -R /") != null or
        std.mem.indexOf(u8, c, "rg / ") != null;
}

fn isLikelyVerificationCommand(cmd: []const u8) bool {
    const c = std.mem.trim(u8, cmd, " \t\r\n");
    return std.mem.indexOf(u8, c, " test") != null or
        std.mem.indexOf(u8, c, "pytest") != null or
        std.mem.indexOf(u8, c, "zig build") != null or
        std.mem.indexOf(u8, c, "zig test") != null or
        std.mem.indexOf(u8, c, "go test") != null or
        std.mem.indexOf(u8, c, "cargo test") != null or
        std.mem.indexOf(u8, c, "npm test") != null or
        std.mem.indexOf(u8, c, "pnpm test") != null or
        std.mem.indexOf(u8, c, "yarn test") != null or
        std.mem.indexOf(u8, c, "ruff check") != null or
        std.mem.indexOf(u8, c, "eslint") != null or
        std.mem.indexOf(u8, c, "tsc") != null or
        std.mem.indexOf(u8, c, "make") != null;
}

fn looksLikeThresholdFailure(out: []const u8) bool {
    return (utils.containsIgnoreCase(out, "threshold") and utils.containsIgnoreCase(out, "fail")) or
        (utils.containsIgnoreCase(out, "AssertionError") and utils.containsIgnoreCase(out, "cost")) or
        (utils.containsIgnoreCase(out, "AssertionError") and utils.containsIgnoreCase(out, "latency")) or
        (utils.containsIgnoreCase(out, "cost") and std.mem.indexOf(u8, out, " > ") != null);
}

fn looksLikeAnyFailure(out: []const u8) bool {
    return utils.containsIgnoreCase(out, "failed") or
        utils.containsIgnoreCase(out, "error") or
        utils.containsIgnoreCase(out, "assertionerror");
}

fn looksLikeCorrectnessFailure(out: []const u8) bool {
    return utils.containsIgnoreCase(out, "shape_feasibility") or
        utils.containsIgnoreCase(out, "batch_consistency") or
        (utils.containsIgnoreCase(out, "seq_align") and std.mem.indexOf(u8, out, " >= ") != null) or
        (utils.containsIgnoreCase(out, "schema") and utils.containsIgnoreCase(out, "fail")) or
        (utils.containsIgnoreCase(out, "feasibility") and utils.containsIgnoreCase(out, "fail")) or
        (utils.containsIgnoreCase(out, "coverage") and utils.containsIgnoreCase(out, "fail"));
}

fn isObjectiveMetricsRequest(raw_user_request: []const u8) bool {
    return utils.containsIgnoreCase(raw_user_request, "threshold") or
        utils.containsIgnoreCase(raw_user_request, "latency") or
        utils.containsIgnoreCase(raw_user_request, "cost") or
        utils.containsIgnoreCase(raw_user_request, "optimiz") or
        utils.containsIgnoreCase(raw_user_request, "benchmark");
}

const ThresholdAnalysis = struct {
    detected: bool,
    single_numeric: bool,
    gap_percent: ?f64,
};

const VerificationInsight = struct {
    has_failure: bool,
    has_metrics: bool,
};

fn analyzeVerificationOutput(out: []const u8) VerificationInsight {
    var has_metrics = false;

    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (looksLikeMetricLine(trimmed)) {
            has_metrics = true;
        }
    }
    return .{
        .has_failure = looksLikeAnyFailure(out),
        .has_metrics = has_metrics,
    };
}

fn buildMetricSnapshot(allocator: std.mem.Allocator, out: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, out, '\n');
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (!looksLikeMetricLine(trimmed)) continue;
        if (buf.items.len > 0) try buf.appendSlice(allocator, "; ");
        const remain = 220 - buf.items.len;
        if (remain == 0) break;
        const to_copy = @min(trimmed.len, remain);
        try buf.appendSlice(allocator, trimmed[0..to_copy]);
        if (buf.items.len >= 220) break;
    }
    if (buf.items.len == 0) return allocator.dupe(u8, "metrics not captured");
    return buf.toOwnedSlice(allocator);
}

fn looksLikeMetricLine(line: []const u8) bool {
    return (utils.containsIgnoreCase(line, "cost") and (std.mem.indexOf(u8, line, ":") != null or std.mem.indexOf(u8, line, " > ") != null)) or
        (utils.containsIgnoreCase(line, "latency") and std.mem.indexOf(u8, line, ":") != null) or
        (utils.containsIgnoreCase(line, "pad ratio") and std.mem.indexOf(u8, line, ":") != null) or
        (utils.containsIgnoreCase(line, "timecost") and std.mem.indexOf(u8, line, ":") != null) or
        (utils.containsIgnoreCase(line, "bucket") and std.mem.indexOf(u8, line, " > ") != null);
}

fn isGoldenVerificationCommand(cmd: []const u8) bool {
    const c = std.mem.trim(u8, cmd, " \t\r\n");
    return std.mem.indexOf(u8, c, "pytest") != null or
        std.mem.indexOf(u8, c, " verify") != null or
        std.mem.endsWith(u8, c, "verify.sh") or
        std.mem.indexOf(u8, c, "test_outputs.py") != null;
}

fn isInvariantVerificationCommand(cmd: []const u8, out: []const u8) bool {
    const c = std.mem.trim(u8, cmd, " \t\r\n");
    return std.mem.indexOf(u8, c, "shape") != null or
        std.mem.indexOf(u8, c, "schema") != null or
        std.mem.indexOf(u8, c, "consistency") != null or
        std.mem.indexOf(u8, c, "test_solution_shape_feasibility") != null or
        std.mem.indexOf(u8, c, "test_generate_and_schema") != null or
        looksLikeCorrectnessFailure(out);
}

fn buildFailureSnapshot(allocator: std.mem.Allocator, out: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, out, '\n');
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (!(utils.containsIgnoreCase(trimmed, "assert") or
            utils.containsIgnoreCase(trimmed, "failed") or
            utils.containsIgnoreCase(trimmed, "error")))
        {
            continue;
        }
        if (buf.items.len > 0) try buf.appendSlice(allocator, "; ");
        const remain = 220 - buf.items.len;
        if (remain == 0) break;
        const to_copy = @min(trimmed.len, remain);
        try buf.appendSlice(allocator, trimmed[0..to_copy]);
        if (buf.items.len >= 220) break;
    }
    if (buf.items.len == 0) return allocator.dupe(u8, "correctness invariant failed");
    return buf.toOwnedSlice(allocator);
}

fn requiredArtifactsExistPaths(paths: []const []const u8) bool {
    for (paths) |p| {
        if (!fileExists(p)) return false;
    }
    return true;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn collectRequiredOutputPaths(
    allocator: std.mem.Allocator,
    raw_user_request: []const u8,
    out: *std.ArrayListUnmanaged([]const u8),
) !void {
    var tok = std.mem.tokenizeAny(u8, raw_user_request, " \t\r\n`'\"()[]{}<>,;");
    while (tok.next()) |t_raw| {
        const t = std.mem.trim(u8, t_raw, " \t\r\n:.");
        if (t.len == 0) continue;
        if (std.mem.startsWith(u8, t, "http://") or std.mem.startsWith(u8, t, "https://")) continue;
        if (!isLikelyOutputArtifactToken(t)) continue;
        if (std.mem.indexOf(u8, t, "/input") != null or std.mem.indexOf(u8, t, "input_data/") != null) continue;
        if (containsPathStr(out.items, t)) continue;
        try out.append(allocator, try allocator.dupe(u8, t));
    }
}

fn isLikelyOutputArtifactToken(t: []const u8) bool {
    const has_ext = std.mem.lastIndexOfScalar(u8, t, '.') != null;
    if (!has_ext) return false;
    const output_hint = utils.containsIgnoreCase(t, "output") or
        utils.containsIgnoreCase(t, "result") or
        utils.containsIgnoreCase(t, "submission") or
        utils.containsIgnoreCase(t, "answer") or
        utils.containsIgnoreCase(t, "plan");
    return output_hint;
}

fn containsPathStr(paths: []const []const u8, p: []const u8) bool {
    for (paths) |x| {
        if (std.mem.eql(u8, x, p)) return true;
    }
    return false;
}

fn captureArtifactSnapshots(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    out: *std.ArrayListUnmanaged(ArtifactSnapshot),
) !void {
    for (out.items) |it| {
        allocator.free(it.path);
        allocator.free(it.content);
    }
    out.clearRetainingCapacity();

    for (paths) |p| {
        const content = std.fs.cwd().readFileAlloc(allocator, p, 8 * 1024 * 1024) catch continue;
        try out.append(allocator, .{
            .path = try allocator.dupe(u8, p),
            .content = content,
        });
    }
}

fn restoreArtifactSnapshots(snaps: *const std.ArrayListUnmanaged(ArtifactSnapshot)) !void {
    for (snaps.items) |it| {
        var f = try std.fs.cwd().createFile(it.path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(it.content);
    }
}

fn verificationScore(out: []const u8) f64 {
    var score: f64 = 0.0;
    if (looksLikeAnyFailure(out)) score += 1.0e6;
    const threshold = analyzeThresholdFailure(out);
    if (threshold.detected and threshold.gap_percent != null) score += threshold.gap_percent.?;
    return score;
}

fn analyzeThresholdFailure(out: []const u8) ThresholdAnalysis {
    var has_numeric_assert = false;
    var numeric_assert_count: usize = 0;
    var assertion_count: usize = 0;
    var gap_percent: ?f64 = null;

    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "AssertionError")) |_| {
            assertion_count += 1;
            if (std.mem.indexOf(u8, line, " > ")) |gt_idx| {
                const lhs = parseLastNumber(line[0..gt_idx]);
                const rhs = parseFirstNumber(line[gt_idx + 3 ..]);
                if (lhs != null and rhs != null and rhs.? > 0.0 and lhs.? > rhs.?) {
                    has_numeric_assert = true;
                    numeric_assert_count += 1;
                    gap_percent = ((lhs.? - rhs.?) / rhs.?) * 100.0;
                }
            }
        }
    }

    const detected = has_numeric_assert or looksLikeThresholdFailure(out);
    return .{
        .detected = detected,
        .single_numeric = detected and assertion_count == 1 and numeric_assert_count == 1,
        .gap_percent = gap_percent,
    };
}

fn parseFirstNumber(s: []const u8) ?f64 {
    var tok = std.mem.tokenizeAny(u8, s, " \t,:;()[]{}<>=\"'");
    while (tok.next()) |t| {
        const n = std.fmt.parseFloat(f64, t) catch continue;
        return n;
    }
    return null;
}

fn parseLastNumber(s: []const u8) ?f64 {
    var tok = std.mem.tokenizeAny(u8, s, " \t,:;()[]{}<>=\"'");
    var out: ?f64 = null;
    while (tok.next()) |t| {
        const n = std.fmt.parseFloat(f64, t) catch continue;
        out = n;
    }
    return out;
}
