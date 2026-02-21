const std = @import("std");
const builtin = @import("builtin");
const state_mod = @import("state.zig");
const handlers = @import("handlers.zig");
const commands = @import("commands.zig");
const ui = @import("ui.zig");
const auth = @import("../auth.zig");
const provider = @import("../provider.zig");
const store = @import("../provider_store.zig");
const config_store = @import("../config_store.zig");
const skills = @import("../skills.zig");
const tools = @import("../tools.zig");
const context = @import("../context.zig");
const model_loop = @import("../model_loop.zig");
const model_select = @import("../model_select.zig");
const paths = @import("../paths.zig");

const todo = @import("../todo.zig");
const display = @import("../display.zig");
const cancel = @import("../cancel.zig");
const line_editor = @import("../line_editor.zig");
const logger = @import("../logger.zig");

// Spinner state for showing processing indicator
var g_spinner_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_spinner_thread: ?std.Thread = null;

fn spinnerThread(stdout_file: std.fs.File) void {
    var state_buf: [192]u8 = undefined;
    while (g_spinner_running.load(.acquire)) {
        drainInput();
        const state_text = display.getSpinnerStateText(&state_buf);
        const frame = display.getSpinnerFrame();
        
        display.renderStatusBar(stdout_file, frame, state_text);
        
        std.Thread.sleep(80 * std.time.ns_per_ms);
    }
    // Final clear of status bar
    display.renderStatusBar(stdout_file, "", "");
}

// Reset cursor to terminal default
fn resetCursorStyle(stdout_file: std.fs.File) void {
    _ = stdout_file.write("\x1b[0 q") catch {}; // Reset to terminal default
}

fn startSpinner(stdout_file: std.fs.File) !void {
    display.setSpinnerState(.thinking);
    display.setSpinnerActive(true);
    g_spinner_running.store(true, .release);
    g_spinner_thread = try std.Thread.spawn(.{}, spinnerThread, .{stdout_file});
}

fn stopSpinner() void {
    g_spinner_running.store(false, .release);
    if (g_spinner_thread) |t| {
        t.join();
        g_spinner_thread = null;
    }
    display.setSpinnerActive(false);
    display.setSpinnerState(.thinking);
}

// Global state for callback redraw
var g_callback_stdout_file: ?std.fs.File = null;
var g_callback_prompt: ?[]const u8 = null;

const InputDrainCallback = *const fn () void;
var g_input_drain_callback: ?InputDrainCallback = null;
var g_input_drain_mutex: std.Thread.Mutex = .{};

const InputDrainState = struct {
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    queued_partial: *std.ArrayListUnmanaged(u8),
    queued_lines: *std.ArrayListUnmanaged([]u8),
};
var g_input_drain_state: ?InputDrainState = null;

fn drainInput() void {
    g_input_drain_mutex.lock();
    defer g_input_drain_mutex.unlock();

    if (g_input_drain_state) |ids| {
        @import("../line_editor.zig").drainQueuedLinesFromStdin(ids.allocator, ids.stdin_file, ids.queued_partial, ids.queued_lines);
    }
}

fn containsSkillPtr(items: []const *skills.Skill, candidate: *skills.Skill) bool {
    for (items) |s| {
        if (s == candidate) return true;
    }
    return false;
}

fn lastFilesTouched(window: *const context.ContextWindow) ?[]const u8 {
    var i: usize = window.turns.items.len;
    while (i > 0) {
        i -= 1;
        const turn = window.turns.items[i];
        if (turn.role == .assistant and turn.files_touched != null) return turn.files_touched.?;
    }
    return null;
}

fn hasExtHint(line: []const u8, recent_files: ?[]const u8, ext: []const u8) bool {
    var needle_buf: [16]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, ".{s}", .{ext}) catch return false;
    if (std.mem.indexOf(u8, line, needle) != null) return true;
    if (recent_files) |rf| {
        if (std.mem.indexOf(u8, rf, needle) != null) return true;
    }
    return false;
}

