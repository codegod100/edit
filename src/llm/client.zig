const std = @import("std");
const cancel = @import("../cancel.zig");
const types = @import("types.zig");

pub fn httpRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) ![]u8 {
    // Use curl subprocess as workaround for Zig HTTP client bug
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "curl");
    try argv.append(allocator, "-s");
    try argv.append(allocator, "-X");
    try argv.append(allocator, @tagName(method));

    // Add Authorization header
    const auth_str = switch (headers.authorization) {
        .override => |v| v,
        else => null,
    };
    if (auth_str) |a| {
        const header = try std.fmt.allocPrint(allocator, "Authorization: {s}", .{a});
        defer allocator.free(header);
        try argv.append(allocator, "-H");
        try argv.append(allocator, header);
    }
    
    // Add Content-Type header
    const ct_str = switch (headers.content_type) {
        .override => |v| v,
        else => null,
    };
    if (ct_str) |c| {
        const header = try std.fmt.allocPrint(allocator, "Content-Type: {s}", .{c});
        defer allocator.free(header);
        try argv.append(allocator, "-H");
        try argv.append(allocator, header);
    }
    
    // Add extra headers
    for (extra_headers) |h| {
        const header = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ h.name, h.value });
        defer allocator.free(header);
        try argv.append(allocator, "-H");
        try argv.append(allocator, header);
    }

    // Add payload
    if (payload) |p| {
        try argv.append(allocator, "-d");
        try argv.append(allocator, p);
    }

    try argv.append(allocator, url);

    // Debug: log curl command
    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(allocator);
    const cmd_writer = cmd_buf.writer(allocator);
    
    for (argv.items, 0..) |arg, i| {
        if (i > 0) try cmd_writer.writeAll(" ");
        if (std.mem.indexOf(u8, arg, "Bearer")) |_| {
            try cmd_writer.writeAll("-H 'Authorization: Bearer ...'");
        } else {
            try cmd_writer.writeAll(arg);
        }
    }
    std.log.debug("Curl command: {s}", .{cmd_buf.items});

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    var stdout_arr: std.ArrayList(u8) = .empty;
    var stderr_arr: std.ArrayList(u8) = .empty;
    defer stdout_arr.deinit(allocator);
    defer stderr_arr.deinit(allocator);

    try child.collectOutput(allocator, &stdout_arr, &stderr_arr, 10 * 1024 * 1024);

    const term = try child.wait();

    if (term.Exited != 0) {
        std.log.err("curl failed: {s}", .{stderr_arr.items});
        return error.CurlFailed;
    }

    if (stdout_arr.items.len == 0) {
        return error.EmptyResponse;
    }

    // Debug: log response preview
    if (stdout_arr.items.len > 0) {
        std.log.debug("Response: {s}", .{stdout_arr.items[0..@min(stdout_arr.items.len, 200)]});
    }

    return try stdout_arr.toOwnedSlice(allocator);
}
