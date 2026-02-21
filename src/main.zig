const std = @import("std");
const repl = @import("repl/main.zig");
const logger = @import("logger.zig");
const cancel = @import("cancel.zig");
const context = @import("context.zig");
const config_store = @import("config_store.zig");
const paths = @import("paths.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var resume_session_id: ?[]const u8 = null;
    var model_flag: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help_text =
                \\Usage: zagent [OPTIONS]
                \\
                \\Options:
                \\  -m, --model PROVIDER/MODEL  Set the model (e.g., zai/glm-5, opencode/glm-5)
                \\      --resume [ID]           Resume from a session (show menu if no ID)
                \\  -h, --help                  Show this help message
                \\
                \\Environment Variables:
                \\  ZAGENT_RESTORE_CONTEXT=1    Also enables context restoration from current project
                \\
                \\Examples:
                \\  zagent --model zai/glm-5      Start with zai/glm-5 model
                \\  zagent --resume               Show menu to select from recent sessions
                \\  zagent --resume 56ffe754      Resume session with ID 56ffe754
                \\
            ;
            _ = try std.posix.write(1, help_text);
            return;
        }

        if (std.mem.eql(u8, arg, "--model") or std.mem.eql(u8, arg, "-m")) {
            if (i + 1 < args.len) {
                i += 1;
                model_flag = args[i];
            } else {
                std.debug.print("Error: --model requires PROVIDER/MODEL argument\n", .{});
                return error.MissingArgument;
            }
        } else if (std.mem.startsWith(u8, arg, "--model=")) {
            model_flag = arg["--model=".len..];
        } else if (std.mem.eql(u8, arg, "--resume")) {
            // Check if next argument exists and doesn't start with --
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                resume_session_id = args[i];
            } else {
                resume_session_id = ""; // Empty means show menu
            }
        } else if (std.mem.eql(u8, arg, "--resume=0")) {
            // Handle legacy --resume=0 format
            resume_session_id = "0";
        } else if (std.mem.startsWith(u8, arg, "--resume=")) {
            // Handle legacy --resume=ID format for backward compatibility
            resume_session_id = arg["--resume=".len..];
        }
    }

    // Initialize verbose logging
    const log_path = try paths.getLogPath(allocator);
    defer allocator.free(log_path);

    try logger.init(allocator, .info, log_path);
    defer logger.deinit();

    cancel.init();
    defer cancel.deinit();

    logger.info("zagent starting up", .{});

    // Handle resume if requested
    var resumed_session_hash: ?u64 = null;
    if (resume_session_id) |id| {
        const config_dir = try paths.getConfigDir(allocator);
        defer allocator.free(config_dir);

        if (id.len == 0) {
            // Show menu to select session
            const selected_id = try selectSessionMenu(allocator, config_dir);
            if (selected_id) |sid| {
                logger.info("Resuming session: {s}", .{sid});
                // Try to restore context from the selected session
                var window = context.ContextWindow.init(32000, 20);
                defer window.deinit(allocator);
                
                const project_hash = std.fmt.parseInt(u64, sid, 16) catch {
                    std.debug.print("Invalid session ID: {s}\n", .{sid});
                    return;
                };
                
                if (context.loadContextWindow(allocator, config_dir, &window, project_hash)) {
                    if (window.turns.items.len > 0) {
                        std.debug.print("Resumed session {s} with {d} turns\n", .{sid, window.turns.items.len});
                        resumed_session_hash = project_hash;
                    }
                } else |_| {
                    std.debug.print("Failed to load session: {s}\n", .{sid});
                }
            }
        } else {
            // Use the provided session ID
            logger.info("Resuming session: {s}", .{id});
            var window = context.ContextWindow.init(32000, 20);
            defer window.deinit(allocator);
            
            const project_hash = std.fmt.parseInt(u64, id, 16) catch {
                std.debug.print("Invalid session ID: {s}\n", .{id});
                return;
            };
            
            if (context.loadContextWindow(allocator, config_dir, &window, project_hash)) {
                if (window.turns.items.len > 0) {
                    std.debug.print("Resumed session {s} with {d} turns\n", .{id, window.turns.items.len});
                    resumed_session_hash = project_hash;
                }
            } else |_| {
                std.debug.print("Failed to load session: {s}\n", .{id});
            }
        }
    }

    // Handle --model flag
    if (model_flag) |model_str| {
        const config_dir = try paths.getConfigDir(allocator);
        defer allocator.free(config_dir);

        // Parse model string: "provider/model" or just "model"
        if (std.mem.indexOfScalar(u8, model_str, '/')) |slash_pos| {
            const provider_id = model_str[0..slash_pos];
            const model_id = model_str[slash_pos + 1 ..];
            try config_store.saveSelectedModel(allocator, config_dir, .{
                .provider_id = provider_id,
                .model_id = model_id,
            });
            std.debug.print("Set model: {s}/{s}\n", .{ provider_id, model_id });
        } else {
            std.debug.print("Error: --model format is PROVIDER/MODEL (e.g., zai/glm-5)\n", .{});
            return error.InvalidModelFormat;
        }
    }

    repl.run(allocator, resumed_session_hash) catch |err| {
        // Graceful exit on interrupt or EOF - don't print error trace
        if (err == error.InputOutput or err == error.EndOfStream or err == error.BrokenPipe) {
            return;
        }
        return err;
    };

    // Normal shutdown (deinit handled by defer)
    logger.info("zagent shutting down", .{});
}

