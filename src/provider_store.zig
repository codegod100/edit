const std = @import("std");

pub const StoredPair = struct {
    name: []u8,
    value: []u8,

    fn deinit(self: *StoredPair, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub fn free(allocator: std.mem.Allocator, pairs: []StoredPair) void {
    for (pairs) |*pair| pair.deinit(allocator);
    allocator.free(pairs);
}

pub fn load(allocator: std.mem.Allocator, base_path: []const u8) ![]StoredPair {
    const path = try storePathAlloc(allocator, base_path);
    defer allocator.free(path);

    const content = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(StoredPair, 0),
        else => return err,
    };
    defer content.close();

    const data = try content.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(data);

    return parseContent(allocator, data);
}

pub fn upsertFile(allocator: std.mem.Allocator, base_path: []const u8, name: []const u8, value: []const u8) !void {
    const raw_pairs = try load(allocator, base_path);
    var list = try std.ArrayListUnmanaged(StoredPair).initCapacity(allocator, raw_pairs.len);
    try list.appendSlice(allocator, raw_pairs);
    allocator.free(raw_pairs);

    if (value.len == 0) return error.InvalidEnvValue;

    defer {
        for (list.items) |*pair| pair.deinit(allocator);
        list.deinit(allocator);
    }

    var found = false;
    for (list.items) |*pair| {
        if (std.mem.eql(u8, pair.name, name)) {
            allocator.free(pair.value);
            pair.value = try allocator.dupe(u8, value);
            found = true;
            break;
        }
    }

    if (!found) {
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
        });
    }

    const path = try storePathAlloc(allocator, base_path);
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    const writer = if (@hasDecl(std.fs.File, "deprecatedWriter"))
        file.deprecatedWriter()
    else
        file.writer();
    for (list.items) |pair| {
        try writer.print("{s}={s}\n", .{ pair.name, pair.value });
    }
}

const SanitizedValue = struct {
    value: []u8,
    stripped: bool,
};

fn sanitizeEnvValue(allocator: std.mem.Allocator, value: []const u8) !SanitizedValue {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var stripped = false;
    for (value) |ch| {
        if (ch >= 32 and ch <= 126) {
            try out.append(allocator, ch);
        } else {
            stripped = true;
        }
    }
    return .{ .value = try out.toOwnedSlice(allocator), .stripped = stripped };
}

fn parseContent(allocator: std.mem.Allocator, content: []const u8) ![]StoredPair {
    var out = try std.ArrayListUnmanaged(StoredPair).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |*pair| pair.deinit(allocator);
        out.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const idx = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..idx], " \t");
        const val = std.mem.trim(u8, line[idx + 1 ..], " \t");
        if (key.len == 0 or val.len == 0) continue;

        try out.append(allocator, .{
            .name = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, val),
        });
    }

    return out.toOwnedSlice(allocator);
}

fn storePathAlloc(allocator: std.mem.Allocator, base_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_path, "provider.env" });
}

test "upsert file stores and updates provider key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try upsertFile(allocator, root, "OPENAI_API_KEY", "abc");
    try upsertFile(allocator, root, "OPENAI_API_KEY", "xyz");

    const loaded = try load(allocator, root);
    defer free(allocator, loaded);

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", loaded[0].name);
    try std.testing.expectEqualStrings("xyz", loaded[0].value);
}

test "sanitize env value strips non-ascii" {
    const allocator = std.testing.allocator;
    const out = try sanitizeEnvValue(allocator, "sk-abc\x00\x7F\xC2\xA9");
    defer allocator.free(out.value);
    try std.testing.expect(out.stripped);
    try std.testing.expectEqualStrings("sk-abc", out.value);
}