/// Non-interactive mode: read stdin, send to model, print response, exit
fn runNonInteractive(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    active: ?context.ActiveModel,
    state: *state_mod.ReplState,
) !void {
    // Disable ANSI codes for non-interactive output
    display.setNoAnsi(true);

    // Read all stdin content
    var input = std.ArrayListUnmanaged(u8).empty;
    defer input.deinit(allocator);
    
    // Read in chunks until EOF
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stdin.read(&buf) catch 0;
        if (n == 0) break;
        try input.appendSlice(allocator, buf[0..n]);
    }
    
    const line = std.mem.trim(u8, input.items, " \t\r\n");
    if (line.len == 0) return;

    // Check for active model
    if (active == null) {
        try stdout.print("Error: No active model/provider. Use /model or set --model flag.\n", .{});
        return;
    }

    logger.info("Non-interactive mode: sending to model", .{});

    // Set up context
    var turn_arena = std.heap.ArenaAllocator.init(allocator);
    defer turn_arena.deinit();
    const turn_alloc = turn_arena.allocator();

    const ctx_messages = try context.buildContextMessagesJson(turn_alloc, &state.context_window, line);

    cancel.init();
    defer cancel.deinit();
    cancel.resetCancelled();
    cancel.beginProcessing();

    // Run model (no TTY, no spinner, no tools in non-interactive mode)
    const result = model_loop.runModel(allocator, stdout, active.?, line, ctx_messages, false, &state.todo_list, null) catch |err| {
        logger.err("runModel failed: {any}", .{err});
        try stdout.print("Error: {s}\n", .{@errorName(err)});
        return;
    };

    // Print response plainly
    if (result.reasoning.len > 0) {
        try stdout.print("--- Reasoning ---\n{s}\n--- Response ---\n", .{result.reasoning});
    }
    try stdout.print("{s}\n", .{result.response});

    // Save to context
    try state.context_window.append(allocator, .assistant, result.response, .{
        .reasoning = result.reasoning,
        .tool_calls = result.tool_calls,
        .error_count = result.error_count,
        .files_touched = result.files_touched,
    });

    var mut_res = result;
    mut_res.deinit(allocator);
}

