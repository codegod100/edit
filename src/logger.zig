const std = @import("std");

pub const LogLevel = enum {
    debug,
    info,
    warn,
    err,
};

var log_level: LogLevel = .info;
var log_file: ?std.fs.File = null;
var transcript_file: ?std.fs.File = null;
var session_id_buf: [32]u8 = undefined;
var session_id_len: usize = 0;

pub fn getSessionID() []const u8 {
    return session_id_buf[0..session_id_len];
}

pub fn init(_allocator: std.mem.Allocator, level: LogLevel, file_path: ?[]const u8) !void {
    _ = _allocator;
    log_level = level;

    if (file_path) |path| {
        log_file = try std.fs.createFileAbsolute(path, .{ .truncate = false });
        try log_file.?.seekFromEnd(0);

        // Generate unique Session ID (timestamp-based)
        const now = std.time.timestamp();
        const sid = try std.fmt.bufPrint(&session_id_buf, "{d}", .{@as(u64, @intCast(now))});
        session_id_len = sid.len;

        // Also initialize transcript in the same directory
        const dir = std.fs.path.dirname(path) orelse return;
        const transcript_name = try std.fmt.allocPrint(std.heap.page_allocator, "transcript_{s}.txt", .{sid});
        defer std.heap.page_allocator.free(transcript_name);
        
        const transcript_path = try std.fs.path.join(std.heap.page_allocator, &.{ dir, transcript_name });
        defer std.heap.page_allocator.free(transcript_path);
        
        transcript_file = try std.fs.createFileAbsolute(transcript_path, .{ .truncate = false });
        try transcript_file.?.seekFromEnd(0);
        
        var ts_buf: [32]u8 = undefined;
        const ts = timestamp(&ts_buf) catch "UNKNOWN";
        try transcriptWrite("\n--- Session Started: {s} (ID: {s}) ---\n", .{ts, sid});
    }
}

pub fn deinit() void {
    if (log_file) |f| {
        f.close();
        log_file = null;
    }
    if (transcript_file) |f| {
        f.close();
        transcript_file = null;
    }
}

pub fn transcriptWrite(comptime fmt: []const u8, args: anytype) !void {
    if (transcript_file) |f| {
        const msg = try std.fmt.allocPrint(std.heap.page_allocator, fmt, args);
        defer std.heap.page_allocator.free(msg);
        _ = try f.write(msg);
    }
}

fn shouldLog(level: LogLevel) bool {
    return @intFromEnum(level) >= @intFromEnum(log_level);
}

fn timestamp(buf: []u8) ![]const u8 {
    const now = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn logInternal(level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (!shouldLog(level)) return;

    const level_str = switch (level) {
        .debug => "DEBUG",
        .info => "INFO",
        .warn => "WARN",
        .err => "ERROR",
    };

    var ts_buf: [32]u8 = undefined;
    const ts = timestamp(&ts_buf) catch "UNKNOWN";

    // Log to stderr only if no log file is open
    if (log_file == null) {
        std.debug.print("[{s}] {s}: " ++ fmt ++ "\n", .{ ts, level_str } ++ args);
    }

    // Log to file if available
    if (log_file) |f| {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, "[{s}] {s}: " ++ fmt ++ "\n", .{ ts, level_str } ++ args) catch return;
        defer std.heap.page_allocator.free(msg);
        _ = f.write(msg) catch {};
    }
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    logInternal(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    logInternal(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    logInternal(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    logInternal(.err, fmt, args);
}

pub fn logErrorWithContext(
    comptime src: std.builtin.SourceLocation,
    error_val: anytype,
    context: []const u8,
    extra: ?[]const u8,
) void {
    const error_name = @errorName(error_val);

    err("Error in {s}:{d} ({s}): {s}", .{
        src.file,
        src.line,
        src.fn_name,
        error_name,
    });

    if (context.len > 0) {
        err("  Context: {s}", .{context});
    }

    if (extra) |e| {
        err("  Details: {s}", .{e});
    }
}

pub fn logApiError(
    provider: []const u8,
    endpoint: []const u8,
    status_code: ?u16,
    response_body: ?[]const u8,
    error_val: anyerror,
) void {
    err("API Error - Provider: {s}, Endpoint: {s}", .{ provider, endpoint });

    if (status_code) |code| {
        err("  HTTP Status: {d}", .{code});
    }

    err("  Error Type: {s}", .{@errorName(error_val)});

    if (response_body) |body| {
        const truncated = if (body.len > 200) body[0..200] else body;
        err("  Response: {s}{s}", .{ truncated, if (body.len > 200) "..." else "" });
    }
}

pub fn logToolExecution(
    tool_name: []const u8,
    args_json: []const u8,
    success: bool,
    result: ?[]const u8,
    error_val: ?anyerror,
) void {
    if (success) {
        info("Tool Success: {s}", .{tool_name});
        if (result) |r| {
            const truncated = if (r.len > 100) r[0..100] else r;
            debug("  Result: {s}{s}", .{ truncated, if (r.len > 100) "..." else "" });
        }
    } else {
        err("Tool Failed: {s}", .{tool_name});
        if (error_val) |e| {
            err("  Error: {s}", .{@errorName(e)});
        }
    }

    const args_truncated = if (args_json.len > 100) args_json[0..100] else args_json;
    debug("  Args: {s}{s}", .{ args_truncated, if (args_json.len > 100) "..." else "" });
}

pub fn logModelRequest(
    provider: []const u8,
    model: []const u8,
    prompt_len: usize,
    use_tools: bool,
) void {
    info("Model Request - Provider: {s}, Model: {s}, Prompt: {d} bytes, Tools: {s}", .{
        provider,
        model,
        prompt_len,
        if (use_tools) "yes" else "no",
    });
}

pub fn logModelResponse(
    provider: []const u8,
    model: []const u8,
    response_len: usize,
    tool_calls: usize,
    duration_ms: i64,
) void {
    info("Model Response - Provider: {s}, Model: {s}, Response: {d} bytes, Tool Calls: {d}, Duration: {d}ms", .{
        provider,
        model,
        response_len,
        tool_calls,
        duration_ms,
    });
}
