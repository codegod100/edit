const std = @import("std");
const builtin = @import("builtin");
const state_mod = @import("state.zig");
const handlers = @import("handlers.zig");
const commands = @import("commands.zig");
const ui = @import("ui.zig");
const auth = @import("../auth.zig");
const pm = @import("../provider_manager.zig");
const store = @import("../provider_store.zig");
const config_store = @import("../config_store.zig");
const skills = @import("../skills.zig");
const tools = @import("../tools.zig");
const context = @import("../context.zig");
const model_loop = @import("../model_loop.zig");
const model_select = @import("../model_select.zig");
const catalog = @import("../models_catalog.zig");
const subagent = @import("../subagent.zig");
const todo = @import("../todo.zig");
const display = @import("../display.zig");
const cancel = @import("../cancel.zig");
const line_editor = @import("../line_editor.zig");

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
    const providers = try catalog.loadProviderSpecs(provider_alloc, config_dir);
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

    const provider_states = try model_select.resolveProviderStates(allocator, providers, stored_pairs);

    // Initialize State
    var state = state_mod.ReplState{
        .allocator = allocator,
        .providers = providers,
        .provider_states = provider_states,
        .selected_model = null,
        .context_window = context.ContextWindow.init(32000, 20),
        .todo_list = todo.TodoList.init(allocator),
        .subagent_manager = subagent.SubagentManager.init(allocator),
        .reasoning_effort = null,
        .project_hash = context.hashProjectPath(cwd),
        .config_dir = config_dir,
    };
    defer state.deinit();

    // Load Context/History (only restore context if ZAGENT_RESTORE_CONTEXT is set)
    const restore_context = std.posix.getenv("ZAGENT_RESTORE_CONTEXT") != null;
    if (restore_context) {
        context.loadContextWindow(allocator, config_dir, &state.context_window, state.project_hash) catch {};
    }
    var history = context.CommandHistory.init();
    defer history.deinit(allocator);
    context.loadHistory(allocator, config_dir, &history) catch {};

    // Load selected model config
    state.selected_model = config_store.loadSelectedModel(allocator, config_dir) catch null;
    if (state.selected_model) |_| {
        // Restore reasoning_effort if saved? config_store might load it?
        // ConfigStore struct needs checking. Assuming for now.
        // Actually loadSelectedModel returns OwnedModelSelection which has specific fields.
        // We might need to load reasoning effort separately if not in OwnedModelSelection.
        // Ignoring effort restoration for brevity unless critical.
    }

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

        // Get active model info for prompt
        const active = model_select.chooseActiveModel(state.providers, state.provider_states, state.selected_model, state.reasoning_effort);
        
        // Get terminal width for box
        const term_width = display.terminalColumns();
        const box_width = if (term_width > 4) term_width - 2 else 78;
        
        // Prompt with horizontal box style - fit to screen
        var prompt_buf: std.ArrayListUnmanaged(u8) = .empty;
        
        // Top border: ╭────────────────────╮
        try prompt_buf.appendSlice(allocator, "\xe2\x95\xad"); // ╭
        var bw: usize = 0;
        while (bw < box_width) : (bw += 1) {
            try prompt_buf.appendSlice(allocator, "\xe2\x94\x80"); // ─
        }
        try prompt_buf.appendSlice(allocator, "\xe2\x95\xae\n"); // ╮
        
        // Middle line with ">": │ > ... │
        try prompt_buf.appendSlice(allocator, "\xe2\x94\x82 >"); // │ > (2 display chars)
        bw = 0;
        while (bw < box_width - 2) : (bw += 1) { // Fill remaining width minus "│ >" and "│"
            try prompt_buf.appendSlice(allocator, " ");
        }
        try prompt_buf.appendSlice(allocator, " \xe2\x94\x82\n"); // space + │
        
        // Bottom border: ╰────────────────────╯
        try prompt_buf.appendSlice(allocator, "\xe2\x95\xb0"); // ╰
        bw = 0;
        while (bw < box_width) : (bw += 1) {
            try prompt_buf.appendSlice(allocator, "\xe2\x94\x80"); // ─
        }
        try prompt_buf.appendSlice(allocator, "\xe2\x95\xaf\n"); // ╯
        
        // System info line below box - show full path
        if (active) |a| {
            if (state.selected_model) |m| {
                try prompt_buf.writer(allocator).print(" {s}/{s} @ ", .{ a.provider_id, m.model_id });
            }
        }
        try prompt_buf.writer(allocator).print("{s}\n", .{cwd});
        const prompt = try prompt_buf.toOwnedSlice(allocator);
        defer allocator.free(prompt);

        // Read Line
        var line_opt: ?[]u8 = null;
        if (queued_lines.items.len > 0) {
            line_opt = queued_lines.orderedRemove(0);
        } else {
            line_opt = try line_editor.readPromptLine(allocator, stdin_file, stdin, &stdout, prompt, &history);
        }

        if (line_opt == null) {
            try stdout.print("\nEOF.\n", .{});
            break;
        }
        const line = line_opt.?;
        defer allocator.free(line);

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

        // Add user input to timeline and redraw
        display.addTimelineEntry("{s}>>{s} {s}", .{ display.C_CYAN, display.C_RESET, line });
        try display.clearScreenAndRedrawTimeline(stdout, prompt, "");

        // Add user turn to context
        try state.context_window.append(allocator, .user, line, .{});
        try context.saveContextWindow(allocator, config_dir, &state.context_window, state.project_hash);

        // Arena for per-turn allocations (context prompt, model result, etc.)
        var turn_arena = std.heap.ArenaAllocator.init(allocator);
        defer turn_arena.deinit();
        const turn_alloc = turn_arena.allocator();

        const ctx_prompt = try context.buildContextPrompt(turn_alloc, &state.context_window, line);

        // Move cursor to bottom for model output
        try stdout.writeAll("\n");

        const result = model_loop.runModel(allocator, stdout, active.?, line, // raw request
            ctx_prompt, stdout_file.isTty(), &state.todo_list, &state.subagent_manager, null // system prompt override
        ) catch |err| {
            display.addTimelineEntry("{s}Error:{s} {s}", .{ display.C_RED, display.C_RESET, @errorName(err) });
            try display.clearScreenAndRedrawTimeline(stdout, prompt, "");
            continue;
        };

        // Add assistant response to timeline (convert \n to actual newlines)
        const response_with_newlines = try allocator.alloc(u8, result.response.len);
        defer allocator.free(response_with_newlines);
        var j: usize = 0;
        var i: usize = 0;
        while (i < result.response.len) : (i += 1) {
            if (result.response[i] == '\\' and i + 1 < result.response.len and result.response[i + 1] == 'n') {
                response_with_newlines[j] = '\n';
                j += 1;
                i += 1;
            } else {
                response_with_newlines[j] = result.response[i];
                j += 1;
            }
        }
        display.addTimelineEntry("{s}⛬{s} {s}", .{ display.C_CYAN, display.C_RESET, response_with_newlines[0..j] });

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

        // Redraw timeline with prompt at bottom
        try display.clearScreenAndRedrawTimeline(stdout, prompt, "");

        // Drain inputs during run
        line_editor.drainQueuedLinesFromStdin(allocator, stdin_file, &queued_partial, &queued_lines);
    }
}
