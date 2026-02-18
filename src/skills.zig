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

pub fn discover(allocator: std.mem.Allocator, project_root: []const u8, config_dir: []const u8) ![]Skill {
    var out = try std.ArrayListUnmanaged(Skill).initCapacity(allocator, 16);
    errdefer {
        for (out.items) |*s| s.deinit(allocator);
        out.deinit(allocator);
    }

    const abs_project_root = if (std.fs.path.isAbsolute(project_root))
        try allocator.dupe(u8, project_root)
    else
        try std.fs.cwd().realpathAlloc(allocator, project_root);
    defer allocator.free(abs_project_root);

    const project_base = try std.fs.path.join(allocator, &.{ abs_project_root, ".zagent", "skills" });
    defer allocator.free(project_base);
    try scanBase(allocator, project_base, &out);

    const config_base = try std.fs.path.join(allocator, &.{ config_dir, "skills" });
    defer allocator.free(config_base);
    try scanBase(allocator, config_base, &out);

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

pub fn isTriggeredByInput(name: []const u8, input: []const u8) bool {
    if (name.len == 0 or input.len == 0) return false;

    // Explicit mention: "$skill-name"
    var i: usize = 0;
    while (i + 1 + name.len <= input.len) : (i += 1) {
        if (input[i] != '$') continue;
        if (!sliceEqlIgnoreCase(input[i + 1 .. i + 1 + name.len], name)) continue;
        const end = i + 1 + name.len;
        if (end == input.len or !isNameChar(input[end])) return true;
    }

    // Plain mention with token boundaries.
    i = 0;
    while (i + name.len <= input.len) : (i += 1) {
        if (!sliceEqlIgnoreCase(input[i .. i + name.len], name)) continue;
        const left_ok = i == 0 or !isNameChar(input[i - 1]);
        const right_idx = i + name.len;
        const right_ok = right_idx == input.len or !isNameChar(input[right_idx]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

pub fn isHintedByInput(name: []const u8, input: []const u8) bool {
    if (name.len == 0 or input.len == 0) return false;
    if (!containsWordIgnoreCase(input, "skill")) return false;

    var tok_start: ?usize = null;
    var i: usize = 0;
    while (i <= input.len) : (i += 1) {
        const at_end = i == input.len;
        const c = if (!at_end) input[i] else 0;
        const is_char = !at_end and isNameChar(c);
        if (is_char and tok_start == null) tok_start = i;
        if (!is_char or at_end) {
            if (tok_start) |s| {
                const tok = input[s..i];
                tok_start = null;
                if (tok.len < 3) continue;
                if (equalsIgnoreCase(tok, "skill") or
                    equalsIgnoreCase(tok, "use") or
                    equalsIgnoreCase(tok, "with") or
                    equalsIgnoreCase(tok, "for") or
                    equalsIgnoreCase(tok, "the") or
                    equalsIgnoreCase(tok, "this") or
                    equalsIgnoreCase(tok, "that") or
                    equalsIgnoreCase(tok, "create") or
                    equalsIgnoreCase(tok, "make") or
                    equalsIgnoreCase(tok, "build") or
                    equalsIgnoreCase(tok, "write"))
                {
                    continue;
                }
                if (containsIgnoreCase(name, tok)) return true;
            }
        }
    }
    return false;
}

pub fn nameContainsIgnoreCase(name: []const u8, needle: []const u8) bool {
    return containsIgnoreCase(name, needle);
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_';
}

fn sliceEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    return sliceEqlIgnoreCase(a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (sliceEqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn containsWordIgnoreCase(haystack: []const u8, word: []const u8) bool {
    if (word.len == 0 or haystack.len < word.len) return false;
    var i: usize = 0;
    while (i + word.len <= haystack.len) : (i += 1) {
        if (!sliceEqlIgnoreCase(haystack[i .. i + word.len], word)) continue;
        const left_ok = i == 0 or !isNameChar(haystack[i - 1]);
        const right_idx = i + word.len;
        const right_ok = right_idx == haystack.len or !isNameChar(haystack[right_idx]);
        if (left_ok and right_ok) return true;
    }
    return false;
}

fn scanBase(allocator: std.mem.Allocator, base_path: []const u8, out: *std.ArrayListUnmanaged(Skill)) !void {
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

test "discover finds project and config skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".zagent/skills/project-skill");
    try tmp.dir.makePath("cfg/skills/global-skill");

    {
        var f = try tmp.dir.createFile(".zagent/skills/project-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll(
            "# Project Skill\n\nproject body\n",
        );
    }

    {
        var f = try tmp.dir.createFile("cfg/skills/global-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll(
            "# Global Skill\n\nglobal body\n",
        );
    }

    const allocator = std.testing.allocator;
    const project_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);

    const config_dir = try tmp.dir.realpathAlloc(allocator, "cfg");
    defer allocator.free(config_dir);

    const discovered = try discover(allocator, project_root, config_dir);
    defer freeList(allocator, discovered);

    try std.testing.expectEqual(@as(usize, 2), discovered.len);

    const project = findByName(discovered, "project-skill");
    try std.testing.expect(project != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, project.?.body, 1, "project body"));

    const global = findByName(discovered, "global-skill");
    try std.testing.expect(global != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, global.?.body, 1, "global body"));
}

test "discover de-duplicates project over config by skill name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".zagent/skills/project-skill");
    try tmp.dir.makePath("cfg/skills/project-skill");
    try tmp.dir.makePath("cfg/skills/allowed-skill");

    {
        var f = try tmp.dir.createFile(".zagent/skills/project-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll("project body");
    }
    {
        var f = try tmp.dir.createFile("cfg/skills/project-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll("config body");
    }
    {
        var f = try tmp.dir.createFile("cfg/skills/allowed-skill/SKILL.md", .{});
        defer f.close();
        try f.writeAll("allowed");
    }

    const allocator = std.testing.allocator;
    const project_root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(project_root);
    const config_dir = try tmp.dir.realpathAlloc(allocator, "cfg");
    defer allocator.free(config_dir);

    const discovered = try discover(allocator, project_root, config_dir);
    defer freeList(allocator, discovered);

    const project_skill = findByName(discovered, "project-skill");
    try std.testing.expect(project_skill != null);
    try std.testing.expect(std.mem.containsAtLeast(u8, project_skill.?.body, 1, "project body"));
    try std.testing.expect(findByName(discovered, "allowed-skill") != null);
}

test "isTriggeredByInput supports plain and $ mentions" {
    try std.testing.expect(isTriggeredByInput("roc-syntax", "use roc-syntax for this"));
    try std.testing.expect(isTriggeredByInput("roc-syntax", "please use $roc-syntax now"));
    try std.testing.expect(!isTriggeredByInput("roc", "crocodile"));
    try std.testing.expect(!isTriggeredByInput("skill", "skilled"));
}

test "isHintedByInput supports language + skill phrasing" {
    try std.testing.expect(isHintedByInput("roc-syntax", "use roc skill"));
    try std.testing.expect(isHintedByInput("python-lint", "please apply python skill here"));
    try std.testing.expect(!isHintedByInput("roc-syntax", "please use skill"));
}
