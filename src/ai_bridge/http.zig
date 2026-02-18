const std = @import("std");

pub fn httpRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    var all_headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer all_headers.deinit(allocator);
    try all_headers.ensureTotalCapacity(allocator, extra_headers.len + 1);

    var has_ae = false;
    for (extra_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "accept-encoding")) has_ae = true;
        try all_headers.append(allocator, h);
    }
    if (!has_ae) {
        try all_headers.append(allocator, .{ .name = "accept-encoding", .value = "identity" });
    }

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .headers = headers,
        .extra_headers = all_headers.items,
        .payload = payload,
        .response_writer = &allocating_writer.writer,
    });

    return try allocating_writer.toOwnedSlice();
}
