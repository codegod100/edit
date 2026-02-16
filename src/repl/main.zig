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
        cancel.pollForEscape();
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

pub fn run(allocator: std.mem.Allocator) !void {
    // Arena for provider specs that live for the entire session
    var provider_arena = std.heap.ArenaAllocator.init(allocator);
    defer provider_arena.deinit();
    const provider_alloc = provider_arena.allocator();
    // Arena for provider specs that live for the entire session

    const stdin_file = line_editor.stdInFile();
    const stdout_file = line_editor.stdOutFile();
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
    const home = std.posix.getenv("HOME") orelse "";
    const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "zagent" });
    defer allocator.free(config_dir);
    try std.fs.cwd().makePath(config_dir);

    // Load initial data
    const provider_specs = try provider.loadProviderSpecs(provider_alloc, config_dir);
    // Providers are static configuration, but we might want them in state.
    // Spec says []const ProviderSpec. We can keep it.

    var stored_pairs = try store.load(allocator, config_dir);
    defer store.free(allocator, stored_pairs);

    // Codex token sync
    {
        const codex_path = try std.fs.path.join(allocator, &.{ home, ".codex", "copilot_auth.json" });
        defer allocator.free(codex_path);
        const f = std.fs.openFileAbsolute(codex_path, .{}) catch |err| blk: {
            if (err != error.FileNotFound) {} // ignore
            break :blk null;
        };
        if (f) |file| {
            defer file.close();
            const text = file.readToEndAlloc(allocator, 16 * 1024) catch null;
            if (text) |t| {
                defer allocator.free(t);
                // Simple grep for token
                if (std.mem.indexOf(u8, t, "\"token\":\"")) |idx| {
                    const start = idx + 9;
                    if (std.mem.indexOfScalarPos(u8, t, start, '"')) |end| {
                        const token = t[start..end];
                        // Upsert into stored_pairs if not present or different
                        // Actually just upsert file
                        _ = store.upsertFile(allocator, config_dir, "GITHUB_COPILOT_API_KEY", token) catch {};
                        // Reload stored
                        store.free(allocator, stored_pairs);
                        stored_pairs = try store.load(allocator, config_dir);
                    }
                }
            }
        }
    }

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
    };
    defer state.deinit();

    // Load selected model config into state
    state.selected_model = config_store.loadSelectedModel(allocator, config_dir) catch null;

    // Initialize Status Bar Info before setupScrollingRegion
    const active_init = model_select.chooseActiveModel(state.providers, state.provider_states, state.selected_model, state.reasoning_effort);
    if (active_init) |a| {
        display.setStatusBarInfo(a.provider_id, a.model_id, cwd);
    } else {
        display.setStatusBarInfo("none", "none", cwd);
    }

    // Initialize scrolling region (reserves bottom line for status bar)
    display.setupScrollingRegion(stdout_file);
    defer display.resetScrollingRegion(stdout_file);

    // Print Session Info
    try stdout.print("Session ID: {s}{s}{s} (Log: {s}/transcript_{s}.txt)\n", .{ 
        display.C_BOLD, logger.getSessionID(), display.C_RESET,
        config_dir, logger.getSessionID() 
    });

    // Load Context/History (only restore context if ZAGENT_RESTORE_CONTEXT is set)
    const restore_context = std.posix.getenv("ZAGENT_RESTORE_CONTEXT") != null;
    if (restore_context) {
        context.loadContextWindow(allocator, config_dir, &state.context_window, state.project_hash) catch {};
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

        // Get terminal dimensions
        const term_width = display.terminalColumns();
        const term_height = display.getTerminalHeight();
        const box_width = if (term_width > 80) 80 else if (term_width > 4) term_width - 2 else 78;
        
        try logger.transcriptWrite("[Terminal] {d}x{d}\n", .{ term_width, term_height });

        // 1. Vertical spacing before box
        try stdout.writeAll("\n");

        // 2. Pre-render the entire box
        // Total outer width will be box_width + 2
        // Top
        try stdout.print("{s}\xe2\x95\xad", .{display.C_CYAN}); // ╭
        var bw: usize = 0;
        while (bw < box_width) : (bw += 1) try stdout.writeAll("\xe2\x94\x80"); // ─
        try stdout.print("\xe2\x95\xae{s}\n", .{display.C_RESET}); // ╮
        
        // Middle (Empty)
        try stdout.print("{s}\xe2\x94\x82{s} > ", .{ display.C_CYAN, display.C_RESET });
        bw = 0;
        // box_width total inner - 3 for " > "
        while (bw < box_width - 3) : (bw += 1) try stdout.writeAll(" ");
        try stdout.print("{s}\xe2\x94\x82{s}\n", .{ display.C_CYAN, display.C_RESET }); // │
        
        // Bottom
        try stdout.print("{s}\xe2\x95\xb0", .{display.C_CYAN}); // ╰
        bw = 0;
        while (bw < box_width) : (bw += 1) try stdout.writeAll("\xe2\x94\x80"); // ─
        try stdout.print("\xe2\x95\xaf{s}\n", .{display.C_RESET}); // ╯

        // 3. Move cursor UP 2 lines and forward 5 chars to get into the "│ > " position
        try stdout.writeAll("\x1b[2A\x1b[5G");

        // Read Line (passing empty prompt because we already printed it)
        var line_opt: ?[]u8 = null;
        if (queued_lines.items.len > 0) {
            line_opt = queued_lines.orderedRemove(0);
        } else {
            line_opt = try line_editor.readPromptLine(allocator, stdin_file, stdin, &stdout, "", &history);
        }

        if (line_opt == null) {
            try stdout.print("\nEOF.\n", .{});
            break;
        }
        const line = line_opt.?;
        defer allocator.free(line);

        // 4. Move cursor down past the box bottom to resume normal scrolling
        try stdout.writeAll("\x1b[2B\r");

        if (line.len == 0) continue;

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

        // Add user turn to context
        try state.context_window.append(allocator, .user, line, .{});
        try context.saveContextWindow(allocator, config_dir, &state.context_window, state.project_hash);

        // Initialize tool output arena for persistent strings
        const legacy = @import("../model_loop/legacy.zig");
        legacy.initToolOutputArena(allocator);
        defer legacy.deinitToolOutputArena();
        
        g_callback_stdout_file = stdout_file;
        model_loop.setToolOutputCallback(struct {
            fn callback(text: []const u8) void {
                cancel.pollForEscape();
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

        const ctx_prompt = try context.buildContextPrompt(turn_alloc, &state.context_window, line);

        display.setSpinnerState(.thinking);

        // Show spinner while model is processing
        if (stdout_file.isTty()) {
            try startSpinner(stdout_file);
        }

        logger.info("Calling runModel for line: {s}", .{line});
        cancel.beginProcessing();
        cancel.enableRawMode();
        defer cancel.disableRawMode();

        const result = model_loop.runModel(allocator, stdout, active.?, line, // raw request
            ctx_prompt, stdout_file.isTty(), &state.todo_list, null // system prompt override
        ) catch |err| {
            stopSpinner();
            logger.err("runModel failed with error: {any}", .{err});
            display.addTimelineEntry("{s}Error:{s} {s}\n", .{ display.C_RED, display.C_RESET, @errorName(err) });
            // Error already in timeline, continue loop to redraw at end
            continue;
        };
        logger.info("runModel completed successfully", .{});

        stopSpinner();
        resetCursorStyle(stdout_file);

        // Assistant response is already printed via respond_text tool call usually,
        // but if not, we should ensure it's in the timeline.
        // The new runModel adds everything to timeline via addTimelineEntry.

        try state.context_window.append(allocator, .assistant, result.response, .{
            .tool_calls = result.tool_calls,
            .error_count = result.error_count,
            .files_touched = result.files_touched,
        });

        // Cleanup result
        var mut_res = result;
        mut_res.deinit(allocator);

        try context.compactContextWindow(allocator, &state.context_window, active.?);
        try context.saveContextWindow(allocator, config_dir, &state.context_window, state.project_hash);

        // Drain inputs during run
        line_editor.drainQueuedLinesFromStdin(allocator, stdin_file, &queued_partial, &queued_lines);
    }
}
