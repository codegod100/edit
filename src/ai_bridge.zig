const std = @import("std");
const logger = @import("logger.zig");

pub const ToolCall = struct {
    id: []const u8,
    tool: []const u8,
    args: []const u8,
};

pub const ChatResponse = struct {
    text: []const u8,
    tool_calls: []ToolCall,
    finish_reason: []const u8,
};

pub const Bridge = struct {
    child: std.process.Child,
    allocator: std.mem.Allocator,
    env_map: std.process.EnvMap,
    stderr_thread: ?std.Thread = null,

    pub fn spawn(allocator: std.mem.Allocator, api_key: []const u8, model_id: []const u8, provider_id: []const u8) !Bridge {
        const self_exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch try allocator.dupe(u8, ".");
        defer allocator.free(self_exe_dir);
        const bridge_path = try std.fs.path.join(allocator, &.{ self_exe_dir, "..", "..", "ai-bridge.ts" });
        defer allocator.free(bridge_path);

        var env_map = std.process.EnvMap.init(allocator);
        defer env_map.deinit();
        // Log API key (masked)
        logger.info("Bridge spawning with provider={s}, model={s}, api_key_len={d}", .{ provider_id, model_id, api_key.len });

        // Pass all API keys from providers.env
        try env_map.put("OPENCODE_API_KEY", api_key);
        try env_map.put("OPENROUTER_API_KEY", api_key);
        try env_map.put("ZAGENT_API_KEY", api_key);
        try env_map.put("ZAGENT_MODEL", model_id);
        try env_map.put("ZAGENT_PROVIDER", provider_id);

        var child = std.process.Child.init(&.{ "bun", "run", bridge_path }, allocator);

        // Copy env vars to child process
        var env_copy = std.process.EnvMap.init(allocator);
        var it = env_map.iterator();
        while (it.next()) |entry| {
            try env_copy.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        child.env_map = &env_copy;

        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        // Spawn stderr reader thread
        const stderr_thread = try std.Thread.spawn(.{}, readStderr, .{child.stderr.?});

        // Wait for ready signal from stdout
        const stdout_reader = if (@hasDecl(std.fs.File, "deprecatedReader"))
            child.stdout.?.deprecatedReader()
        else
            child.stdout.?.reader();
        const ready_line = try stdout_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
        if (ready_line) |line| {
            defer allocator.free(line);
            logger.info("Bridge ready: {s}", .{line});
        }

        return .{
            .child = child,
            .allocator = allocator,
            .env_map = env_copy,
            .stderr_thread = stderr_thread,
        };
    }

    fn readStderr(stderr_file: std.fs.File) void {
        const allocator = std.heap.page_allocator;
        const stderr_reader = if (@hasDecl(std.fs.File, "deprecatedReader"))
            stderr_file.deprecatedReader()
        else
            stderr_file.reader();

        while (true) {
            const line = stderr_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024) catch break;
            if (line) |l| {
                defer allocator.free(l);
                if (l.len > 0) {
                    logger.info("Bridge: {s}", .{l});
                }
            } else break;
        }
    }

    pub fn chat(self: *Bridge, messages: []const u8, max_steps: usize) !ChatResponse {
        const stdin_file = self.child.stdin.?;
        const stdout_file = self.child.stdout.?;

        // Get reader/writer
        const stdin_writer = if (@hasDecl(std.fs.File, "deprecatedWriter"))
            stdin_file.deprecatedWriter()
        else
            stdin_file.writer();
        const stdout_reader = if (@hasDecl(std.fs.File, "deprecatedReader"))
            stdout_file.deprecatedReader()
        else
            stdout_file.reader();

        // Send request
        var request_buf = std.ArrayListUnmanaged(u8).empty;
        defer request_buf.deinit(self.allocator);
        const w = request_buf.writer(self.allocator);
        try w.writeAll("{\"type\":\"chat\",\"messages\":");
        try w.writeAll(messages);
        try w.print(",\"maxSteps\":{d}}}", .{max_steps});
        try w.writeByte('\n');

        logger.info("Sending request: {s}", .{request_buf.items});

        const debug_file = std.fs.cwd().createFile("debug_payload.json", .{}) catch null;
        if (debug_file) |f| {
            f.writeAll(request_buf.items) catch {};
            f.close();
        }

        try stdin_writer.writeAll(request_buf.items);

        logger.info("Request sent, waiting for response...", .{});

        // Read response line
        const line = try stdout_reader.readUntilDelimiterOrEofAlloc(self.allocator, '\n', 10 * 1024 * 1024);
        if (line == null) return error.BridgeClosed;
        defer self.allocator.free(line.?);

        // Parse JSON response
        const Response = struct {
            type: []const u8,
            text: ?[]const u8 = null,
            toolCalls: ?[]struct {
                id: []const u8,
                tool: []const u8,
                args: std.json.Value,
            } = null,
            finishReason: ?[]const u8 = null,
            err: ?[]const u8 = null,
        };

        var parsed = try std.json.parseFromSlice(Response, self.allocator, line.?, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        if (parsed.value.err) |err| {
            logger.err("Bridge error: {s}", .{err});
            return error.BridgeError;
        }

        // Convert tool calls
        var tool_calls = std.ArrayListUnmanaged(ToolCall).empty;
        errdefer {
            for (tool_calls.items) |tc| {
                self.allocator.free(tc.id);
                self.allocator.free(tc.tool);
                self.allocator.free(tc.args);
            }
            tool_calls.deinit(self.allocator);
        }

        if (parsed.value.toolCalls) |tcs| {
            for (tcs) |tc| {
                // Convert args Value back to JSON string
                const args_json = switch (tc.args) {
                    .string => |s| try self.allocator.dupe(u8, s),
                    else => try std.fmt.allocPrint(self.allocator, "{}", .{tc.args}),
                };
                try tool_calls.append(self.allocator, .{
                    .id = try self.allocator.dupe(u8, tc.id),
                    .tool = try self.allocator.dupe(u8, tc.tool),
                    .args = args_json,
                });
            }
        }

        return .{
            .text = try self.allocator.dupe(u8, parsed.value.text orelse ""),
            .tool_calls = try tool_calls.toOwnedSlice(self.allocator),
            .finish_reason = try self.allocator.dupe(u8, parsed.value.finishReason orelse "unknown"),
        };
    }

    pub fn deinit(self: *Bridge) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        if (self.stderr_thread) |thread| {
            thread.join();
        }
        self.env_map.deinit();
    }
};
