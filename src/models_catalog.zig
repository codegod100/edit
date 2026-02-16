const std = @import("std");
const pm = @import("provider_manager.zig");

const embedded_models_json = @embedFile("models.dev.json");

pub fn loadProviderSpecs(allocator: std.mem.Allocator, base_path: []const u8) ![]pm.ProviderSpec {
    const dev_path = try std.fs.path.join(allocator, &.{ base_path, "models.dev.json" });
    defer allocator.free(dev_path);

    const dev_specs: []pm.ProviderSpec = blk: {
        const file = std.fs.openFileAbsolute(dev_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var new_file = try std.fs.createFileAbsolute(dev_path, .{});
                defer new_file.close();
                try new_file.writeAll(embedded_models_json);
                break :blk try parseProviderSpecsFromJson(allocator, embedded_models_json);
            },
            else => return err,
        };
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        break :blk try parseProviderSpecsFromJson(allocator, content);
    };
    errdefer freeProviderSpecs(allocator, dev_specs);

    const user_path = try std.fs.path.join(allocator, &.{ base_path, "models.user.json" });
    defer allocator.free(user_path);

    const user_specs: []pm.ProviderSpec = blk: {
        const file = std.fs.openFileAbsolute(user_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.alloc(pm.ProviderSpec, 0),
            else => return err,
        };
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        break :blk try parseProviderSpecsFromJson(allocator, content);
    };
    defer freeProviderSpecs(allocator, user_specs);

    if (user_specs.len == 0) return dev_specs;

    const merged = try mergeProviderSpecs(allocator, dev_specs, user_specs);
    freeProviderSpecs(allocator, dev_specs);
    return merged;
}

fn mergeProviderSpecs(allocator: std.mem.Allocator, base: []const pm.ProviderSpec, extra: []const pm.ProviderSpec) ![]pm.ProviderSpec {
    var out = try std.ArrayListUnmanaged(pm.ProviderSpec).initCapacity(allocator, base.len);
    errdefer {
        for (out.items) |s| {
            allocator.free(s.id);
            allocator.free(s.display_name);
            for (s.env_vars) |e| allocator.free(e);
            allocator.free(s.env_vars);
            for (s.models) |m| {
                allocator.free(m.id);
                allocator.free(m.display_name);
            }
            allocator.free(s.models);
        }
        out.deinit(allocator);
    }

    // Start with all base specs
    for (base) |s| {
        try out.append(allocator, try dupeSpec(allocator, s));
    }

    // Merge extra specs
    for (extra) |ex| {
        var found: ?*pm.ProviderSpec = null;
        for (out.items) |*s| {
            if (std.mem.eql(u8, s.id, ex.id)) {
                found = s;
                break;
            }
        }

        if (found) |s| {
            // Add models that don't exist
            var new_models = try std.ArrayListUnmanaged(pm.Model).initCapacity(allocator, s.models.len);
            for (s.models) |m| {
                try new_models.append(allocator, try dupeModel(allocator, m));
            }
            for (ex.models) |ex_m| {
                var model_exists = false;
                for (new_models.items) |m| {
                    if (std.mem.eql(u8, m.id, ex_m.id)) {
                        model_exists = true;
                        break;
                    }
                }
                if (!model_exists) {
                    try new_models.append(allocator, try dupeModel(allocator, ex_m));
                }
            }

            // Free old models and swap
            for (s.models) |m| {
                allocator.free(m.id);
                allocator.free(m.display_name);
            }
            allocator.free(s.models);
            s.models = try new_models.toOwnedSlice(allocator);
        } else {
            // New provider
            try out.append(allocator, try dupeSpec(allocator, ex));
        }
    }

    return out.toOwnedSlice(allocator);
}

fn dupeSpec(allocator: std.mem.Allocator, s: pm.ProviderSpec) !pm.ProviderSpec {
    const env_vars = try allocator.alloc([]const u8, s.env_vars.len);
    errdefer {
        for (env_vars) |e| allocator.free(e);
        allocator.free(env_vars);
    }
    for (s.env_vars, 0..) |e, i| env_vars[i] = try allocator.dupe(u8, e);

    const models = try allocator.alloc(pm.Model, s.models.len);
    errdefer {
        for (models) |m| {
            allocator.free(m.id);
            allocator.free(m.display_name);
        }
        allocator.free(models);
    }
    for (s.models, 0..) |m, i| models[i] = try dupeModel(allocator, m);

    return .{
        .id = try allocator.dupe(u8, s.id),
        .display_name = try allocator.dupe(u8, s.display_name),
        .env_vars = env_vars,
        .models = models,
    };
}

fn dupeModel(allocator: std.mem.Allocator, m: pm.Model) !pm.Model {
    return .{
        .id = try allocator.dupe(u8, m.id),
        .display_name = try allocator.dupe(u8, m.display_name),
    };
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

    var specs = try std.ArrayListUnmanaged(pm.ProviderSpec).initCapacity(allocator, 0);
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

        var env_vars = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, 0);
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

        var models = try std.ArrayListUnmanaged(pm.Model).initCapacity(allocator, 0);
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
