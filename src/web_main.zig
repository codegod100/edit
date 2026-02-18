const std = @import("std");
const web = @import("web.zig").server;
const logger = @import("logger.zig");
const cancel = @import("cancel.zig");
const context = @import("context.zig");
const config_store = @import("config_store.zig");
const provider = @import("provider.zig");
const provider_store = @import("provider_store.zig");
const model_select = @import("model_select.zig");
const model_loop = @import("model_loop/main.zig");

const log = std.log.scoped(.web_main);
const active_module = @import("context.zig");
const todo = @import("todo.zig");

const SessionMap = std.AutoHashMap(u32, Session);
var g_sessions: ?*SessionMap = null;
var g_server: ?*web.Server = null;
var g_config_dir: ?[]const u8 = null;
var g_provider_specs: ?[]const provider.ProviderSpec = null;
const FIXED_FALLBACK_PORT: u16 = 28713;

// WebSocket message types
const MessageType = enum {
    user_input,
    set_project,
    read_file,
    write_file,
    list_sessions,
    load_session,
};

// WebSocket session state
const Session = struct {
    allocator: std.mem.Allocator,
    client_id: u32,
    project_path: ?[]const u8 = null,
    context_window: context.ContextWindow,
    todo_list: todo.TodoList,
    active_model: ?active_module.ActiveModel = null,
    
    pub fn init(allocator: std.mem.Allocator, client_id: u32) Session {
        return Session{
            .allocator = allocator,
            .client_id = client_id,
            .project_path = null,
            .context_window = context.ContextWindow.init(32000, 20),
            .todo_list = todo.TodoList.init(allocator),
        };
    }
    
    pub fn deinit(self: *Session) void {
        if (self.project_path) |p| {
            self.allocator.free(p);
        }
        self.context_window.deinit(self.allocator);
        self.todo_list.deinit();
        if (self.active_model) |*m| {
            self.allocator.free(m.provider_id);
            self.allocator.free(m.model_id);
            if (m.api_key) |k| self.allocator.free(k);
            if (m.reasoning_effort) |r| self.allocator.free(r);
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = web.Server.Config{
        .port = FIXED_FALLBACK_PORT,
        .host = "127.0.0.1",
    };

    // Parse --port and --host flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help_text =
                \\Usage: zagent-web [OPTIONS]
                \\
                \\Options:
                \\  --port PORT           Port to listen on (default: 28713)
                \\  --host HOST           Host to bind to (default: 127.0.0.1)
                \\  -h, --help            Show this help message
                \\
            ;
            _ = try std.posix.write(1, help_text);
            return;
        }

        if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i < args.len) {
                config.port = try std.fmt.parseInt(u16, args[i], 10);
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i < args.len) {
                config.host = args[i];
            }
        }
    }

    // Initialize logging
    const home = std.posix.getenv("HOME") orelse "/tmp";
    const log_path = try std.fs.path.join(allocator, &.{ home, ".config", "zagent", "debug.log" });
    defer allocator.free(log_path);

    try logger.init(allocator, .info, log_path);
    defer logger.deinit();

    cancel.init();
    defer cancel.deinit();

    log.info("zagent-web starting up", .{});

    // Load the selected model
    const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "zagent" });
    defer allocator.free(config_dir);

    // Create the web server, falling back to a fixed port if preferred is in use.
    var server: web.Server = undefined;
    var server_inited = false;
    var effective_config = config;
    server = web.Server.init(allocator, effective_config) catch |err| switch (err) {
        error.AddressInUse => blk: {
            if (effective_config.port == FIXED_FALLBACK_PORT) return err;
            log.warn("Port {d} is busy; retrying on fixed fallback {d}", .{ effective_config.port, FIXED_FALLBACK_PORT });
            effective_config.port = FIXED_FALLBACK_PORT;
            break :blk web.Server.init(allocator, effective_config) catch |err2| switch (err2) {
                error.AddressInUse => {
                    log.err("Fallback port {d} is also busy", .{FIXED_FALLBACK_PORT});
                    return err2;
                },
                else => return err2,
            };
        },
        else => return err,
    };
    server_inited = true;
    if (!server_inited) {
        return error.AddressInUse;
    }
    defer server.deinit();

    // Session storage
    var sessions = SessionMap.init(allocator);
    defer {
        var it = sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        sessions.deinit();
    }

    g_sessions = &sessions;
    g_server = &server;
    g_config_dir = config_dir;
    g_provider_specs = try provider.loadProviderSpecs(allocator, config_dir);
    defer {
        provider.deinitProviderSpecs();
        g_provider_specs = null;
        g_config_dir = null;
        g_server = null;
        g_sessions = null;
    }

    // Set message handler
    server.onMessage(handleMessage);

    log.info("Starting web server on {s}:{d}", .{ effective_config.host, effective_config.port });
    try server.run();
}