pub fn run(allocator: std.mem.Allocator, resumed_session_hash_arg: ?u64) !void {
    // Arena for provider specs that live for the entire session
    var provider_arena = std.heap.ArenaAllocator.init(allocator);
    defer provider_arena.deinit();
    const provider_alloc = provider_arena.allocator();
    // Arena for provider specs that live for the entire session

    const stdin_file = line_editor.stdInFile();
    const stdout_file = line_editor.stdOutFile();
    
    // Check if we're in non-interactive mode (stdin is piped)
    const is_interactive = std.posix.isatty(std.posix.STDIN_FILENO);
    
    // Use reader/writer directly
    const stdin = if (@hasDecl(std.fs.File, "deprecatedReader"))
        stdin_file.deprecatedReader()
    else
        stdin_file.reader();
    var stdout = if (@hasDecl(std.fs.File, "deprecatedWriter"))
        stdout_file.deprecatedWriter()
    else
        stdout_file.writer();
    
    // Initialize timeline display
    display.initTimeline(allocator);
    defer display.deinitTimeline();

    // Setup paths
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const config_dir = try paths.getConfigDir(allocator);
    defer allocator.free(config_dir);
    try std.fs.cwd().makePath(config_dir);

    // Load initial data
    const provider_specs = try provider.loadProviderSpecs(provider_alloc, config_dir);
    // Providers are static configuration, but we might want them in state.
    // Spec says []const ProviderSpec. We can keep it.

    const stored_pairs = try store.load(allocator, config_dir);
    defer store.free(allocator, stored_pairs);

    const provider_states = try model_select.resolveProviderStates(allocator, provider_specs, stored_pairs);

    // Initialize State
    var state = state_mod.ReplState{
        .allocator = allocator,
        .providers = provider_specs,
        .provider_states = provider_states,
        .selected_model = null,
        .context_window = context.ContextWindow.init(32000, 20),
        .todo_list = todo.TodoList.init(allocator),

        .reasoning_effort = null,
        .project_hash = context.hashProjectPath(cwd),
        .config_dir = config_dir,
        .resumed_session_hash = resumed_session_hash_arg,
    };
    defer state.deinit();
    state.context_window.project_path = try allocator.dupe(u8, cwd);

    // Load selected model config into state
    state.selected_model = config_store.loadSelectedModel(allocator, config_dir) catch null;

    // Initialize Status Bar Info before setupScrollingRegion
    const active_init = model_select.chooseActiveModel(state.providers, state.provider_states, state.selected_model, state.reasoning_effort);
    if (active_init) |a| {
        display.setStatusBarInfo(a.provider_id, a.model_id, cwd);
    } else {
        display.setStatusBarInfo("none", "none", cwd);
    }

    // Non-interactive mode: read from stdin, get response, exit
    if (!is_interactive) {
        return runNonInteractive(allocator, stdin, stdout, active_init, &state);
    }

    // Initialize scrolling region (reserves bottom line for status bar)
    display.setupScrollingRegion(stdout_file);
    defer display.resetScrollingRegion(stdout_file);

    // Print Session Info
    try stdout.print("Session ID: {s}{s}{s} (Log: {s}/{s}/transcript_{s}.txt)\n", .{ 
        display.C_BOLD, logger.getSessionID(), display.C_RESET,
        config_dir, paths.TRANSCRIPTS_DIR_NAME, logger.getSessionID() 
    });

    // Load Context/History
    // If a session was resumed, load its context. Otherwise, check ZAGENT_RESTORE_CONTEXT env var
    const restore_context_env = std.posix.getenv("ZAGENT_RESTORE_CONTEXT") != null;
    const hash_to_load = resumed_session_hash_arg orelse blk: {
        if (restore_context_env) break :blk state.project_hash;
        break :blk null;
    };
    if (hash_to_load) |hash| {
        context.loadContextWindow(allocator, config_dir, &state.context_window, hash) catch {};
        if (state.context_window.project_path == null) {
            state.context_window.project_path = try allocator.dupe(u8, cwd);
        }

        // Replay history to timeline
        if (state.context_window.turns.items.len > 0) {
            display.addTimelineEntry("{s}--- Resumed Session History ---{s}\n", .{ display.C_DIM, display.C_RESET });
            for (state.context_window.turns.items) |turn| {
                if (turn.role == .user) {
                    display.addTimelineEntry("{s}{s}{s}\n", .{ display.C_CYAN, turn.content, display.C_RESET });
                } else {
                    if (turn.reasoning) |r| {
                        if (r.len > 0) {
                            display.addTimelineEntry("{s}Reasoning:{s}\n", .{ display.C_PURPLE, display.C_RESET });
                            display.addWrappedTimelineEntry(display.C_PURPLE, r, display.C_RESET);
                        }
                    }
                    if (turn.content.len > 0) {
                        display.addTimelineEntry("{s}⛬{s} {s}\n", .{ display.C_CYAN, display.C_RESET, turn.content });
                    }
                    if (turn.tool_calls > 0) {
                        display.addTimelineEntry("{s}• {d} tool calls{s}\n", .{ display.C_DIM, turn.tool_calls, display.C_RESET });
                    }
                }
            }
            display.addTimelineEntry("{s}-------------------------------{s}\n", .{ display.C_DIM, display.C_RESET });
        }
    }
    var history = context.CommandHistory.init();
    defer history.deinit(allocator);
    context.loadHistory(allocator, config_dir, &history) catch {};

    // Input queue
    var queued_lines: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (queued_lines.items) |l| allocator.free(l);
        queued_lines.deinit(allocator);
    }
    var queued_partial: std.ArrayListUnmanaged(u8) = .empty;
    defer queued_partial.deinit(allocator);

    // Main Loop
    while (true) {
        cancel.resetCancelled();

        // Ensure vertical spacing before new prompt
        try stdout.writeAll("\n");

        // Set state to idle while waiting for input
        display.setSpinnerState(.idle);

        // Get active model info for prompt
        const active = model_select.chooseActiveModel(state.providers, state.provider_states, state.selected_model, state.reasoning_effort);
        
        if (active) |a| {
            display.setStatusBarInfo(a.provider_id, a.model_id, cwd);
        } else {
            display.setStatusBarInfo("none", "none", cwd);
        }
        
        var state_buf: [128]u8 = undefined;
        display.renderStatusBar(stdout_file, " ", display.getSpinnerStateText(&state_buf));

        // Get terminal dimensions
        const term_width = display.terminalColumns();
        const term_height = display.getTerminalHeight();
        
        try logger.transcriptWrite("[Terminal] {d}x{d}\n", .{ term_width, term_height });

        // Prompt prefix now removed - input will be colorized directly

        // Read Line
        var line_opt: ?[]u8 = null;
        var line_from_queue = false;
        if (queued_lines.items.len > 0) {
            line_opt = queued_lines.orderedRemove(0);
            line_from_queue = true;
        } else {
            line_opt = try line_editor.readPromptLine(allocator, stdin_file, stdin, &stdout, "> ", &history, queued_partial.items);
            queued_partial.clearRetainingCapacity();
        }

        if (line_opt == null) {
            // EOF or Ctrl+C - exit cleanly
            if (!cancel.isCancelled()) {
                try stdout.print("\nEOF.\n", .{});
            }
            break;
        }
        var line = line_opt.?;
        defer allocator.free(line);

        // If a multiline paste submitted on first newline, remaining lines can still
        // be waiting in stdin. Drain and merge them so the model sees one prompt body.
        if (!line_from_queue) {
            line_editor.drainQueuedLinesFromStdin(allocator, stdin_file, &queued_partial, &queued_lines);
            if (queued_lines.items.len > 0 or queued_partial.items.len > 0) {
                var merged: std.ArrayListUnmanaged(u8) = .empty;
                defer merged.deinit(allocator);
                try merged.appendSlice(allocator, line);

                for (queued_lines.items) |extra| {
                    try merged.append(allocator, '\n');
                    try merged.appendSlice(allocator, extra);
                    allocator.free(extra);
                }
                queued_lines.clearRetainingCapacity();

                if (queued_partial.items.len > 0) {
                    try merged.append(allocator, '\n');
                    try merged.appendSlice(allocator, queued_partial.items);
                    queued_partial.clearRetainingCapacity();
                }

                const old_line = line;
                line = try merged.toOwnedSlice(allocator);
                allocator.free(old_line);
            }
        }

        // Defensive normalization: strip any accidental prompt prefixes
        // before rendering, command parsing, or history persistence.
        const normalized_line = context.normalizeHistoryLine(line);
        if (!std.mem.eql(u8, normalized_line, line)) {
            const old_line = line;
            line = try allocator.dupe(u8, normalized_line);
            allocator.free(old_line);
        }

        // Ensure we are at the start of a clean line before drawing the box
        std.debug.print("\r\x1b[K", .{});

        if (line.len == 0) {
            // Exit on empty line after cancellation (Ctrl+C)
            if (cancel.isCancelled()) {
                break;
            }
            continue;
        }

        // Colorize input text in the timeline (no box)
        display.addTimelineEntry("{s}> {s}{s}\n", .{ display.C_PROMPT, line, display.C_RESET });

        // History
        try history.append(allocator, line);
        try context.appendHistoryLine(allocator, config_dir, line);

        const cmd = commands.parseCommand(line);
        if (cmd != .none) {
            const arg_start = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const arg = std.mem.trim(u8, line[arg_start..], " \t");
            const keep_running = try handlers.handleCommand(allocator, &state, cmd, arg, stdin, stdout, stdin_file);
            if (!keep_running) break;
            continue;
        }

        // Run Model (active already retrieved for prompt)
        if (active == null) {
            try stdout.print("No active model/provider. Use /connect or /model.\n", .{});
            continue;
        }

        var model_user_input: []const u8 = line;
        var injected_skill_input: ?[]u8 = null;
        defer if (injected_skill_input) |s| allocator.free(s);

        var discovered_skills: []skills.Skill = &.{};
        var have_discovered_skills = false;
        if (skills.discover(allocator, ".", config_dir)) |list| {
            discovered_skills = list;
            have_discovered_skills = true;
        } else |err| {
            logger.warn("Skill discovery failed: {any}", .{err});
        }
        defer if (have_discovered_skills) skills.freeList(allocator, discovered_skills);

        var matched: std.ArrayListUnmanaged(*skills.Skill) = .empty;
        defer matched.deinit(allocator);
        if (have_discovered_skills) {
            for (discovered_skills) |*skill| {
                if (skills.isTriggeredByInput(skill.name, line)) {
                    try matched.append(allocator, skill);
                }
            }
        }

        // Natural language hints like "use roc skill" should also resolve skill names.
        if (matched.items.len == 0 and have_discovered_skills) {
            for (discovered_skills) |*skill| {
                if (skills.isHintedByInput(skill.name, line)) {
                    try matched.append(allocator, skill);
                }
            }
        }

        // Auto-load skill based on file types in the prompt or recently edited files.
        if (matched.items.len == 0 and have_discovered_skills) {
            const recent = lastFilesTouched(&state.context_window);
            const LangHint = struct { ext: []const u8, key: []const u8 };
            const hints = [_]LangHint{
                .{ .ext = "roc", .key = "roc" },
                .{ .ext = "zig", .key = "zig" },
                .{ .ext = "py", .key = "python" },
                .{ .ext = "rs", .key = "rust" },
                .{ .ext = "go", .key = "go" },
                .{ .ext = "ts", .key = "typescript" },
                .{ .ext = "tsx", .key = "typescript" },
                .{ .ext = "js", .key = "javascript" },
                .{ .ext = "jsx", .key = "javascript" },
            };

            for (hints) |h| {
                if (!hasExtHint(line, recent, h.ext)) continue;
                for (discovered_skills) |*skill| {
                    if (containsSkillPtr(matched.items, skill)) continue;
                    if (skills.nameContainsIgnoreCase(skill.name, h.key)) {
                        try matched.append(allocator, skill);
                    }
                }
            }
        }

        if (matched.items.len > 0) {
            const MAX_SKILLS: usize = 3;
            const MAX_SKILL_BODY_BYTES: usize = 20 * 1024;

            var names: std.ArrayListUnmanaged(u8) = .empty;
            defer names.deinit(allocator);
            for (matched.items, 0..) |s, i| {
                if (i > 0) try names.appendSlice(allocator, ", ");
                try names.appendSlice(allocator, s.name);
            }
            display.addTimelineEntry("{s}↳ Auto-loaded skills:{s} {s}\n", .{ display.C_DIM, display.C_RESET, names.items });

            var buf: std.ArrayListUnmanaged(u8) = .empty;
            errdefer buf.deinit(allocator);
            const w_skill = buf.writer(allocator);
            try w_skill.writeAll(line);
            try w_skill.writeAll("\n\n[Auto-loaded skill instructions for this turn]\n");

            var used: usize = 0;
            for (matched.items) |s| {
                if (used >= MAX_SKILLS) break;
                const body_cap = @min(s.body.len, MAX_SKILL_BODY_BYTES);
                try w_skill.print("\n[Skill: {s}]\n{s}\n", .{ s.name, s.body[0..body_cap] });
                if (s.body.len > body_cap) {
                    try w_skill.print("[Skill body truncated to {d} bytes]\n", .{MAX_SKILL_BODY_BYTES});
                }
                used += 1;
            }
            if (matched.items.len > MAX_SKILLS) {
                try w_skill.print("\n[Note: {d} additional matched skills omitted]\n", .{matched.items.len - MAX_SKILLS});
            }

            injected_skill_input = try buf.toOwnedSlice(allocator);
            model_user_input = injected_skill_input.?;
        }

        // Add user turn to context
        try state.context_window.append(allocator, .user, line, .{});

        const save_hash = state.resumed_session_hash orelse state.project_hash;
        try context.saveContextWindow(allocator, config_dir, &state.context_window, save_hash);

        // Initialize tool output arena for persistent strings
        const orchestrator = @import("../model_loop/orchestrator.zig");
        orchestrator.initToolOutputArena(allocator);
        defer orchestrator.deinitToolOutputArena();
        
        g_callback_stdout_file = stdout_file;
        model_loop.setToolOutputCallback(struct {
            fn callback(text: []const u8) void {
                // Drain input through a single path to avoid split-reading
                // escape sequences (e.g. ESC consumed here, tail echoed elsewhere).
                drainInput();
                display.addTimelineEntry("{s}", .{text});
            }
        }.callback);
        defer {
            model_loop.setToolOutputCallback(null);
            g_callback_stdout_file = null;
        }

        // Arena for per-turn allocations (context prompt, model result, etc.)
        var turn_arena = std.heap.ArenaAllocator.init(allocator);
        defer turn_arena.deinit();
        const turn_alloc = turn_arena.allocator();

        const ctx_messages = try context.buildContextMessagesJson(turn_alloc, &state.context_window, model_user_input);

        display.setSpinnerState(.thinking);

        // Show spinner while model is processing
        if (stdout_file.isTty()) {
            try startSpinner(stdout_file);
        }

        logger.info("Calling runModel for line: {s}", .{line});
        cancel.beginProcessing();
        cancel.enableRawMode();
        defer cancel.disableRawMode();

        // Set up the global drain state for the background spinner thread
        g_input_drain_state = .{
            .allocator = allocator,
            .stdin_file = stdin_file,
            .queued_partial = &queued_partial,
            .queued_lines = &queued_lines,
        };
        defer g_input_drain_state = null;

        const result = model_loop.runModel(allocator, stdout, active.?, line, // raw request
            ctx_messages, stdout_file.isTty(), &state.todo_list, null // system prompt override
        ) catch |err| {
            stopSpinner();
            cancel.disableRawMode(); // Disable raw mode before printing error
            logger.err("runModel failed with error: {any}", .{err});
            display.addTimelineEntry("{s}Error:{s} {s}\n", .{ display.C_RED, display.C_RESET, @errorName(err) });
            // Error already in timeline, continue loop to redraw at end
            continue;
        };
        logger.info("runModel completed successfully", .{});

        stopSpinner();
        cancel.disableRawMode();
        resetCursorStyle(stdout_file);

        // Assistant response is already printed via respond_text tool call usually,
        // but if not, we should ensure it's in the timeline.
        // The new runModel adds everything to timeline via addTimelineEntry.

        try state.context_window.append(allocator, .assistant, result.response, .{
            .reasoning = result.reasoning,
            .tool_calls = result.tool_calls,
            .error_count = result.error_count,
            .files_touched = result.files_touched,
        });

        // Cleanup result
        var mut_res = result;
        mut_res.deinit(allocator);

        try context.compactContextWindow(allocator, &state.context_window, active.?);
        const save_hash2 = state.resumed_session_hash orelse state.project_hash;
        try context.saveContextWindow(allocator, config_dir, &state.context_window, save_hash2);

        // Add a newline after turn completion
        try stdout.writeAll("\n");

        // Drain inputs during run
        line_editor.drainQueuedLinesFromStdin(allocator, stdin_file, &queued_partial, &queued_lines);
    }
}
