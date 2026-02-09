const std = @import("std");
const config_store = @import("config_store.zig");

pub const Session = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,
    updated_at: i64,
    message_count: usize,
    model: []const u8,
    provider: []const u8,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.model);
        allocator.free(self.provider);
    }
};

pub const SessionSummary = struct {
    id: []const u8,
    name: []const u8,
    created_at: i64,
    updated_at: i64,
    message_count: usize,
    model: []const u8,
    provider: []const u8,
};

const SessionsManifest = struct {
    sessions: []SessionSummary,
    active_session_id: ?[]const u8,

    pub fn jsonStringify(self: SessionsManifest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("sessions");
        try jw.write(self.sessions);
        try jw.objectField("active_session_id");
        try jw.write(self.active_session_id);
        try jw.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: anytype) !SessionsManifest {
        const value = try std.json.parseFromTokenSource(std.json.Value, allocator, source, options);
        defer value.deinit();
        
        var manifest = SessionsManifest{
            .sessions = &.{},
            .active_session_id = null,
        };

        if (value.value.object.get("sessions")) |sessions_val| {
            if (sessions_val == .array) {
                const sessions = try allocator.alloc(SessionSummary, sessions_val.array.items.len);
                for (sessions_val.array.items, 0..) |item, i| {
                    sessions[i] = SessionSummary{
                        .id = try allocator.dupe(u8, item.object.get("id").?.string),
                        .name = try allocator.dupe(u8, item.object.get("name").?.string),
                        .created_at = item.object.get("created_at").?.integer,
                        .updated_at = item.object.get("updated_at").?.integer,
                        .message_count = @intCast(item.object.get("message_count").?.integer),
                        .model = try allocator.dupe(u8, item.object.get("model").?.string),
                        .provider = try allocator.dupe(u8, item.object.get("provider").?.string),
                    };
                }
                manifest.sessions = sessions;
            }
        }

        if (value.value.object.get("active_session_id")) |active| {
            if (active == .string) {
                manifest.active_session_id = try allocator.dupe(u8, active.string);
            }
        }

        return manifest;
    }
};

pub fn sessionsPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    return config_store.getConfigPathAlloc(allocator, "sessions.json");
}

pub fn sessionsDirPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const config_dir = try config_store.configDirPathAlloc(allocator);
    defer allocator.free(config_dir);
    return std.fs.path.join(allocator, &.{ config_dir, "sessions" });
}

pub fn createSession(allocator: std.mem.Allocator, name: []const u8, model: []const u8, provider: []const u8) !Session {
    const id = try generateSessionId(allocator);
    errdefer allocator.free(id);

    const now = std.time.timestamp();
    
    const session = Session{
        .id = id,
        .name = try allocator.dupe(u8, name),
        .created_at = now,
        .updated_at = now,
        .message_count = 0,
        .model = try allocator.dupe(u8, model),
        .provider = try allocator.dupe(u8, provider),
    };

    try saveSession(allocator, &session);
    try addToManifest(allocator, &session);

    return session;
}