fn getOrCreateSession(allocator: std.mem.Allocator, sessions: *SessionMap, client_id: u32) !*Session {
    const gop = try sessions.getOrPut(client_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = Session.init(allocator, client_id);
    }
    return gop.value_ptr;
}

fn handleMessage(allocator: std.mem.Allocator, client_id: u32, ws_message: []const u8) ![]const u8 {
    const data = std.json.parseFromSlice(struct {
        type: []const u8,
        path: ?[]const u8 = null,
        content: ?[]const u8 = null,
        project_path: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
    }, allocator, ws_message, .{}) catch |err| {
        log.err("Failed to parse message: {}", .{err});
        return try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Invalid JSON\"}}", .{});
    };
    defer data.deinit();

    const sessions = g_sessions orelse {
        return try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Session store unavailable\"}}", .{});
    };
    const server = g_server orelse {
        return try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Server unavailable\"}}", .{});
    };
    const config_dir = g_config_dir orelse {
        return try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Config unavailable\"}}", .{});
    };

    const session = try getOrCreateSession(allocator, sessions, client_id);

    if (std.mem.eql(u8, data.value.type, "set_project")) {
        if (data.value.project_path) |path| {
            if (session.project_path) |old_path| session.allocator.free(old_path);
            session.project_path = try session.allocator.dupe(u8, path);
            session.context_window.deinit(session.allocator);
            session.context_window = context.ContextWindow.init(32000, 20);
            if (session.context_window.title) |old_title| session.allocator.free(old_title);
            session.context_window.title = try session.allocator.dupe(u8, path);
            if (session.context_window.project_path) |old_project_path| session.allocator.free(old_project_path);
            session.context_window.project_path = try session.allocator.dupe(u8, path);
            const project_hash = context.hashProjectPath(path);
            context.loadContextWindow(session.allocator, config_dir, &session.context_window, project_hash) catch |err| {
                log.warn("Failed to load context for {s}: {}", .{ path, err });
            };
            if (session.context_window.project_path == null) {
                session.context_window.project_path = try session.allocator.dupe(u8, path);
            }
            try sendFileList(server, session, path);
            return try std.fmt.allocPrint(allocator, "{{\"type\":\"status\",\"content\":\"Project set to {s}\"}}", .{path});
        }
    } else if (std.mem.eql(u8, data.value.type, "list_dir")) {
        return try listDirectoriesResponse(allocator, data.value.path);
    } else if (std.mem.eql(u8, data.value.type, "user_input")) {
        if (data.value.content) |content| {
            try processUserInput(allocator, server, session, content, config_dir);
            return try allocator.dupe(u8, "");
        }
    } else if (std.mem.eql(u8, data.value.type, "read_file")) {
        if (data.value.path) |path| {
            try sendFileContent(server, session.project_path orelse ".", path);
        }
    } else if (std.mem.eql(u8, data.value.type, "write_file")) {
        if (data.value.path) |path| {
            if (data.value.content) |content| {
                try writeAndBroadcastFile(allocator, server, session.project_path orelse ".", path, content);
            }
        }
    } else if (std.mem.eql(u8, data.value.type, "list_sessions")) {
        return try listSessionsResponse(allocator, config_dir);
    } else if (std.mem.eql(u8, data.value.type, "load_session")) {
        if (data.value.session_id) |session_id| {
            return try loadSessionResponse(allocator, server, session, config_dir, session_id);
        }
    }

    return try allocator.dupe(u8, "");
}

