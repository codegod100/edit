const std = @import("std");

pub fn sparkline(allocator: std.mem.Allocator, values: []const i64, width: usize) ![]u8 {
    if (values.len == 0 or width == 0) return allocator.dupe(u8, "");

    const blocks = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    const n = @min(width, values.len);

    var max_v: i64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const idx = @min(values.len - 1, (i * values.len) / n);
        if (values[idx] > max_v) max_v = values[idx];
    }
    if (max_v <= 0) max_v = 1;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    i = 0;
    while (i < n) : (i += 1) {
        const idx = @min(values.len - 1, (i * values.len) / n);
        const v = if (values[idx] > 0) values[idx] else 0;
        const level = @as(usize, @intCast(@divTrunc(v * @as(i64, @intCast(blocks.len - 1)), max_v)));
        try out.appendSlice(allocator, blocks[@min(level, blocks.len - 1)]);
    }
    return out.toOwnedSlice(allocator);
}

pub fn pctBar(allocator: std.mem.Allocator, pct_raw: i64, width: usize) ![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    const pct = @max(@as(i64, 0), @min(@as(i64, 100), pct_raw));
    const filled: usize = @intCast(@divTrunc(pct * @as(i64, @intCast(width)), 100));

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if (i < filled) {
            try out.appendSlice(allocator, "█");
        } else {
            try out.appendSlice(allocator, "░");
        }
    }
    try out.append(allocator, ']');
    try out.writer(allocator).print(" {d}%", .{pct});
    return out.toOwnedSlice(allocator);
}
