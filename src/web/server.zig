const std = @import("std");
const net = std.net;
const posix = std.posix;

const log = std.log.scoped(.web_server);

// Global message handler (set by web_main)
var global_message_handler: ?*const fn (allocator: std.mem.Allocator, client_id: u32, message: []const u8) anyerror![]const u8 = null;
var next_client_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);

pub fn setMessageHandler(handler: *const fn (allocator: std.mem.Allocator, client_id: u32, message: []const u8) anyerror![]const u8) void {
    global_message_handler = handler;
}

/// HTTP/WebSocket server for zagent web UI
pub const Server = struct {
    allocator: std.mem.Allocator,
    listener: net.Server,
    port: u16,
    clients: std.ArrayListUnmanaged(Client),
    clients_mutex: std.Thread.Mutex,
    running: bool,

    pub const Client = struct {
        id: u32,
        stream: net.Stream,
        is_websocket: bool = false,
        path: ?[]const u8 = null, // Project path for this session
    };

    pub const Config = struct {
        port: u16 = 8080,
        host: []const u8 = "127.0.0.1",
    };

    /// Initialize the server
    pub fn init(allocator: std.mem.Allocator, config: Config) !Server {
        const address = try net.Address.resolveIp(config.host, config.port);
        const listener = try address.listen(.{
            .reuse_address = true,
            .kernel_backlog = 128,
        });

        log.info("Server listening on {s}:{d}\n", .{config.host, config.port});

        return Server{
            .allocator = allocator,
            .listener = listener,
            .port = config.port,
            .clients = .empty,
            .clients_mutex = .{},
            .running = false,
        };
    }

    /// Deinitialize the server
    pub fn deinit(self: *Server) void {
        self.running = false;

        // Close all client connections
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items) |client| {
            client.stream.close();
        }

        self.clients.deinit(self.allocator);
        self.listener.deinit();
    }

    /// Set the message handler callback
    pub fn onMessage(self: *Server, callback: *const fn (allocator: std.mem.Allocator, client_id: u32, message: []const u8) anyerror![]const u8) void {
        _ = self;
        setMessageHandler(callback);
    }

    /// Set the broadcast callback (currently unused)
    pub fn onBroadcast(self: *Server, callback: *const fn (allocator: std.mem.Allocator, message: []const u8) anyerror!void) void {
        _ = self;
        _ = callback;
    }

    /// Send a message to a specific client
    pub fn sendToClient(self: *Server, client_id: u32, message: []const u8) !void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        var i: usize = 0;
        while (i < self.clients.items.len) : (i += 1) {
            var client = &self.clients.items[i];
            if (client.id != client_id) continue;

            if (client.is_websocket) {
                sendWebSocketMessage(client.stream, message) catch |err| {
                    client.stream.close();
                    _ = self.clients.orderedRemove(i);
                    return err;
                };
            } else {
                client.stream.writeAll(message) catch |err| {
                    client.stream.close();
                    _ = self.clients.orderedRemove(i);
                    return err;
                };
            }
            return;
        }
        return error.ClientNotFound;
    }

    /// Broadcast a message to all connected clients
    pub fn broadcast(self: *Server, message: []const u8) !void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        var i: usize = 0;
        while (i < self.clients.items.len) {
            var client = &self.clients.items[i];
            const send_result = if (client.is_websocket)
                sendWebSocketMessage(client.stream, message)
            else
                client.stream.writeAll(message);

            _ = send_result catch {
                client.stream.close();
                _ = self.clients.orderedRemove(i);
                continue;
            };
            i += 1;
        }
        return;
    }

    /// Broadcast a message only to websocket clients
    pub fn broadcastWebSocket(self: *Server, message: []const u8) !void {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        var i: usize = 0;
        while (i < self.clients.items.len) {
            var client = &self.clients.items[i];
            if (!client.is_websocket) {
                i += 1;
                continue;
            }

            _ = sendWebSocketMessage(client.stream, message) catch {
                client.stream.close();
                _ = self.clients.orderedRemove(i);
                continue;
            };
            i += 1;
        }
        return;
    }

    /// Send agent output to all clients (used by the agent loop)
    pub fn sendAgentOutput(self: *Server, output: []const u8, message_type: []const u8) !void {
        const output_json = try jsonQuoted(self.allocator, output);
        defer self.allocator.free(output_json);
        const response = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"{s}\",\"content\":{s}}}", .{ message_type, output_json });
        defer self.allocator.free(response);

        try self.broadcast(response);
    }

    /// Start the server main loop
    pub fn run(self: *Server) !void {
        self.running = true;

        while (self.running) {
            // Accept new connection
            const connection = self.listener.accept() catch |err| {
                if (!self.running) return;
                log.err("Failed to accept connection: {}\n", .{err});
                continue;
            };

            const client_id = next_client_id.fetchAdd(1, .monotonic);

            const thread = try std.Thread.spawn(.{}, handleClientThreadMain, .{ self, connection, client_id });
            thread.detach();
        }
    }

    fn handleClientThreadMain(self: *Server, connection: net.Server.Connection, client_id: u32) void {
        self.handleClient(connection, client_id) catch |err| {
            log.err("Client {d} handler error: {}", .{ client_id, err });
        };
    }

    /// Handle a client connection
    fn handleClient(self: *Server, connection: net.Server.Connection, client_id: u32) !void {
        const client = Client{
            .id = client_id,
            .stream = connection.stream,
            .is_websocket = false,
        };

        self.clients_mutex.lock();
        errdefer self.clients_mutex.unlock();
        try self.clients.append(self.allocator, client);
        self.clients_mutex.unlock();
        defer {
            // Remove client on disconnect
            self.clients_mutex.lock();
            for (self.clients.items, 0..) |c, i| {
                if (c.id == client_id) {
                    _ = self.clients.orderedRemove(i);
                    break;
                }
            }
            self.clients_mutex.unlock();
            connection.stream.close();
        }

        // Read HTTP request
        var buffer: [8192]u8 = undefined;
        const request = connection.stream.read(&buffer) catch |err| {
            log.err("Failed to read from client: {}\n", .{err});
            return;
        };

        if (request > 0) {
            const request_text = buffer[0..request];

            // Check if it's a WebSocket upgrade request (case-insensitive)
            if (hasWebSocketUpgradeHeader(request_text)) {
                // WebSocket upgrade
                try self.handleWebSocketUpgrade(connection.stream, request_text, client_id);
                return;
            }

            // Handle HTTP request
            try self.handleHttpRequest(connection.stream, request_text);
        }
    }

    const StaticRoute = struct {
        path: []const u8,
        content_type: []const u8,
    };

    fn staticRouteForPath(path: []const u8) ?StaticRoute {
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            return .{ .path = "web_ui/index.html", .content_type = "text/html; charset=utf-8" };
        }
        if (std.mem.eql(u8, path, "/app.js")) {
            return .{ .path = "web_ui/app.js", .content_type = "application/javascript; charset=utf-8" };
        }
        if (std.mem.eql(u8, path, "/styles.css")) {
            return .{ .path = "web_ui/styles.css", .content_type = "text/css; charset=utf-8" };
        }
        if (std.mem.eql(u8, path, "/favicon.svg")) {
            return .{ .path = "web_ui/favicon.svg", .content_type = "image/svg+xml; charset=utf-8" };
        }
        if (std.mem.eql(u8, path, "/favicon.ico")) {
            return .{ .path = "web_ui/favicon.ico", .content_type = "image/x-icon" };
        }
        return null;
    }

    /// Handle HTTP GET request
    fn handleHttpRequest(self: *Server, stream: net.Stream, request: []const u8) !void {
        // Parse the request line
        var lines = std.mem.splitScalar(u8, request, '\n');
        const request_line = lines.next() orelse return;
        var parts = std.mem.splitScalar(u8, request_line, ' ');
        const method = parts.next() orelse "";
        const path = parts.next() orelse "/";

        if (!std.mem.eql(u8, method, "GET")) {
            try sendHttpResponse(stream, "405 Method Not Allowed", "text/plain", "Method not allowed");
            return;
        }

        if (staticRouteForPath(path)) |route| {
            try self.serveStaticFile(stream, route.path, route.content_type);
        } else {
            try sendHttpResponse(stream, "404 Not Found", "text/plain", "Not found");
        }
    }

    /// Serve a static file
    fn serveStaticFile(self: *Server, stream: net.Stream, path: []const u8, content_type: []const u8) !void {
        // 1) Try current working dir.
        var file = std.fs.cwd().openFile(path, .{}) catch null;
        // 2) Try next to binary (e.g. zig-out/bin/../web_ui/*).
        if (file == null) {
            const exe_dir = std.fs.selfExeDirPathAlloc(self.allocator) catch null;
            defer if (exe_dir) |d| self.allocator.free(d);
            if (exe_dir) |dir| {
                const candidate1 = std.fs.path.join(self.allocator, &.{ dir, "..", path }) catch null;
                defer if (candidate1) |p| self.allocator.free(p);
                if (candidate1) |p| file = std.fs.openFileAbsolute(p, .{}) catch null;

                if (file == null) {
                    const candidate2 = std.fs.path.join(self.allocator, &.{ dir, "..", "..", path }) catch null;
                    defer if (candidate2) |p2| self.allocator.free(p2);
                    if (candidate2) |p2| file = std.fs.openFileAbsolute(p2, .{}) catch null;
                }
            }
        }

        if (file == null) {
            log.err("Failed to open static file {s}\n", .{path});
            try sendHttpResponse(stream, "404 Not Found", "text/plain", "File not found");
            return;
        }
        const f = file.?;
        defer f.close();

        const content = f.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            log.err("Failed to read file {s}: {}\n", .{path, err});
            try sendHttpResponse(stream, "500 Internal Server Error", "text/plain", "Failed to read file");
            return;
        };
        defer self.allocator.free(content);

        // Send HTTP response
        try sendHttpResponse(stream, "200 OK", content_type, content);
    }

    /// Handle WebSocket upgrade
    fn handleWebSocketUpgrade(self: *Server, stream: net.Stream, request: []const u8, client_id: u32) !void {
        // Extract Sec-WebSocket-Key
        var key: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, request, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            if (std.mem.startsWith(u8, trimmed, "Sec-WebSocket-Key:")) {
                key = trimmed["Sec-WebSocket-Key:".len..];
                if (key) |k| {
                    key = std.mem.trim(u8, k, " \t\r\n");
                }
            }
        }

        if (key == null) {
            try sendHttpResponse(stream, "400 Bad Request", "text/plain", "Missing Sec-WebSocket-Key");
            return;
        }

        // Compute Sec-WebSocket-Accept
        const accept_key = try computeWebSocketAccept(self.allocator, key.?);
        defer self.allocator.free(accept_key);

        // Send WebSocket upgrade response
        const response = try std.fmt.allocPrint(
            self.allocator,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Accept: {s}\r\n" ++
                "Content-Length: 0\r\n" ++
                "\r\n",
            .{accept_key},
        );
        defer self.allocator.free(response);

        _ = try stream.writeAll(response);

        // Mark client as WebSocket
        self.clients_mutex.lock();
        for (self.clients.items) |*c| {
            if (c.id == client_id) {
                c.is_websocket = true;
                break;
            }
        }
        self.clients_mutex.unlock();

        // Bootstrap with recent sessions so the sidebar can populate on initial page load.
        if (global_message_handler) |callback| {
            const bootstrap_response = callback(self.allocator, client_id, initialWebSocketBootstrapMessage()) catch |err| blk: {
                log.warn("WebSocket bootstrap callback failed for client {d}: {}", .{ client_id, err });
                break :blk "";
            };
            if (bootstrap_response.len > 0) {
                defer self.allocator.free(bootstrap_response);
                try self.sendToClient(client_id, bootstrap_response);
            }
        }

        // Handle WebSocket messages
        try self.handleWebSocketMessages(stream, client_id);
    }

    /// Handle incoming WebSocket messages
    fn handleWebSocketMessages(self: *Server, stream: net.Stream, client_id: u32) !void {
        var read_buf: [8192]u8 = undefined;
        var pending: std.ArrayListUnmanaged(u8) = .empty;
        defer pending.deinit(self.allocator);

        while (self.running) {
            const n = stream.read(&read_buf) catch |err| {
                log.err("WebSocket read error for client {d}: {}\n", .{client_id, err});
                break;
            };

            if (n == 0) break;
            try pending.appendSlice(self.allocator, read_buf[0..n]);

            while (true) {
                const parsed_opt = parseWebSocketFrame(pending.items) catch |err| {
                    if (err == error.ConnectionClosed) return;
                    log.err("Failed to parse WebSocket frame: {}\n", .{err});
                    pending.clearRetainingCapacity();
                    break;
                };
                if (parsed_opt == null) break;
                const parsed = parsed_opt.?;

                const remaining = pending.items.len - parsed.consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[parsed.consumed..]);
                }
                pending.items.len = remaining;

                if (parsed.message.len == 0) continue;

                // Call message callback if set
                if (global_message_handler) |callback| {
                    const response = callback(self.allocator, client_id, parsed.message) catch |err| {
                        const error_msg = try std.fmt.allocPrint(self.allocator, "{{\"type\":\"error\",\"content\":\"Error: {s}\"}}", .{@errorName(err)});
                        defer self.allocator.free(error_msg);
                        try self.sendToClient(client_id, error_msg);
                        continue;
                    };
                    if (response.len > 0) {
                        defer self.allocator.free(response);
                        try self.sendToClient(client_id, response);
                    }
                }
            }
        }
    }
};