// Helper functions
fn listDirectoriesResponse(allocator: std.mem.Allocator, requested_path: ?[]const u8) ![]u8 {
    const base_path = blk: {
        if (requested_path) |rp| {
            const trimmed = std.mem.trim(u8, rp, " \t\r\n");
            if (trimmed.len > 0) {
                if (std.fs.path.isAbsolute(trimmed)) {
                    break :blk try allocator.dupe(u8, trimmed);
                }
                break :blk try std.fs.cwd().realpathAlloc(allocator, trimmed);
            }
        }
        break :blk try std.fs.cwd().realpathAlloc(allocator, ".");
    };
    defer allocator.free(base_path);

    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch {
        return try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Cannot open directory: {s}\"}}", .{base_path});
    };
    defer dir.close();

    var entries: std.ArrayListUnmanaged(struct { name: []u8, path: []u8 }) = .empty;
    defer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.path);
        }
        entries.deinit(allocator);
    }

    if (std.fs.path.dirname(base_path)) |parent| {
        if (!std.mem.eql(u8, parent, base_path)) {
            try entries.append(allocator, .{
                .name = try allocator.dupe(u8, ".."),
                .path = try allocator.dupe(u8, parent),
            });
        }
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const full = try std.fs.path.join(allocator, &.{ base_path, entry.name });
        try entries.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = full,
        });
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const path_json = try jsonQuoted(allocator, base_path);
    defer allocator.free(path_json);

    try out.writer(allocator).print("{{\"type\":\"dir_list\",\"path\":{s},\"entries\":[", .{path_json});
    for (entries.items, 0..) |e, i| {
        if (i > 0) try out.append(allocator, ',');
        const name_json = try jsonQuoted(allocator, e.name);
        defer allocator.free(name_json);
        const entry_path_json = try jsonQuoted(allocator, e.path);
        defer allocator.free(entry_path_json);
        try out.writer(allocator).print("{{\"name\":{s},\"path\":{s}}}", .{ name_json, entry_path_json });
    }
    try out.appendSlice(allocator, "]}");

    return out.toOwnedSlice(allocator);
}

fn inferProjectPathFromWindow(allocator: std.mem.Allocator, window: *const context.ContextWindow) !?[]u8 {
    if (window.project_path) |project_path| {
        const trimmed = std.mem.trim(u8, project_path, " \t\r\n");
        if (trimmed.len > 0 and std.fs.path.isAbsolute(trimmed)) {
            return try allocator.dupe(u8, trimmed);
        }
    }

    if (window.title) |title| {
        const trimmed = std.mem.trim(u8, title, " \t\r\n");
        if (trimmed.len > 0 and std.fs.path.isAbsolute(trimmed)) {
            return try allocator.dupe(u8, trimmed);
        }
    }

    const prefix = "Active project root: ";
    for (window.turns.items) |turn| {
        if (turn.role != .user) continue;
        if (!std.mem.startsWith(u8, turn.content, prefix)) continue;
        const rest = turn.content[prefix.len..];
        const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const maybe = std.mem.trim(u8, rest[0..line_end], " \t\r\n");
        if (maybe.len > 0 and std.fs.path.isAbsolute(maybe)) {
            return try allocator.dupe(u8, maybe);
        }
    }

    return null;
}

fn inferProjectPathForSession(allocator: std.mem.Allocator, config_dir: []const u8, session_id: []const u8) !?[]u8 {
    var window = context.ContextWindow.init(32000, 20);
    defer window.deinit(allocator);

    const loaded_hash = try context.loadContextWindowWithHash(allocator, config_dir, &window, session_id);
    if (loaded_hash == null) return null;

    return try inferProjectPathFromWindow(allocator, &window);
}

