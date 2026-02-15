const std = @import("std");
const logger = @import("../logger.zig");

var last_provider_error_buf: [512]u8 = undefined;
var last_provider_error_len: usize = 0;

pub fn setLastProviderError(msg: []const u8) void {
    const n = @min(msg.len, last_provider_error_buf.len);
    @memcpy(last_provider_error_buf[0..n], msg[0..n]);
    last_provider_error_len = n;
}

pub fn getLastProviderError() ?[]const u8 {
    if (last_provider_error_len == 0) return null;
    return last_provider_error_buf[0..last_provider_error_len];
}

pub fn clearLastProviderError() void {
    last_provider_error_len = 0;
}

pub const ProviderError = error{
    ModelProviderError,
    ModelResponseParseError,
    ModelResponseMissingChoices,
    UnsupportedProvider,
};
