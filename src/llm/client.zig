const std = @import("std");
// Use relative path to cancel.zig one level up
const cancel = @import("../cancel.zig");
const types = @import("types.zig");

const HttpRequestContext = struct {
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
    result: union(enum) { success: []u8, err: anyerror },
    done: std.Thread.ResetEvent,
};

fn httpRequestThread(ctx: *HttpRequestContext) void {
    var client = std.http.Client{ .allocator = ctx.allocator };
    defer client.deinit();

    // Use .fetch with allocating writer adapter
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var allocating_writer = std.Io.Writer.Allocating.fromArrayList(ctx.allocator, &out);

    var h: std.ArrayList(std.http.Header) = .empty;
    defer h.deinit(ctx.allocator);
    h.appendSlice(ctx.allocator, ctx.extra_headers) catch {};

    const result = client.fetch(.{
        .location = .{ .url = ctx.url },
        .method = ctx.method,
        .headers = ctx.headers,
        .extra_headers = h.items,
        .payload = ctx.payload,
        .response_writer = &allocating_writer.writer,
    });

    if (result) |res| {
        std.log.debug("HTTP status: {d}", .{@intFromEnum(res.status)});
        const data = out.toOwnedSlice(ctx.allocator) catch {
            out.deinit(ctx.allocator);
            ctx.result = .{ .err = types.QueryError.OutOfMemory };
            ctx.done.set();
            return;
        };
        ctx.result = .{ .success = data };
    } else |e| {
        out.deinit(ctx.allocator);
        ctx.result = .{ .err = e };
    }
    ctx.done.set();
}

pub fn httpRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) ![]u8 {
    cancel.enableRawMode();
    defer cancel.disableRawMode();

    if (cancel.isCancelled()) return types.QueryError.Cancelled;

    var ctx = HttpRequestContext{
        .allocator = allocator,
        .method = method,
        .url = url,
        .headers = headers,
        .extra_headers = extra_headers,
        .payload = payload,
        .result = .{ .err = types.QueryError.ThreadPanic },
        .done = std.Thread.ResetEvent{},
    };

    const thread = try std.Thread.spawn(.{}, httpRequestThread, .{&ctx});
    defer thread.detach();

    while (true) {
        if (cancel.isCancelled()) return types.QueryError.Cancelled;
        if (ctx.done.isSet()) break;
        cancel.pollForEscape();
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    switch (ctx.result) {
        .success => |d| return d,
        .err => |e| return e,
    }
}
