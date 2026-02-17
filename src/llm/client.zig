const std = @import("std");
const cancel = @import("../cancel.zig");
const types = @import("types.zig");

const MAX_RETRIES = 3;
const RETRY_DELAY_MS = 1000;

pub const HttpError = error{
    TooManyRetries,
    NetworkError,
    AuthenticationError,
    RateLimited,
    ServerError,
    EmptyResponse,
} || std.http.Client.FetchError;

pub fn httpRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) ![]u8 {
    var last_error: ?anyerror = null;

    var retry_count: u32 = 0;
    while (retry_count < MAX_RETRIES) : (retry_count += 1) {
        if (retry_count > 0) {
            std.Thread.sleep(RETRY_DELAY_MS * std.time.ns_per_ms * retry_count);
        }

        return tryRequest(allocator, method, url, headers, extra_headers, payload) catch |err| {
            last_error = err;

            // Don't retry on authentication errors or client errors (4xx except 429)
            if (err == error.AuthenticationError or
                err == error.BadRequest or
                err == error.Unauthorized or
                err == error.Forbidden)
            {
                return err;
            }

            // Retry on network errors, server errors, rate limiting, and empty responses
            if (err == error.NetworkError or
                err == error.ServerError or
                err == error.RateLimited or
                err == error.EmptyResponse or
                err == error.ConnectionTimedOut or
                err == error.ConnectionResetByPeer)
            {
                continue;
            }

            // For other errors, try once more then give up
            if (retry_count < MAX_RETRIES - 1) {
                continue;
            }

            return err;
        };
    }

    std.log.err("HTTP request failed after {d} retries: {any}", .{ MAX_RETRIES, last_error });
    return error.TooManyRetries;
}

fn tryRequest(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
    payload: ?[]const u8,
) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var allocating_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &out);

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

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .headers = headers,
        .extra_headers = all_headers.items,
        .payload = payload,
        .response_writer = &allocating_writer.writer,
    }) catch |err| {
        std.log.debug("HTTP fetch error: {any}", .{err});
        return mapError(err);
    };

    if (result.status != .ok) {
        if (result.status == .unauthorized) return error.AuthenticationError;
        if (result.status == .too_many_requests) return error.RateLimited;
        if (@intFromEnum(result.status) >= 500) return error.ServerError;
        return error.BadRequest;
    }

    if (out.items.len == 0) {
        out.deinit(allocator);
        return error.EmptyResponse;
    }

    return out.toOwnedSlice(allocator);
}

fn mapError(err: anyerror) anyerror {
    return switch (err) {
        error.ConnectionTimedOut,
        error.ConnectionResetByPeer,
        error.NetworkUnreachable,
        error.ConnectionRefused,
        => error.NetworkError,
        error.UnexpectedEof,
        error.EndOfStream,
        => error.EmptyResponse,
        else => err,
    };
}