fn initialWebSocketBootstrapMessage() []const u8 {
    return "{\"type\":\"list_sessions\"}";
}

fn hasWebSocketUpgradeHeader(request: []const u8) bool {
    var lines = std.mem.splitScalar(u8, request, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Upgrade") and std.ascii.eqlIgnoreCase(value, "websocket")) {
            return true;
        }
    }
    return false;
}

/// Send an HTTP response
fn sendHttpResponse(stream: net.Stream, status: []const u8, content_type: []const u8, body: []const u8) !void {
    const response = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}",
        .{ status, content_type, body.len, body },
    );
    defer std.heap.page_allocator.free(response);

    _ = try stream.writeAll(response);
}

/// Send a WebSocket message
fn sendWebSocketMessage(stream: net.Stream, message: []const u8) !void {
    var frame: std.ArrayListUnmanaged(u8) = .empty;
    defer frame.deinit(std.heap.page_allocator);

    // FIN bit and text opcode
    try frame.append(std.heap.page_allocator, 0x81);

    const message_len = message.len;
    if (message_len < 126) {
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len)));
    } else if (message_len < 65536) {
        try frame.append(std.heap.page_allocator, 126);
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len >> 8)));
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len)));
    } else {
        try frame.append(std.heap.page_allocator, 127);
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len >> 56)));
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len >> 48)));
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len >> 40)));
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len >> 32)));
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len >> 24)));
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len >> 16)));
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len >> 8)));
        try frame.append(std.heap.page_allocator, @as(u8, @truncate(message_len)));
    }

    try frame.appendSlice(std.heap.page_allocator, message);

    _ = try stream.writeAll(frame.items);
}