fn listSessionsResponse(allocator: std.mem.Allocator, config_dir: []const u8) ![]u8 {
    var sessions = try context.listContextSessions(allocator, config_dir);
    defer {
        for (sessions.items) |*s| s.deinit(allocator);
        sessions.deinit(allocator);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"type\":\"recent_sessions\",\"sessions\":[");

    for (sessions.items, 0..) |s, i| {
        if (i > 0) try out.append(allocator, ',');

        const id_json = try jsonQuoted(allocator, s.id);
        defer allocator.free(id_json);

        const title_value = if (s.title) |title|
            title
        else
            s.path;
        const title_json = try jsonQuoted(allocator, title_value);
        defer allocator.free(title_json);

        const inferred_project_path = try inferProjectPathForSession(allocator, config_dir, s.id);
        defer if (inferred_project_path) |p| allocator.free(p);

        const project_path_candidate: ?[]const u8 = if (inferred_project_path) |p|
            p
        else if (s.title) |title| blk: {
            const trimmed = std.mem.trim(u8, title, " \t\r\n");
            if (trimmed.len > 0 and std.fs.path.isAbsolute(trimmed)) break :blk trimmed;
            break :blk null;
        } else
            null;

        try out.writer(allocator).print("{{\"id\":{s},\"title\":{s},\"updated\":{d},\"turn_count\":{d},\"project_path\":", .{
            id_json,
            title_json,
            s.modified_time,
            s.turn_count,
        });
        if (project_path_candidate) |pp| {
            const pp_json = try jsonQuoted(allocator, pp);
            defer allocator.free(pp_json);
            try out.appendSlice(allocator, pp_json);
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, '}');
    }

    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

fn loadSessionResponse(
    allocator: std.mem.Allocator,
    server: *web.Server,
    session: *Session,
    config_dir: []const u8,
    session_id: []const u8,
) ![]u8 {
    session.context_window.deinit(allocator);
    session.context_window = context.ContextWindow.init(32000, 20);
    session.todo_list.deinit();
    session.todo_list = todo.TodoList.init(allocator);

    if (session.project_path) |p| {
        allocator.free(p);
        session.project_path = null;
    }

    const loaded_hash = try context.loadContextWindowWithHash(allocator, config_dir, &session.context_window, session_id);
    if (loaded_hash == null) {
        return try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Failed to load session {s}\"}}", .{session_id});
    }

    const maybe_project_path = try inferProjectPathFromWindow(allocator, &session.context_window);
    defer if (maybe_project_path) |p| allocator.free(p);

    if (maybe_project_path) |project_path| {
        session.project_path = try allocator.dupe(u8, project_path);
        if (session.context_window.title) |old_title| allocator.free(old_title);
        session.context_window.title = try allocator.dupe(u8, project_path);
        if (session.context_window.project_path) |old_project_path| allocator.free(old_project_path);
        session.context_window.project_path = try allocator.dupe(u8, project_path);
        sendFileList(server, session, project_path) catch |err| {
            log.warn("Failed to send file list for loaded session {s}: {}", .{ session_id, err });
        };
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const id_json = try jsonQuoted(allocator, session_id);
    defer allocator.free(id_json);
    const title_json = if (session.context_window.title) |t| try jsonQuoted(allocator, t) else try allocator.dupe(u8, "null");
    defer allocator.free(title_json);

    try out.writer(allocator).print("{{\"type\":\"session_loaded\",\"session_id\":{s},\"title\":{s},\"project_path\":", .{ id_json, title_json });
    if (session.project_path) |p| {
        const project_json = try jsonQuoted(allocator, p);
        defer allocator.free(project_json);
        try out.appendSlice(allocator, project_json);
    } else {
        try out.appendSlice(allocator, "null");
    }

    try out.appendSlice(allocator, ",\"turns\":[");
    for (session.context_window.turns.items, 0..) |turn, i| {
        if (i > 0) try out.append(allocator, ',');
        const role_json = try jsonQuoted(allocator, if (turn.role == .assistant) "assistant" else "user");
        defer allocator.free(role_json);
        const content_json = try jsonQuoted(allocator, turn.content);
        defer allocator.free(content_json);
        try out.writer(allocator).print("{{\"role\":{s},\"content\":{s}}}", .{ role_json, content_json });
    }
    try out.appendSlice(allocator, "]}");

    return out.toOwnedSlice(allocator);
}

fn sendFileList(server: *web.Server, session: *Session, project_path: []const u8) !void {
    var files: std.ArrayListUnmanaged(struct { name: []const u8, path: []const u8 }) = .empty;
    defer {
        for (files.items) |f| {
            session.allocator.free(f.name);
            session.allocator.free(f.path);
        }
        files.deinit(session.allocator);
    }

    var dir = std.fs.openDirAbsolute(project_path, .{ .iterate = true }) catch |err| {
        log.err("Failed to open directory {s}: {}", .{project_path, err});
        return;
    };
    defer dir.close();

    var walker = try dir.walk(session.allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            try files.append(session.allocator, .{
                .name = try session.allocator.dupe(u8, entry.basename),
                .path = try session.allocator.dupe(u8, entry.path),
            });
        }
    }

    // Convert to JSON
    var json_builder: std.ArrayListUnmanaged(u8) = .empty;
    defer json_builder.deinit(session.allocator);

    try json_builder.append(session.allocator, '{');
    try json_builder.appendSlice(session.allocator, "\"type\":\"file_list\",\"files\":[");

    for (files.items, 0..) |file, i| {
        if (i > 0) try json_builder.append(session.allocator, ',');
        try json_builder.append(session.allocator, '{');
        try json_builder.writer(session.allocator).print("\"name\":\"{s}\",\"path\":\"{s}\"", .{ file.name, file.path });
        try json_builder.append(session.allocator, '}');
    }

    try json_builder.appendSlice(session.allocator, "]}");

    try server.broadcast(json_builder.items);
}

