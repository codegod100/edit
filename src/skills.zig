const std = @import("std");

pub const Skill = struct {
    name: []u8,
    path: []u8,
    body: []u8,

    pub fn deinit(self: *Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.body);
    }
};

pub fn discover(allocator: std.mem.Allocator, project_root: []const u8, home_dir: []const u8) ![]Skill {
    var out = try std.ArrayListUnmanaged(Skill).initCapacity(allocator, 16);
    errdefer {
        for (out.items) |*s| s.deinit(allocator);
        out.deinit(allocator);
    }

    const project_base = try std.fs.path.join(allocator, &.{ project_root, ".opencode", "skills" });
    defer allocator.free(project_base);
    try scanBase(allocator, project_base, &out, .project);

    const home_base = try std.fs.path.join(allocator, &.{ home_dir, ".config", "opencode", "skills" });
    defer allocator.free(home_base);
    try scanBase(allocator, home_base, &out, .home);

    return out.toOwnedSlice(allocator);
}

pub fn findByName(skills: []Skill, name: []const u8) ?*Skill {
    for (skills) |*skill| {
        if (std.mem.eql(u8, skill.name, name)) return skill;
    }
    return null;
}

pub fn freeList(allocator: std.mem.Allocator, skills: []Skill) void {
    for (skills) |*skill| {
        skill.deinit(allocator);
    }
    allocator.free(skills);
}

const SkillSource = enum {
    project,
    home,
};

fn scanBase(allocator: std.mem.Allocator, base_path: []const u8, out: *std.ArrayListUnmanaged(Skill), source: SkillSource) !void {
    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(entry.path), "SKILL.md")) continue;

        const parent = std.fs.path.dirname(entry.path) orelse continue;
        const name_part = std.fs.path.basename(parent);
        if (name_part.len == 0) continue;
        if (source == .home and isBlockedHomeSkill(name_part)) continue;
        if (findByName(out.items, name_part) != null) continue;

        const body = try dir.readFileAlloc(allocator, entry.path, 1024 * 1024);
        errdefer allocator.free(body);

        const name = try allocator.dupe(u8, name_part);
        errdefer allocator.free(name);

        const full_path = try std.fs.path.join(allocator, &.{ base_path, entry.path });
        errdefer allocator.free(full_path);

        try out.append(allocator, .{
            .name = name,
            .path = full_path,
            .body = body,
        });
    }
}

fn isBlockedHomeSkill(name: []const u8) bool {
    return std.mem.eql(u8, name, "brainstorming") or std.mem.eql(u8, name, "test-driven-development");
}

test "discover finds project and global opencode skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".opencode/skills/project-skill");
    try tmp.dir.makePath("home/.config/opencode/skills/global-skill");

    {
        var f = try tmp.dir.createFile(".opencode/skills/project-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll(
            "# Project Skill\n\nproject body\n",
        );
    }

    {
        var f = try tmp.dir.createFile("home/.config/opencode/skills/global-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll(
            "# Global Skill\n\nglobal body\n",
        );
    }

    const allocator = std.testing.allocator;
    const project_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    const home_dir = try tmp.dir.realpathAlloc(allocator, "home");
    defer allocator.free(home_dir);

    const discovered = try discover(allocator, project_root, home_dir);
    defer freeList(allocator, discovered);

    try std.testing.expectEqual(@as(usize, 2), discovered.len);

    const project = findByName(discovered, "project-skill");
    try std.testing.expect(project != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, project.?.body, 1, "project body"));

    const global = findByName(discovered, "global-skill");
    try std.testing.expect(global != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, global.?.body, 1, "global body"));
}

test "discover excludes blocked skills from home" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".opencode/skills/project-skill");
    try tmp.dir.makePath("home/.config/opencode/skills/brainstorming");
    try tmp.dir.makePath("home/.config/opencode/skills/test-driven-development");
    try tmp.dir.makePath("home/.config/opencode/skills/allowed-skill");

    {
        var f = try tmp.dir.createFile(".opencode/skills/project-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll("project");
    }
    {
        var f = try tmp.dir.createFile("home/.config/opencode/skills/brainstorming/SKILL.md", .{});
        defer f.close();
        try f.writeAll("blocked");
    }
    {
        var f = try tmp.dir.createFile("home/.config/opencode/skills/test-driven-development/SKILL.md", .{});
        defer f.close();
        try f.writeAll("blocked");
    }
    {
        var f = try tmp.dir.createFile("home/.config/opencode/skills/allowed-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll("allowed");
    }

    const allocator = std.testing.allocator;
    const project_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);
    const home_dir = try tmp.dir.realpathAlloc(allocator, "home");
    defer allocator.free(home_dir);

    const discovered = try discover(allocator, project_root, home_dir);
    defer freeList(allocator, discovered);

    try std.testing.expect(findByName(discovered, "brainstorming") == null);
    try std.testing.expect(findByName(discovered, "test-driven-development") == null);
    try std.testing.expect(findByName(discovered, "allowed-skill") != null);
}