const ParsedWebSocketFrame = struct {
    consumed: usize,
    message: []const u8,
};

/// Parse one WebSocket frame from the start of `frame`.
/// Returns `null` if more bytes are needed.
fn parseWebSocketFrame(frame: []u8) !?ParsedWebSocketFrame {
    if (frame.len < 2) return null;

    const byte0 = frame[0];
    const byte1 = frame[1];

    const fin = (byte0 & 0x80) != 0;
    const opcode = byte0 & 0x0F;
    const masked = (byte1 & 0x80) != 0;
    var payload_len: usize = @intCast(byte1 & 0x7F);

    var offset: usize = 2;

    if (payload_len == 126) {
        if (frame.len < 4) return null;
        payload_len = @as(usize, @intCast(frame[2])) << 8 | @as(usize, @intCast(frame[3]));
        offset = 4;
    } else if (payload_len == 127) {
        if (frame.len < 10) return null;
        payload_len = @as(usize, @intCast(frame[2])) << 56 |
            @as(usize, @intCast(frame[3])) << 48 |
            @as(usize, @intCast(frame[4])) << 40 |
            @as(usize, @intCast(frame[5])) << 32 |
            @as(usize, @intCast(frame[6])) << 24 |
            @as(usize, @intCast(frame[7])) << 16 |
            @as(usize, @intCast(frame[8])) << 8 |
            @as(usize, @intCast(frame[9]));
        offset = 10;
    }

    if (masked) {
        if (frame.len < offset + 4 + payload_len) return null;
    } else {
        if (frame.len < offset + payload_len) return null;
    }

    var payload: []u8 = undefined;

    // Unmask if needed
    if (masked) {
        const mask = frame[offset .. offset + 4];
        payload = frame[offset + 4 .. offset + 4 + payload_len];
        for (payload, 0..) |*byte, i| {
            byte.* ^= mask[i % 4];
        }
    } else {
        payload = frame[offset .. offset + payload_len];
    }

    // Check opcode
    if (opcode == 0x8) return error.ConnectionClosed; // Close frame
    if (opcode == 0x9) {
        return .{ .consumed = if (masked) offset + 4 + payload_len else offset + payload_len, .message = &[_]u8{} };
    } // Ping - ignore
    if (opcode == 0xA) {
        return .{ .consumed = if (masked) offset + 4 + payload_len else offset + payload_len, .message = &[_]u8{} };
    } // Pong - ignore
    if (opcode == 0x2) {
        // Ignore binary frames; this server accepts JSON text only.
        return .{ .consumed = if (masked) offset + 4 + payload_len else offset + payload_len, .message = &[_]u8{} };
    }
    if (opcode != 0x1) return error.UnsupportedOpcode; // Only text frames

    if (!fin) return error.FragmentedFramesNotSupported;

    const consumed = if (masked) offset + 4 + payload_len else offset + payload_len;
    return .{ .consumed = consumed, .message = payload };
}

/// Compute the Sec-WebSocket-Accept value
fn computeWebSocketAccept(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{key, ws_guid});
    defer allocator.free(combined);

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &hash, .{});

    const out_len = std.base64.standard.Encoder.calcSize(hash.len);
    const out = try allocator.alloc(u8, out_len);
    _ = std.base64.standard.Encoder.encode(out, &hash);
    return out;
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

test "staticRouteForPath serves favicon assets" {
    const svg = Server.staticRouteForPath("/favicon.svg") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("web_ui/favicon.svg", svg.path);
    try std.testing.expectEqualStrings("image/svg+xml; charset=utf-8", svg.content_type);

    const ico = Server.staticRouteForPath("/favicon.ico") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("web_ui/favicon.ico", ico.path);
    try std.testing.expectEqualStrings("image/x-icon", ico.content_type);
}

test "staticRouteForPath returns null for unknown path" {
    try std.testing.expect(Server.staticRouteForPath("/missing") == null);
}

test "initialWebSocketBootstrapMessage requests recent sessions" {
    try std.testing.expectEqualStrings("{\"type\":\"list_sessions\"}", initialWebSocketBootstrapMessage());
}