fn sendFileContent(server: *web.Server, project_path: []const u8, file_path: []const u8) !void {
    const allocator = std.heap.page_allocator;
    
    const full_path = try std.fs.path.join(allocator, &.{ project_path, file_path });
    defer allocator.free(full_path);

    const file = std.fs.openFileAbsolute(full_path, .{}) catch |err| {
        log.err("Failed to open file {s}: {}", .{full_path, err});
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Failed to read file\"}}", .{});
        defer allocator.free(error_msg);
        try server.broadcast(error_msg);
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch |err| {
        log.err("Failed to read file content: {}", .{err});
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Failed to read file content\"}}", .{});
        defer allocator.free(error_msg);
        try server.broadcast(error_msg);
        return;
    };
    defer allocator.free(content);

    const path_json = try jsonQuoted(allocator, file_path);
    defer allocator.free(path_json);
    const content_json = try jsonQuoted(allocator, content);
    defer allocator.free(content_json);

    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"file_content\",\"path\":{s},\"content\":{s}}}", .{ path_json, content_json });
    defer allocator.free(response);

    try server.broadcast(response);
}

fn writeAndBroadcastFile(allocator: std.mem.Allocator, server: *web.Server, project_path: []const u8, file_path: []const u8, content: []const u8) !void {
    const full_path = try std.fs.path.join(allocator, &.{ project_path, file_path });
    defer allocator.free(full_path);

    const dir_path = std.fs.path.dirname(full_path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| {
        if (err != error.PathAlreadyExists) {
            return err;
        }
    };

    const file = try std.fs.createFileAbsolute(full_path, .{});
    defer file.close();

    try file.writeAll(content);

    const path_json = try jsonQuoted(allocator, file_path);
    defer allocator.free(path_json);

    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"file_saved\",\"path\":{s}}}", .{path_json});
    defer allocator.free(response);

    try server.broadcast(response);
}

