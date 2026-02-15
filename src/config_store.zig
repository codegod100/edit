const std = @import("std");

pub const SelectedModel = struct {
    provider_id: []u8,
    model_id: []u8,
    reasoning_effort: ?[]u8 = null,

    pub fn deinit(self: *SelectedModel, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model_id);
        if (self.reasoning_effort) |e| allocator.free(e);
    }
};

pub const ModelRef = struct {
    provider_id: []const u8,
    model_id: []const u8,
    reasoning_effort: ?[]const u8 = null,
};

pub fn loadSelectedModel(allocator: std.mem.Allocator, base_path: []const u8) !?SelectedModel {
    const path = try configPathAlloc(allocator, base_path);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const text = try file.readToEndAlloc(allocator, 256 * 1024);
    defer allocator.free(text);

    const SelectedModelJson = struct {
        provider_id: []const u8,
        model_id: []const u8,
        reasoning_effort: ?[]const u8 = null,
    };
    const Json = struct {
        selected_model: ?SelectedModelJson = null,
    };

    var parsed = std.json.parseFromSlice(Json, allocator, text, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const sm = parsed.value.selected_model orelse return null;
    return .{
        .provider_id = try allocator.dupe(u8, sm.provider_id),
        .model_id = try allocator.dupe(u8, sm.model_id),
        .reasoning_effort = if (sm.reasoning_effort) |e| try allocator.dupe(u8, e) else null,
    };
}

pub fn saveSelectedModel(allocator: std.mem.Allocator, base_path: []const u8, model: ?ModelRef) !void {
    const path = try configPathAlloc(allocator, base_path);
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();

    const SelectedModelJson = struct {
        provider_id: []const u8,
        model_id: []const u8,
        reasoning_effort: ?[]const u8 = null,
    };
    const Payload = struct {
        selected_model: ?SelectedModelJson,
    };

    const payload: Payload = if (model) |m|
        .{ .selected_model = .{
            .provider_id = m.provider_id,
            .model_id = m.model_id,
            .reasoning_effort = m.reasoning_effort,
        } }
    else
        .{ .selected_model = null };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.writer(allocator).print("{f}\n", .{std.json.fmt(payload, .{})});
    try file.writeAll(buf.items);
}

fn configPathAlloc(allocator: std.mem.Allocator, base_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_path, "config.json" });
}

test "save and load selected model" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try saveSelectedModel(allocator, root, .{ .provider_id = "openai", .model_id = "gpt-5.3-codex" });
    const loaded = try loadSelectedModel(allocator, root);
    try std.testing.expect(loaded != null);
    if (loaded) |persisted| {
        var p = persisted;
        defer p.deinit(allocator);
    }
    try std.testing.expectEqualStrings("openai", loaded.?.provider_id);
    try std.testing.expectEqualStrings("gpt-5.3-codex", loaded.?.model_id);
}
