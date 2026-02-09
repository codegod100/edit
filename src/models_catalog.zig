const std = @import("std");
const pm = @import("provider_manager.zig");

const embedded_models_json = @embedFile("models.dev.json");

pub fn loadProviderSpecs(allocator: std.mem.Allocator, base_path: []const u8) ![]pm.ProviderSpec {
    const path = try std.fs.path.join(allocator, &.{ base_path, "models.dev.json" });
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Write embedded default
            var new_file = try std.fs.createFileAbsolute(path, .{});
            defer new_file.close();
            try new_file.writeAll(embedded_models_json);
            return parseProviderSpecsFromJson(allocator, embedded_models_json);
        },
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    return parseProviderSpecsFromJson(allocator, content);
}

pub fn freeProviderSpecs(allocator: std.mem.Allocator, specs: []pm.ProviderSpec) void {
    for (specs) |spec| {
        allocator.free(spec.id);
        allocator.free(spec.display_name);
        for (spec.env_vars) |env| allocator.free(env);
        allocator.free(spec.env_vars);
        for (spec.models) |m| {
            allocator.free(m.id);
            allocator.free(m.display_name);
        }
        allocator.free(spec.models);
    }
    allocator.free(specs);
}

fn parseProviderSpecsFromJson(allocator: std.mem.Allocator, json_text: []const u8) ![]pm.ProviderSpec {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value != .object) return allocator.alloc(pm.ProviderSpec, 0);

    var specs = try std.ArrayList(pm.ProviderSpec).initCapacity(allocator, 0);
    errdefer {
        for (specs.items) |spec| {
            allocator.free(spec.id);
            allocator.free(spec.display_name);
            for (spec.env_vars) |env| allocator.free(env);
            allocator.free(spec.env_vars);
            for (spec.models) |m| {
                allocator.free(m.id);
                allocator.free(m.display_name);
            }
            allocator.free(spec.models);
        }
        specs.deinit(allocator);
    }

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const obj = entry.value_ptr.object;

        const provider_id = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(provider_id);

        const display_name = if (obj.get("name")) |n|
            if (n == .string) try allocator.dupe(u8, n.string) else try allocator.dupe(u8, entry.key_ptr.*)
        else
            try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(display_name);

        var env_vars = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        errdefer {
            for (env_vars.items) |env| allocator.free(env);
            env_vars.deinit(allocator);
        }
        if (obj.get("env")) |env_json| {
            if (env_json == .array) {
                for (env_json.array.items) |v| {
                    if (v == .string) try env_vars.append(allocator, try allocator.dupe(u8, v.string));
                }
            }
        }

        var models = try std.ArrayList(pm.Model).initCapacity(allocator, 0);
        errdefer {
            for (models.items) |m| {
                allocator.free(m.id);
                allocator.free(m.display_name);
            }
            models.deinit(allocator);
        }
        if (obj.get("models")) |models_json| {
            if (models_json == .object) {
                var mit = models_json.object.iterator();
                while (mit.next()) |mentry| {
                    if (mentry.value_ptr.* != .object) continue;
                    const mobj = mentry.value_ptr.object;
                    const mid = try allocator.dupe(u8, mentry.key_ptr.*);
                    errdefer allocator.free(mid);
                    const mname = if (mobj.get("name")) |mn|
                        if (mn == .string) try allocator.dupe(u8, mn.string) else try allocator.dupe(u8, mentry.key_ptr.*)
                    else
                        try allocator.dupe(u8, mentry.key_ptr.*);
                    errdefer allocator.free(mname);
                    try models.append(allocator, .{ .id = mid, .display_name = mname });
                }
            }
        }

        try specs.append(allocator, .{
            .id = provider_id,
            .display_name = display_name,
            .env_vars = try env_vars.toOwnedSlice(allocator),
            .models = try models.toOwnedSlice(allocator),
        });
    }

    return specs.toOwnedSlice(allocator);
}

test "parse provider specs from models json sample" {
    const allocator = std.testing.allocator;
    const sample =
        \\{
        \\  "openai": {
        \\    "id": "openai",
        \\    "name": "OpenAI",
        \\    "env": ["OPENAI_API_KEY"],
        \\    "models": {
        \\      "gpt-5": {"id": "gpt-5", "name": "GPT-5"}
        \\    }
        \\  }
        \\}
    ;
    const specs = try parseProviderSpecsFromJson(allocator, sample);
    defer freeProviderSpecs(allocator, specs);

    try std.testing.expect(specs.len > 0);
    try std.testing.expectEqualStrings("openai", specs[0].id);
    try std.testing.expectEqualStrings("OpenAI", specs[0].display_name);
    try std.testing.expectEqual(@as(usize, 1), specs[0].models.len);
    try std.testing.expectEqualStrings("gpt-5", specs[0].models[0].id);
}