fn selectSessionMenu(allocator: std.mem.Allocator, config_dir: []const u8) !?[]const u8 {
    var sessions = try context.listContextSessions(allocator, config_dir);
    defer {
        for (sessions.items) |*s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    if (sessions.items.len == 0) {
        std.debug.print("No recent sessions found.\n", .{});
        return null;
    }

    // Display menu
    std.debug.print("\nRecent sessions:\n", .{});
    std.debug.print("  0. Start fresh session\n", .{});
    
    const display_count = @min(sessions.items.len, 10);
    for (sessions.items[0..display_count], 1..) |s, i| {
        const now = std.time.nanoTimestamp();
        const diff_ns = if (now > s.modified_time) now - s.modified_time else 0;
        const diff_sec = @as(u64, @intCast(@divTrunc(diff_ns, 1_000_000_000)));

        const title = if (s.title) |t| t else "(no title)";

        if (diff_sec < 60) {
            std.debug.print("  {d}. {s} - {s} ({s}) - just now\n", .{ i, s.id, title, s.size_str });
        } else if (diff_sec < 3600) {
            std.debug.print("  {d}. {s} - {s} ({s}) - {d}m ago\n", .{ i, s.id, title, s.size_str, diff_sec / 60 });
        } else if (diff_sec < 86400) {
            std.debug.print("  {d}. {s} - {s} ({s}) - {d}h ago\n", .{ i, s.id, title, s.size_str, diff_sec / 3600 });
        } else if (diff_sec < 86400 * 2) {
            std.debug.print("  {d}. {s} - {s} ({s}) - yesterday\n", .{ i, s.id, title, s.size_str });
        } else {
            std.debug.print("  {d}. {s} - {s} ({s}) - {d}d ago\n", .{ i, s.id, title, s.size_str, diff_sec / 86400 });
        }
    }
    std.debug.print("\nSelect session (0-{d}): ", .{display_count});

    // Read selection from stdin
    var buf: [64]u8 = undefined;
    const stdin = if (@hasDecl(std.io, "getStdIn"))
        std.io.getStdIn()
    else if (@hasDecl(std.fs.File, "stdin"))
        std.fs.File.stdin()
    else
        @compileError("No supported stdin API");
    const count = try stdin.read(&buf);
    const trimmed = std.mem.trim(u8, buf[0..count], " \t\r\n");

    const selection = std.fmt.parseInt(usize, trimmed, 10) catch 0;
    if (selection == 0) {
        return null;
    }
    if (selection > display_count) {
        std.debug.print("Invalid selection.\n", .{});
        return null;
    }

    return try allocator.dupe(u8, sessions.items[selection - 1].id);
}

test {
    _ = @import("config_store.zig");
    _ = @import("llm.zig");
    _ = @import("provider.zig");
    _ = @import("skills.zig");
    _ = @import("repl/main.zig");
    _ = @import("provider_store.zig");
    _ = @import("logger.zig");
    _ = @import("ai_bridge.zig");
}