fn processUserInput(allocator: std.mem.Allocator, server: *web.Server, session: *Session, input: []const u8, config_dir: []const u8) !void {
    const trimmed_input = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed_input.len == 0) return;
    cancel.resetCancelled();
    cancel.beginProcessing();
    defer cancel.resetCancelled();

    // Ensure we have an active model
    if (session.active_model == null) {
        const selected = try config_store.loadSelectedModel(allocator, config_dir);
        if (selected == null) {
            const error_msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"No model selected. Use /model to select one.\"}}", .{});
            defer allocator.free(error_msg);
            try server.broadcast(error_msg);
            return;
        }
        defer {
            var s = selected.?;
            s.deinit(allocator);
        }

        const specs = g_provider_specs orelse {
            const error_msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"Provider configuration unavailable.\"}}", .{});
            defer allocator.free(error_msg);
            try server.broadcast(error_msg);
            return;
        };

        const stored_pairs = try provider_store.load(allocator, config_dir);
        defer provider_store.free(allocator, stored_pairs);

        const provider_states = try model_select.resolveProviderStates(allocator, specs, stored_pairs);
        defer allocator.free(provider_states);

        const active = model_select.chooseActiveModel(specs, provider_states, selected, null);
        if (active == null) {
            const error_msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":\"No connected provider for selected model.\"}}", .{});
            defer allocator.free(error_msg);
            try server.broadcast(error_msg);
            return;
        }

        session.active_model = active_module.ActiveModel{
            .provider_id = try allocator.dupe(u8, active.?.provider_id),
            .api_key = if (active.?.api_key) |k| try allocator.dupe(u8, k) else null,
            .model_id = try allocator.dupe(u8, active.?.model_id),
        };
    }

    const project_path = session.project_path orelse ".";
    const project_hash = context.hashProjectPath(project_path);
    if (session.context_window.project_path) |old_project_path| session.allocator.free(old_project_path);
    session.context_window.project_path = try session.allocator.dupe(u8, project_path);

    try session.context_window.append(allocator, .user, trimmed_input, .{});
    context.saveContextWindow(allocator, config_dir, &session.context_window, project_hash) catch |err| {
        log.warn("Failed to save context before run: {}", .{err});
    };

    const model_input = try std.fmt.allocPrint(
        allocator,
        "Active project root: {s}\n\nUser request:\n{s}",
        .{ project_path, trimmed_input },
    );
    defer allocator.free(model_input);

    var turn_arena = std.heap.ArenaAllocator.init(allocator);
    defer turn_arena.deinit();
    const turn_alloc = turn_arena.allocator();

    const ctx_messages = try context.buildContextMessagesJson(turn_alloc, &session.context_window, model_input);
    const sink = std.io.null_writer;

    const result = model_loop.runModel(
        allocator,
        sink,
        session.active_model.?,
        trimmed_input,
        ctx_messages,
        false,
        &session.todo_list,
        null,
    ) catch |err| {
        const provider_err = @import("llm.zig").getLastProviderError() orelse "";
        const message = if (provider_err.len > 0)
            try std.fmt.allocPrint(allocator, "Model request failed: {s}", .{provider_err})
        else
            try std.fmt.allocPrint(allocator, "Model request failed: {s}", .{@errorName(err)});
        defer allocator.free(message);
        const message_json = try jsonQuoted(allocator, message);
        defer allocator.free(message_json);
        const error_msg = try std.fmt.allocPrint(allocator, "{{\"type\":\"error\",\"content\":{s}}}", .{message_json});
        defer allocator.free(error_msg);
        try server.broadcast(error_msg);
        return;
    };
    defer {
        var mut = result;
        mut.deinit(allocator);
    }

    try session.context_window.append(allocator, .assistant, result.response, .{
        .reasoning = result.reasoning,
        .tool_calls = result.tool_calls,
        .error_count = result.error_count,
        .files_touched = result.files_touched,
    });
    context.compactContextWindow(allocator, &session.context_window, session.active_model.?) catch |err| {
        log.warn("Failed to compact context: {}", .{err});
    };
    context.saveContextWindow(allocator, config_dir, &session.context_window, project_hash) catch |err| {
        log.warn("Failed to save context after run: {}", .{err});
    };

    const input_json = try jsonQuoted(allocator, result.response);
    defer allocator.free(input_json);
    const response = try std.fmt.allocPrint(allocator, "{{\"type\":\"assistant_output\",\"content\":{s}}}", .{input_json});
    defer allocator.free(response);
    try server.broadcast(response);
}

fn jsonQuoted(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, '"');
    for (input) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 32) {
                    try out.writer(allocator).print("\\u00{x:0>2}", .{c});
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');

    return out.toOwnedSlice(allocator);
}