pub fn loadSession(allocator: std.mem.Allocator, id: []const u8) !Session {
    const sessions_dir = try sessionsDirPathAlloc(allocator);
    defer allocator.free(sessions_dir);

    const path = try std.fs.path.join(allocator, &.{ sessions_dir, id, "session.json" });
    defer allocator.free(path);

    const data = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(Session, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return Session{
        .id = try allocator.dupe(u8, parsed.value.id),
        .name = try allocator.dupe(u8, parsed.value.name),
        .created_at = parsed.value.created_at,
        .updated_at = parsed.value.updated_at,
        .message_count = parsed.value.message_count,
        .model = try allocator.dupe(u8, parsed.value.model),
        .provider = try allocator.dupe(u8, parsed.value.provider),
    };
}

pub fn updateSession(allocator: std.mem.Allocator, session: *const Session) !void {
    try saveSession(allocator, session);
    try updateManifestEntry(allocator, session);
}

pub fn deleteSession(allocator: std.mem.Allocator, id: []const u8) !void {
    const sessions_dir = try sessionsDirPathAlloc(allocator);
    defer allocator.free(sessions_dir);

    const path = try std.fs.path.join(allocator, &.{ sessions_dir, id });
    defer allocator.free(path);

    try std.fs.cwd().deleteTree(path);
    try removeFromManifest(allocator, id);
}

pub fn listSessions(allocator: std.mem.Allocator) ![]SessionSummary {
    const manifest_path = try sessionsPathAlloc(allocator);
    defer allocator.free(manifest_path);

    const data = std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return allocator.alloc(SessionSummary, 0);
        return err;
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(SessionsManifest, allocator, data, .{});
    defer parsed.deinit();

    const sessions = try allocator.alloc(SessionSummary, parsed.value.sessions.len);
    for (parsed.value.sessions, 0..) |s, i| {
        sessions[i] = SessionSummary{
            .id = try allocator.dupe(u8, s.id),
            .name = try allocator.dupe(u8, s.name),
            .created_at = s.created_at,
            .updated_at = s.updated_at,
            .message_count = s.message_count,
            .model = try allocator.dupe(u8, s.model),
            .provider = try allocator.dupe(u8, s.provider),
        };
    }

    return sessions;
}

pub fn setActiveSession(allocator: std.mem.Allocator, id: ?[]const u8) !void {
    const manifest_path = try sessionsPathAlloc(allocator);
    defer allocator.free(manifest_path);

    var manifest: SessionsManifest = .{
        .sessions = &.{},
        .active_session_id = null,
    };

    const data = std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        if (err != error.FileNotFound) return err;
        &[_]u8{};
    };
    defer if (data.len > 0) allocator.free(data);

    if (data.len > 0) {
        const parsed = try std.json.parseFromSlice(SessionsManifest, allocator, data, .{});
        defer parsed.deinit();
        manifest.sessions = parsed.value.sessions;
        manifest.active_session_id = parsed.value.active_session_id;
    }

    if (manifest.active_session_id) |old| {
        allocator.free(old);
    }

    manifest.active_session_id = if (id) |new_id| try allocator.dupe(u8, new_id) else null;

    const out_data = try std.json.stringifyAlloc(allocator, manifest, .{});
    defer allocator.free(out_data);

    const file = try std.fs.cwd().createFile(manifest_path, .{});
    defer file.close();
    try file.writeAll(out_data);
}

pub fn getActiveSession(allocator: std.mem.Allocator) !?[]const u8 {
    const manifest_path = try sessionsPathAlloc(allocator);
    defer allocator.free(manifest_path);

    const data = std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(SessionsManifest, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value.active_session_id) |id| {
        return try allocator.dupe(u8, id);
    }
    return null;
}

fn generateSessionId(allocator: std.mem.Allocator) ![]u8 {
    const timestamp = std.time.timestamp();
    const random_part = std.crypto.random.int(u32);
    return std.fmt.allocPrint(allocator, "{d}_{x}", .{ timestamp, random_part });
}

fn saveSession(allocator: std.mem.Allocator, session: *const Session) !void {
    const sessions_dir = try sessionsDirPathAlloc(allocator);
    defer allocator.free(sessions_dir);

    const session_dir = try std.fs.path.join(allocator, &.{ sessions_dir, session.id });
    defer allocator.free(session_dir);

    try std.fs.cwd().makePath(session_dir);

    const path = try std.fs.path.join(allocator, &.{ session_dir, "session.json" });
    defer allocator.free(path);

    const data = try std.json.stringifyAlloc(allocator, session, .{});
    defer allocator.free(data);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

fn addToManifest(allocator: std.mem.Allocator, session: *const Session) !void {
    const sessions = try listSessions(allocator);
    defer {
        for (sessions) |*s| {
            allocator.free(s.id);
            allocator.free(s.name);
            allocator.free(s.model);
            allocator.free(s.provider);
        }
        allocator.free(sessions);
    }

    const new_sessions = try allocator.alloc(SessionSummary, sessions.len + 1);
    @memcpy(new_sessions[0..sessions.len], sessions);
    new_sessions[sessions.len] = SessionSummary{
        .id = try allocator.dupe(u8, session.id),
        .name = try allocator.dupe(u8, session.name),
        .created_at = session.created_at,
        .updated_at = session.updated_at,
        .message_count = session.message_count,
        .model = try allocator.dupe(u8, session.model),
        .provider = try allocator.dupe(u8, session.provider),
    };

    const manifest = SessionsManifest{
        .sessions = new_sessions,
        .active_session_id = null,
    };

    const manifest_path = try sessionsPathAlloc(allocator);
    defer allocator.free(manifest_path);

    const data = try std.json.stringifyAlloc(allocator, manifest, .{});
    defer allocator.free(data);

    const file = try std.fs.cwd().createFile(manifest_path, .{});
    defer file.close();
    try file.writeAll(data);
}

fn updateManifestEntry(allocator: std.mem.Allocator, session: *const Session) !void {
    var sessions = try listSessions(allocator);
    defer {
        for (sessions) |*s| {
            allocator.free(s.id);
            allocator.free(s.name);
            allocator.free(s.model);
            allocator.free(s.provider);
        }
        allocator.free(sessions);
    }

    for (sessions, 0..) |*s, i| {
        if (std.mem.eql(u8, s.id, session.id)) {
            allocator.free(s.id);
            allocator.free(s.name);
            allocator.free(s.model);
            allocator.free(s.provider);
            sessions[i] = SessionSummary{
                .id = try allocator.dupe(u8, session.id),
                .name = try allocator.dupe(u8, session.name),
                .created_at = session.created_at,
                .updated_at = session.updated_at,
                .message_count = session.message_count,
                .model = try allocator.dupe(u8, session.model),
                .provider = try allocator.dupe(u8, session.provider),
            };
            break;
        }
    }

    const manifest = SessionsManifest{
        .sessions = sessions,
        .active_session_id = null,
    };

    const manifest_path = try sessionsPathAlloc(allocator);
    defer allocator.free(manifest_path);

    const data = try std.json.stringifyAlloc(allocator, manifest, .{});
    defer allocator.free(data);

    const file = try std.fs.cwd().createFile(manifest_path, .{});
    defer file.close();
    try file.writeAll(data);
}

fn removeFromManifest(allocator: std.mem.Allocator, id: []const u8) !void {
    var sessions = try listSessions(allocator);
    defer {
        for (sessions) |*s| {
            allocator.free(s.id);
            allocator.free(s.name);
            allocator.free(s.model);
            allocator.free(s.provider);
        }
        allocator.free(sessions);
    }

    var found: ?usize = null;
    for (sessions, 0..) |s, i| {
        if (std.mem.eql(u8, s.id, id)) {
            found = i;
            break;
        }
    }

    if (found) |idx| {
        allocator.free(sessions[idx].id);
        allocator.free(sessions[idx].name);
        allocator.free(sessions[idx].model);
        allocator.free(sessions[idx].provider);

        if (idx < sessions.len - 1) {
            @memcpy(sessions[idx .. sessions.len - 1], sessions[idx + 1 .. sessions.len]);
        }

        const new_sessions = try allocator.realloc(sessions, sessions.len - 1);

        const manifest = SessionsManifest{
            .sessions = new_sessions,
            .active_session_id = null,
        };

        const manifest_path = try sessionsPathAlloc(allocator);
        defer allocator.free(manifest_path);

        const data = try std.json.stringifyAlloc(allocator, manifest, .{});
        defer allocator.free(data);

        const file = try std.fs.cwd().createFile(manifest_path, .{});
        defer file.close();
        try file.writeAll(data);
    }
}

test "session store" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const orig_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(orig_cwd);

    var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try tmp_dir.dir.realpath(".", &buf);
    try std.os.chdir(path);
    defer std.os.chdir(orig_cwd) catch {};

    const session = try createSession(allocator, "Test Session", "gpt-4", "openai");
    defer session.deinit(allocator);

    try std.testing.expectEqualStrings("Test Session", session.name);
    try std.testing.expectEqualStrings("gpt-4", session.model);
    try std.testing.expectEqualStrings("openai", session.provider);

    const loaded = try loadSession(allocator, session.id);
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings(session.id, loaded.id);
    try std.testing.expectEqualStrings(session.name, loaded.name);

    const sessions = try listSessions(allocator);
    defer {
        for (sessions) |*s| {
            allocator.free(s.id);
            allocator.free(s.name);
            allocator.free(s.model);
            allocator.free(s.provider);
        }
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("Test Session", sessions[0].name);

    try deleteSession(allocator, session.id);
}
