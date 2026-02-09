const std = @import("std");
const skills = @import("skills.zig");
const tools = @import("tools.zig");
const pm = @import("provider_manager.zig");
const store = @import("provider_store.zig");
const config_store = @import("config_store.zig");
const llm = @import("llm.zig");
const catalog = @import("models_catalog.zig");

pub const CommandTag = enum {
    none,
    quit,
    list_skills,
    load_skill,
    list_tools,
    run_tool,
    list_providers,
    default_model,
    connect_provider,
    set_model,
};

pub const Command = struct {
    tag: CommandTag,
    arg: []const u8,
};

pub fn parseCommand(line: []const u8) Command {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return .{ .tag = .none, .arg = "" };

    if (std.mem.eql(u8, trimmed, "/quit")) {
        return .{ .tag = .quit, .arg = "" };
    }
    if (std.mem.eql(u8, trimmed, "/skills")) {
        return .{ .tag = .list_skills, .arg = "" };
    }
    if (std.mem.eql(u8, trimmed, "/tools")) {
        return .{ .tag = .list_tools, .arg = "" };
    }
    if (std.mem.startsWith(u8, trimmed, "/skill")) {
        var rest = trimmed[6..];
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len > 0) {
            return .{ .tag = .load_skill, .arg = rest };
        }
    }
    if (std.mem.startsWith(u8, trimmed, "/tool")) {
        var rest = trimmed[5..];
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len > 0) {
            return .{ .tag = .run_tool, .arg = rest };
        }
    }
    if (std.mem.eql(u8, trimmed, "/providers")) {
        return .{ .tag = .list_providers, .arg = "" };
    }
    if (std.mem.startsWith(u8, trimmed, "/default-model")) {
        var rest = trimmed[14..];
        rest = std.mem.trim(u8, rest, " \t");
        if (rest.len > 0) {
            return .{ .tag = .default_model, .arg = rest };
        }
    }
    if (std.mem.startsWith(u8, trimmed, "/connect")) {
        var rest = trimmed[8..];
        rest = std.mem.trim(u8, rest, " \t");
        return .{ .tag = .connect_provider, .arg = rest };
    }
    if (std.mem.startsWith(u8, trimmed, "/model")) {
        var rest = trimmed[6..];
        rest = std.mem.trim(u8, rest, " \t");
        return .{ .tag = .set_model, .arg = rest };
    }

    return .{ .tag = .none, .arg = "" };
}

fn autocompleteCommand(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return trimmed;
    if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) return trimmed;

    const commands = commandNames();
    var matches: usize = 0;
    var winner: []const u8 = trimmed;

    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd, trimmed)) return trimmed;
        if (std.mem.startsWith(u8, cmd, trimmed)) {
            matches += 1;
            winner = cmd;
        }
    }

    return if (matches == 1) winner else trimmed;
}

const EditKey = enum {
    tab,
    backspace,
    enter,
    character,
};

const AuthMethod = enum {
    api,
    subscription,
};

const OPENAI_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann";
const OPENAI_ISSUER = "https://auth.openai.com";

const HistoryNav = enum {
    up,
    down,
};

const CommandHistory = struct {
    items: std.ArrayList([]u8),

    fn init() CommandHistory {
        return .{ .items = .{} };
    }

    fn deinit(self: *CommandHistory, allocator: std.mem.Allocator) void {
        for (self.items.items) |entry| allocator.free(entry);
        self.items.deinit(allocator);
    }

    fn append(self: *CommandHistory, allocator: std.mem.Allocator, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.items.items.len > 0 and std.mem.eql(u8, self.items.items[self.items.items.len - 1], trimmed)) return;
        try self.items.append(allocator, try allocator.dupe(u8, trimmed));
    }
};

fn historyPathAlloc(allocator: std.mem.Allocator, base_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ base_path, "history" });
}

fn loadHistory(allocator: std.mem.Allocator, base_path: []const u8, history: *CommandHistory) !void {
    const path = try historyPathAlloc(allocator, base_path);
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const text = try file.readToEndAlloc(allocator, 2 * 1024 * 1024);
    defer allocator.free(text);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try history.append(allocator, line);
    }
}

fn appendHistoryLine(allocator: std.mem.Allocator, base_path: []const u8, line: []const u8) !void {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return;

    const path = try historyPathAlloc(allocator, base_path);
    defer allocator.free(path);

    const dir_path = std.fs.path.dirname(path) orelse return;
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.fs.createFileAbsolute(path, .{}),
        else => return err,
    };
    defer file.close();

    try file.seekFromEnd(0);
    try file.writeAll(trimmed);
    try file.writeAll("\n");
}

fn historyNextIndex(entries: []const []const u8, current: ?usize, nav: HistoryNav) ?usize {
    if (entries.len == 0) return null;
    return switch (nav) {
        .up => if (current) |idx| if (idx > 0) idx - 1 else 0 else entries.len - 1,
        .down => if (current) |idx| if (idx + 1 < entries.len) idx + 1 else null else null,
    };
}

const ActiveModel = struct {
    provider_id: []const u8,
    model_id: []const u8,
    api_key: ?[]const u8,
};

const ModelOption = struct {
    provider_id: []const u8,
    model_id: []const u8,
    display_name: []const u8,
};

const ModelSelection = struct {
    provider_id: []const u8,
    model_id: []const u8,
};

fn parseModelSelection(input: []const u8) ?ModelSelection {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return null;
    const slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return null;
    if (slash == 0 or slash + 1 >= trimmed.len) return null;
    return .{
        .provider_id = trimmed[0..slash],
        .model_id = trimmed[slash + 1 ..],
    };
}

const OwnedModelSelection = struct {
    provider_id: []u8,
    model_id: []u8,

    fn deinit(self: *OwnedModelSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model_id);
    }
};

fn applyEditKey(
    allocator: std.mem.Allocator,
    current: []const u8,
    key: EditKey,
    character: u8,
) ![]u8 {
    return switch (key) {
        .tab => allocator.dupe(u8, autocompleteCommand(current)),
        .backspace => {
            if (current.len == 0) return allocator.dupe(u8, current);
            return allocator.dupe(u8, current[0 .. current.len - 1]);
        },
        .character => {
            if (character < 32 or character == 127) return allocator.dupe(u8, current);
            var out = try allocator.alloc(u8, current.len + 1);
            @memcpy(out[0..current.len], current);
            out[current.len] = character;
            return out;
        },
        .enter => allocator.dupe(u8, current),
    };
}

pub fn run(allocator: std.mem.Allocator) !void {
    const stdin_file = std.fs.File.stdin();
    const stdin = stdin_file.deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const prompt_text = if (cwd.len > 0)
        try std.fmt.allocPrint(allocator, "{s}> ", .{cwd})
    else
        try allocator.dupe(u8, "> ");
    defer allocator.free(prompt_text);

    const home = std.posix.getenv("HOME") orelse "";
    const config_dir = try std.fs.path.join(allocator, &.{ home, ".config", "zagent" });
    defer allocator.free(config_dir);
    try std.fs.cwd().makePath(config_dir);

    const skill_list = try skills.discover(allocator, cwd, home);
    defer skills.freeList(allocator, skill_list);

    const providers_owned = try catalog.loadProviderSpecs(allocator);
    defer catalog.freeProviderSpecs(allocator, providers_owned);
    const providers = if (providers_owned.len > 0) providers_owned else defaultProviderSpecs();
    var stored_pairs = try store.load(allocator, config_dir);
    defer store.free(allocator, stored_pairs);

    var provider_states = try resolveProviderStates(allocator, providers, stored_pairs);
    defer pm.ProviderManager.freeResolved(allocator, provider_states);

    var history = CommandHistory.init();
    defer history.deinit(allocator);
    try loadHistory(allocator, config_dir, &history);
    var selected_model: ?OwnedModelSelection = null;
    defer if (selected_model) |*sel| sel.deinit(allocator);

    const persisted_model = try config_store.loadSelectedModel(allocator, config_dir);
    if (persisted_model) |persisted| {
        selected_model = .{
            .provider_id = persisted.provider_id,
            .model_id = persisted.model_id,
        };
    }

    try stdout.print(
        "zagent MVP. Commands: /skills, /skill <name>, /tools, /tool <spec>, /providers, /default-model <provider>, /model <provider/model>, /connect, /quit\n",
        .{},
    );
    while (true) {
        const line_opt = try readPromptLine(allocator, stdin_file, stdin, stdout, prompt_text, &history);
        if (line_opt == null) {
            try stdout.print("\n", .{});
            break;
        }

        const line = line_opt.?;
        defer allocator.free(line);

        const prev_history_len = history.items.items.len;
        try history.append(allocator, line);
        if (history.items.items.len > prev_history_len) {
            try appendHistoryLine(allocator, config_dir, line);
        }

        const normalized = autocompleteCommand(line);
        if (!std.mem.eql(u8, normalized, std.mem.trim(u8, line, " \t\r\n"))) {
            try stdout.print("autocompleted: {s}\n", .{normalized});
        }

        const command = parseCommand(normalized);
        switch (command.tag) {
            .quit => break,
            .list_skills => {
                if (skill_list.len == 0) {
                    try stdout.print("No skills found.\n", .{});
                    continue;
                }
                for (skill_list) |skill| {
                    try stdout.print("- {s} ({s})\n", .{ skill.name, skill.path });
                }
            },
            .load_skill => {
                const skill = skills.findByName(skill_list, command.arg);
                if (skill) |s| {
                    try stdout.print("Loaded skill: {s}\n\n{s}\n", .{ s.name, s.body });
                } else {
                    try stdout.print("Skill not found: {s}\n", .{command.arg});
                }
            },
            .list_tools => {
                for (tools.list()) |tool_name| {
                    try stdout.print("- {s}\n", .{tool_name});
                }
            },
            .run_tool => {
                const output = tools.execute(allocator, command.arg) catch |err| {
                    try stdout.print("Tool failed: {s}\n", .{@errorName(err)});
                    continue;
                };
                defer allocator.free(output);

                try stdout.print("{s}\n", .{output});
            },
            .list_providers => {
                const view = try formatProvidersOutput(allocator, providers, provider_states);
                defer allocator.free(view);
                try stdout.print("{s}", .{view});
            },
            .default_model => {
                var found: ?pm.ProviderState = null;
                for (provider_states) |p| {
                    if (std.mem.eql(u8, p.id, command.arg)) {
                        found = p;
                        break;
                    }
                }
                if (found == null) {
                    try stdout.print("Provider not connected: {s}\n", .{command.arg});
                    continue;
                }

                const model_id = pm.ProviderManager.defaultModelIDForProvider(found.?.id, found.?.models);
                if (model_id) |id| {
                    try stdout.print("Default model for {s}: {s}\n", .{ found.?.id, id });
                } else {
                    try stdout.print("No models configured for {s}\n", .{found.?.id});
                }
            },
            .connect_provider => {
                const chosen = if (command.arg.len > 0)
                    findProviderSpecByID(providers, command.arg)
                else
                    try chooseProvider(allocator, stdin, stdout, providers, provider_states);
                if (chosen == null) {
                    if (command.arg.len > 0) {
                        try stdout.print("Unknown provider: {s}\n", .{command.arg});
                    }
                    continue;
                }

                const provider = chosen.?;
                if (provider.env_vars.len == 0) {
                    try stdout.print("Provider {s} has no API key env mapping.\n", .{provider.id});
                    continue;
                }

                var method: AuthMethod = .api;
                if (supportsSubscription(provider.id)) {
                    const method_opt = try promptLine(allocator, stdin, stdout, "Auth method [api/subscription] (default api): ");
                    if (method_opt) |raw| {
                        defer allocator.free(raw);
                        method = chooseAuthMethod(std.mem.trim(u8, raw, " \t\r\n"), true);
                    }
                }

                const env_name = provider.env_vars[0];
                var key_slice: []const u8 = "";
                var owned_key: ?[]u8 = null;
                defer if (owned_key) |k| allocator.free(k);

                if (method == .subscription) {
                    const sub_key = try connectSubscription(allocator, stdin, stdout, provider.id);
                    if (sub_key == null) continue;
                    owned_key = sub_key.?;
                    key_slice = owned_key.?;
                } else {
                    const key_opt = try promptLine(allocator, stdin, stdout, "API key: ");
                    if (key_opt == null) continue;
                    defer allocator.free(key_opt.?);
                    const key = std.mem.trim(u8, key_opt.?, " \t\r\n");
                    if (key.len == 0) {
                        try stdout.print("Cancelled: empty key.\n", .{});
                        continue;
                    }
                    key_slice = key;
                }

                try store.upsertFile(allocator, config_dir, env_name, key_slice);
                try stdout.print("Stored {s} in {s}/providers.env\n", .{ env_name, config_dir });

                store.free(allocator, stored_pairs);
                stored_pairs = try store.load(allocator, config_dir);

                pm.ProviderManager.freeResolved(allocator, provider_states);
                provider_states = try resolveProviderStates(allocator, providers, stored_pairs);
            },
            .set_model => {
                if (command.arg.len == 0) {
                    if (selected_model) |sel| {
                        try stdout.print("Current model: {s}/{s}\n", .{ sel.provider_id, sel.model_id });
                        continue;
                    }

                    const picked = try interactiveModelSelect(allocator, stdin, stdout, stdin_file, providers, provider_states);
                    if (picked == null) {
                        try stdout.print("No explicit model set. Using default connected provider model.\n", .{});
                        continue;
                    }
                    if (selected_model) |*old| old.deinit(allocator);
                    selected_model = .{
                        .provider_id = try allocator.dupe(u8, picked.?.provider_id),
                        .model_id = try allocator.dupe(u8, picked.?.model_id),
                    };
                    try config_store.saveSelectedModel(allocator, config_dir, .{
                        .provider_id = picked.?.provider_id,
                        .model_id = picked.?.model_id,
                    });
                    try stdout.print("Active model set to {s}/{s}\n", .{ picked.?.provider_id, picked.?.model_id });
                    continue;
                }
                const parsed = parseModelSelection(command.arg);
                if (parsed == null) {
                    try stdout.print("Model must be in format provider/model\n", .{});
                    continue;
                }
                const p = parsed.?;
                if (findConnectedProvider(provider_states, p.provider_id) == null) {
                    try stdout.print("Provider not connected: {s}\n", .{p.provider_id});
                    continue;
                }
                if (!providerHasModel(providers, p.provider_id, p.model_id)) {
                    try stdout.print("Unknown model: {s}/{s}\n", .{ p.provider_id, p.model_id });
                    continue;
                }

                if (selected_model) |*old| old.deinit(allocator);
                selected_model = .{
                    .provider_id = try allocator.dupe(u8, p.provider_id),
                    .model_id = try allocator.dupe(u8, p.model_id),
                };
                try config_store.saveSelectedModel(allocator, config_dir, .{
                    .provider_id = p.provider_id,
                    .model_id = p.model_id,
                });
                try stdout.print("Active model set to {s}/{s}\n", .{ p.provider_id, p.model_id });
            },
            .none => {
                const trimmed = std.mem.trim(u8, normalized, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (trimmed[0] == '/') {
                    try stdout.print("Unknown command: {s}\n", .{trimmed});
                    continue;
                }

                const active = chooseActiveModel(providers, provider_states, selected_model);

                if (active == null) {
                    try stdout.print("No connected providers. Run /providers then /connect <provider-id>.\n", .{});
                    continue;
                }

                const response = runModelTurnWithTools(allocator, stdout, active.?, trimmed) catch |err| {
                    try stdout.print("Model query failed: {s}\n", .{@errorName(err)});
                    continue;
                };
                defer allocator.free(response);

                try stdout.print("{s}\n", .{response});
            },
        }
    }
}

fn readPromptLine(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdin_reader: anytype,
    stdout: anytype,
    prompt: []const u8,
    history: *CommandHistory,
) !?[]u8 {
    if (!stdin_file.isTty()) {
        try stdout.print("{s}", .{prompt});
        return stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    }

    const original = std.posix.tcgetattr(stdin_file.handle) catch {
        try stdout.print("{s}", .{prompt});
        return stdin_reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
    };
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    try std.posix.tcsetattr(stdin_file.handle, .NOW, raw);
    defer std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};

    var line = try allocator.alloc(u8, 0);
    defer allocator.free(line);
    var history_index: ?usize = null;

    try stdout.print("{s}", .{prompt});

    var byte_buf: [3]u8 = undefined;
    while (true) {
        const n = try stdin_file.read(byte_buf[0..1]);
        if (n == 0) {
            if (line.len == 0) return null;
            return try allocator.dupe(u8, line);
        }

        const ch = byte_buf[0];
        if (ch == 27) {
            const n1 = try stdin_file.read(byte_buf[1..2]);
            if (n1 == 0) continue;
            if (byte_buf[1] != '[') continue;

            const n2 = try stdin_file.read(byte_buf[2..3]);
            if (n2 == 0) continue;
            const nav: ?HistoryNav = switch (byte_buf[2]) {
                'A' => .up,
                'B' => .down,
                else => null,
            };
            if (nav == null) continue;

            const next_index = historyNextIndex(history.items.items, history_index, nav.?);
            history_index = next_index;

            const entry = if (history_index) |idx| history.items.items[idx] else "";
            line = try allocator.realloc(line, entry.len);
            @memcpy(line, entry);
            try stdout.print("\r\x1b[2K{s}{s}", .{ prompt, line });
            continue;
        }

        if (ch == '\n' or ch == '\r') {
            try stdout.print("\n", .{});
            return try allocator.dupe(u8, line);
        }

        history_index = null;

        const next = blk: {
            if (ch == 9) break :blk try applyEditKey(allocator, line, .tab, 0);
            if (ch == 127 or ch == 8) break :blk try applyEditKey(allocator, line, .backspace, 0);
            break :blk try applyEditKey(allocator, line, .character, ch);
        };
        defer allocator.free(next);

        line = try allocator.realloc(line, next.len);
        @memcpy(line, next);

        try stdout.print("\r\x1b[2K{s}{s}", .{ prompt, line });
    }
}

test "parse command recognizes slash commands" {
    const list = parseCommand("/skills");
    try std.testing.expectEqual(CommandTag.list_skills, list.tag);

    const load = parseCommand("/skill brainstorming");
    try std.testing.expectEqual(CommandTag.load_skill, load.tag);
    try std.testing.expectEqualStrings("brainstorming", load.arg);

    const quit = parseCommand("/quit");
    try std.testing.expectEqual(CommandTag.quit, quit.tag);

    const tools_cmd = parseCommand("/tools");
    try std.testing.expectEqual(CommandTag.list_tools, tools_cmd.tag);

    const tool = parseCommand("/tool read ./README.md");
    try std.testing.expectEqual(CommandTag.run_tool, tool.tag);
    try std.testing.expectEqualStrings("read ./README.md", tool.arg);

    const providers = parseCommand("/providers");
    try std.testing.expectEqual(CommandTag.list_providers, providers.tag);

    const default_model = parseCommand("/default-model openai");
    try std.testing.expectEqual(CommandTag.default_model, default_model.tag);
    try std.testing.expectEqualStrings("openai", default_model.arg);

    const connect = parseCommand("/connect");
    try std.testing.expectEqual(CommandTag.connect_provider, connect.tag);

    const connect_with_arg = parseCommand("/connect openai");
    try std.testing.expectEqual(CommandTag.connect_provider, connect_with_arg.tag);
    try std.testing.expectEqualStrings("openai", connect_with_arg.arg);

    const model = parseCommand("/model openai/gpt-5");
    try std.testing.expectEqual(CommandTag.set_model, model.tag);
    try std.testing.expectEqualStrings("openai/gpt-5", model.arg);
}

test "parse command trims /skill argument" {
    const load = parseCommand("/skill   systematic-debugging   ");
    try std.testing.expectEqual(CommandTag.load_skill, load.tag);
    try std.testing.expectEqualStrings("systematic-debugging", load.arg);
}

test "autocomplete expands unique command prefixes" {
    try std.testing.expectEqualStrings("/providers", autocompleteCommand("/pro"));
    try std.testing.expectEqualStrings("/connect", autocompleteCommand("/con"));
}

test "autocomplete keeps ambiguous and exact commands" {
    try std.testing.expectEqualStrings("/s", autocompleteCommand("/s"));
    try std.testing.expectEqualStrings("/skills", autocompleteCommand("/skills"));
}

test "apply edit key tab completes command" {
    const allocator = std.testing.allocator;
    const next = try applyEditKey(allocator, "/pro", .tab, 0);
    defer allocator.free(next);
    try std.testing.expectEqualStrings("/providers", next);
}

test "apply edit key backspace removes last character" {
    const allocator = std.testing.allocator;
    const next = try applyEditKey(allocator, "/tool", .backspace, 0);
    defer allocator.free(next);
    try std.testing.expectEqualStrings("/too", next);
}

test "providers output includes available providers when none connected" {
    const allocator = std.testing.allocator;
    const providers = defaultProviderSpecs();
    const text = try formatProvidersOutput(allocator, providers, &.{});
    defer allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "Available providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "openai") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/connect") != null);
}

test "choose auth method parses subscription and defaults to api" {
    try std.testing.expectEqual(AuthMethod.subscription, chooseAuthMethod("subscription", true));
    try std.testing.expectEqual(AuthMethod.subscription, chooseAuthMethod("sub", true));
    try std.testing.expectEqual(AuthMethod.api, chooseAuthMethod("", true));
    try std.testing.expectEqual(AuthMethod.api, chooseAuthMethod("api", true));
    try std.testing.expectEqual(AuthMethod.api, chooseAuthMethod("subscription", false));
}

test "parse model selection supports provider/model format" {
    const selection = parseModelSelection("openai/gpt-5");
    try std.testing.expect(selection != null);
    try std.testing.expectEqualStrings("openai", selection.?.provider_id);
    try std.testing.expectEqualStrings("gpt-5", selection.?.model_id);
}

test "default model prefers non-nano for openai oauth tokens" {
    const providers = defaultProviderSpecs();
    const connected = [_]pm.ProviderState{.{
        .id = "openai",
        .display_name = "OpenAI",
        .key = "a.b.c",
        .connected = true,
        .models = providers[1].models,
    }};

    const active = chooseActiveModel(providers, &connected, null);
    try std.testing.expect(active != null);
    try std.testing.expectEqualStrings("gpt-5", active.?.model_id);
}

test "resolve model pick accepts index and id" {
    const options = [_]pm.Model{
        .{ .id = "gpt-5", .display_name = "GPT-5" },
        .{ .id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
    };

    const by_index = resolveModelPick(options[0..], "2");
    try std.testing.expect(by_index != null);
    try std.testing.expectEqualStrings("gpt-5-nano", by_index.?.id);

    const by_id = resolveModelPick(options[0..], "gpt-5");
    try std.testing.expect(by_id != null);
    try std.testing.expectEqualStrings("gpt-5", by_id.?.id);
}

test "filter model options matches model and provider text" {
    const options = [_]ModelOption{
        .{ .provider_id = "openai", .model_id = "gpt-5", .display_name = "GPT-5" },
        .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4", .display_name = "Claude Sonnet 4" },
        .{ .provider_id = "openai", .model_id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
    };

    const by_provider = try filterModelOptions(std.testing.allocator, options[0..], "anth");
    defer std.testing.allocator.free(by_provider);
    try std.testing.expectEqual(@as(usize, 1), by_provider.len);
    try std.testing.expectEqualStrings("claude-sonnet-4", by_provider[0].model_id);

    const by_model = try filterModelOptions(std.testing.allocator, options[0..], "nano");
    defer std.testing.allocator.free(by_model);
    try std.testing.expectEqual(@as(usize, 1), by_model.len);
    try std.testing.expectEqualStrings("gpt-5-nano", by_model[0].model_id);
}

test "filter preview line includes matching model names" {
    const options = [_]ModelOption{
        .{ .provider_id = "openai", .model_id = "gpt-5", .display_name = "GPT-5" },
        .{ .provider_id = "openai", .model_id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
    };

    const line = try buildFilterPreviewLine(std.testing.allocator, options[0..], "nano");
    defer std.testing.allocator.free(line);
    try std.testing.expect(containsIgnoreCase(line, "gpt-5-nano"));
}

test "filter preview block includes multiple match rows" {
    const options = [_]ModelOption{
        .{ .provider_id = "openai", .model_id = "gpt-5", .display_name = "GPT-5" },
        .{ .provider_id = "openai", .model_id = "gpt-5.3-codex", .display_name = "GPT-5.3 Codex" },
        .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4", .display_name = "Claude Sonnet 4" },
    };

    const block = try buildFilterPreviewBlock(std.testing.allocator, options[0..], "5");
    defer std.testing.allocator.free(block);
    try std.testing.expect(containsIgnoreCase(block, "openai/gpt-5"));
    try std.testing.expect(containsIgnoreCase(block, "openai/gpt-5.3-codex"));
}

test "auto pick single model when only one match" {
    const options = [_]ModelOption{
        .{ .provider_id = "openai", .model_id = "gpt-5.3-codex", .display_name = "GPT-5.3 Codex" },
    };
    const picked = autoPickSingleModel(options[0..]);
    try std.testing.expect(picked != null);
    try std.testing.expectEqualStrings("gpt-5.3-codex", picked.?.model_id);
}

test "known tool name accepts supported tools" {
    try std.testing.expect(isKnownToolName("bash"));
    try std.testing.expect(isKnownToolName("read_file"));
    try std.testing.expect(isKnownToolName("replace_in_file"));
}

test "known tool name rejects unknown tools" {
    try std.testing.expect(!isKnownToolName("read"));
    try std.testing.expect(!isKnownToolName("invalid"));
}

test "tool routing prompt includes codebase analysis guidance" {
    const allocator = std.testing.allocator;
    const prompt = try buildToolRoutingPrompt(allocator, "how does the new file edit harness work?");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Use local tools") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "list_files") != null);
}

test "tool routing prompt preserves original user request" {
    const allocator = std.testing.allocator;
    const prompt = try buildToolRoutingPrompt(allocator, "explain src/repl.zig flow");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "explain src/repl.zig flow") != null);
}

test "strict routing prompt requires at least one read or list" {
    const allocator = std.testing.allocator;
    const prompt = try buildStrictToolRoutingPrompt(allocator, "how does the harness work?");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "must call") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "list_files") != null);
}

test "repo specific detector catches codebase questions" {
    try std.testing.expect(isLikelyRepoSpecificQuestion("how does the new file edit harness work?"));
    try std.testing.expect(isLikelyRepoSpecificQuestion("explain src/repl.zig"));
    try std.testing.expect(isLikelyRepoSpecificQuestion("what does function runModelTurnWithTools do"));
}

test "repo specific detector ignores generic questions" {
    try std.testing.expect(!isLikelyRepoSpecificQuestion("what is a monad"));
    try std.testing.expect(!isLikelyRepoSpecificQuestion("write a haiku"));
}

test "infer tool call spec for system time prompt" {
    const sample = "{\"output\":[{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"input\\\":\\\"date +%T\\\"}\"}]}";
    const parsed = try llm.parseOpenAIFunctionCall(std.testing.allocator, sample);
    try std.testing.expect(parsed != null);
    defer if (parsed) |p| p.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("bash", parsed.?.tool);
}

test "infer tool call spec for time not date followup" {
    const parsed = try llm.parseOpenAIFunctionCall(std.testing.allocator, "hello");
    try std.testing.expect(parsed == null);
}

test "history navigation moves through entries with up and down" {
    const entries = [_][]const u8{ "/providers", "/connect openai", "/tools" };

    const first_up = historyNextIndex(&entries, null, .up);
    try std.testing.expectEqual(@as(?usize, 2), first_up);

    const second_up = historyNextIndex(&entries, first_up, .up);
    try std.testing.expectEqual(@as(?usize, 1), second_up);

    const down = historyNextIndex(&entries, second_up, .down);
    try std.testing.expectEqual(@as(?usize, 2), down);

    const to_current = historyNextIndex(&entries, down, .down);
    try std.testing.expectEqual(@as(?usize, null), to_current);
}

test "history persistence loads prior session entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try appendHistoryLine(allocator, root, "/providers");
    try appendHistoryLine(allocator, root, "/tools");

    var history = CommandHistory.init();
    defer history.deinit(allocator);
    try loadHistory(allocator, root, &history);

    try std.testing.expectEqual(@as(usize, 2), history.items.items.len);
    try std.testing.expectEqualStrings("/providers", history.items.items[0]);
    try std.testing.expectEqualStrings("/tools", history.items.items[1]);
}

test "history append ignores empty lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const allocator = std.testing.allocator;
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    try appendHistoryLine(allocator, root, "   \n");

    var history = CommandHistory.init();
    defer history.deinit(allocator);
    try loadHistory(allocator, root, &history);
    try std.testing.expectEqual(@as(usize, 0), history.items.items.len);
}

fn commandNames() []const []const u8 {
    return &.{
        "/quit",
        "/skills",
        "/skill",
        "/tools",
        "/tool",
        "/providers",
        "/default-model",
        "/connect",
        "/model",
    };
}

fn defaultProviderSpecs() []const pm.ProviderSpec {
    return &.{
        .{
            .id = "anthropic",
            .display_name = "Anthropic",
            .env_vars = &.{"ANTHROPIC_API_KEY"},
            .models = &.{
                .{ .id = "claude-sonnet-4", .display_name = "Claude Sonnet 4" },
                .{ .id = "claude-haiku-4.5", .display_name = "Claude Haiku 4.5" },
            },
        },
        .{
            .id = "openai",
            .display_name = "OpenAI",
            .env_vars = &.{"OPENAI_API_KEY"},
            .models = &.{
                .{ .id = "gpt-5", .display_name = "GPT-5" },
                .{ .id = "gpt-5-nano", .display_name = "GPT-5 Nano" },
            },
        },
        .{
            .id = "google",
            .display_name = "Google",
            .env_vars = &.{"GOOGLE_GENERATIVE_AI_API_KEY"},
            .models = &.{
                .{ .id = "gemini-2.5-pro", .display_name = "Gemini 2.5 Pro" },
                .{ .id = "gemini-2.5-flash", .display_name = "Gemini 2.5 Flash" },
            },
        },
    };
}

fn envPairsForProviders(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    stored: []const store.StoredPair,
) ![]pm.EnvPair {
    var out = try std.ArrayList(pm.EnvPair).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (providers) |provider| {
        for (provider.env_vars) |name| {
            for (stored) |pair| {
                if (std.mem.eql(u8, pair.name, name)) {
                    try out.append(allocator, .{ .name = pair.name, .value = pair.value });
                }
            }
            const value = std.posix.getenv(name) orelse continue;
            try out.append(allocator, .{ .name = name, .value = value });
        }
    }

    return out.toOwnedSlice(allocator);
}

fn resolveProviderStates(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    stored: []const store.StoredPair,
) ![]pm.ProviderState {
    const env_pairs = try envPairsForProviders(allocator, providers, stored);
    defer allocator.free(env_pairs);
    return pm.ProviderManager.resolve(allocator, providers, env_pairs, .{});
}

fn promptLine(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    prompt: []const u8,
) !?[]u8 {
    try stdout.print("{s}", .{prompt});
    return stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
}

fn chooseProvider(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
) !?pm.ProviderSpec {
    try stdout.print("Connect a provider:\n", .{});
    for (providers, 0..) |provider, idx| {
        const status = if (isConnected(provider.id, connected)) "connected" else "not connected";
        try stdout.print("  {d}) {s} [{s}]\n", .{ idx + 1, provider.display_name, status });
    }
    const choice_opt = try promptLine(allocator, stdin, stdout, "Provider number or id: ");
    if (choice_opt == null) return null;
    defer allocator.free(choice_opt.?);
    const choice = std.mem.trim(u8, choice_opt.?, " \t\r\n");
    if (choice.len == 0) return null;

    const parsed_num = std.fmt.parseInt(usize, choice, 10) catch null;
    if (parsed_num) |n| {
        if (n > 0 and n <= providers.len) {
            return providers[n - 1];
        }
    }

    for (providers) |provider| {
        if (std.mem.eql(u8, provider.id, choice)) return provider;
    }

    try stdout.print("Unknown provider: {s}\n", .{choice});
    return null;
}

fn isConnected(provider_id: []const u8, connected: []const pm.ProviderState) bool {
    for (connected) |item| {
        if (std.mem.eql(u8, item.id, provider_id)) return true;
    }
    return false;
}

fn findProviderSpecByID(providers: []const pm.ProviderSpec, provider_id: []const u8) ?pm.ProviderSpec {
    for (providers) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

fn findConnectedProvider(connected: []const pm.ProviderState, provider_id: []const u8) ?pm.ProviderState {
    for (connected) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

fn providerHasModel(providers: []const pm.ProviderSpec, provider_id: []const u8, model_id: []const u8) bool {
    const provider = findProviderSpecByID(providers, provider_id) orelse return false;
    for (provider.models) |model| {
        if (std.mem.eql(u8, model.id, model_id)) return true;
    }
    return false;
}

fn chooseActiveModel(
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
    selected: ?OwnedModelSelection,
) ?ActiveModel {
    if (selected) |sel| {
        const provider = findConnectedProvider(connected, sel.provider_id) orelse return null;
        if (!providerHasModel(providers, sel.provider_id, sel.model_id)) return null;
        return .{ .provider_id = sel.provider_id, .model_id = sel.model_id, .api_key = provider.key };
    }

    if (connected.len == 0) return null;
    const provider = connected[0];
    const default_model = chooseDefaultModelForConnected(provider) orelse return null;
    return .{ .provider_id = provider.id, .model_id = default_model, .api_key = provider.key };
}

fn chooseDefaultModelForConnected(provider: pm.ProviderState) ?[]const u8 {
    if (std.mem.eql(u8, provider.id, "openai") and provider.key != null and isLikelyOAuthToken(provider.key.?)) {
        for (provider.models) |m| {
            if (std.mem.indexOf(u8, m.id, "nano") == null and std.mem.indexOf(u8, m.id, "mini") == null) {
                return m.id;
            }
        }
    }
    return pm.ProviderManager.defaultModelIDForProvider(provider.id, provider.models);
}

fn isLikelyOAuthToken(token: []const u8) bool {
    if (std.mem.startsWith(u8, token, "sk-")) return false;
    return std.mem.count(u8, token, ".") >= 2;
}

fn interactiveModelSelect(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    stdin_file: std.fs.File,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
) !?ModelSelection {
    if (connected.len == 0) {
        try stdout.print("No connected providers. Run /connect first.\n", .{});
        return null;
    }

    const options = try collectModelOptions(allocator, providers, connected);
    defer allocator.free(options);

    const query_opt = if (stdin_file.isTty())
        try readFilterQueryRealtime(allocator, stdin_file, stdout, options)
    else
        try promptLine(allocator, stdin, stdout, "Filter models (empty = all): ");
    if (query_opt == null) return null;
    defer allocator.free(query_opt.?);
    const query = std.mem.trim(u8, query_opt.?, " \t\r\n");

    const filtered = try filterModelOptions(allocator, options, query);
    defer allocator.free(filtered);
    if (filtered.len == 0) {
        try stdout.print("No models matched filter: {s}\n", .{query});
        return null;
    }

    if (autoPickSingleModel(filtered)) |model| {
        try stdout.print("Auto-selected: {s}/{s}\n", .{ model.provider_id, model.model_id });
        return .{ .provider_id = model.provider_id, .model_id = model.model_id };
    }

    try stdout.print("Select model:\n", .{});
    for (filtered, 0..) |m, i| {
        try stdout.print("  {d}) {s}/{s} ({s})\n", .{ i + 1, m.provider_id, m.model_id, m.display_name });
    }

    const model_pick_opt = try promptLine(allocator, stdin, stdout, "Model number or id: ");
    if (model_pick_opt == null) return null;
    defer allocator.free(model_pick_opt.?);
    const model_pick = std.mem.trim(u8, model_pick_opt.?, " \t\r\n");
    if (model_pick.len == 0) return null;

    const model = resolveGlobalModelPick(filtered, model_pick) orelse {
        try stdout.print("Unknown model: {s}\n", .{model_pick});
        return null;
    };

    return .{ .provider_id = model.provider_id, .model_id = model.model_id };
}

fn resolveModelPick(models: []const pm.Model, pick: []const u8) ?pm.Model {
    const n = std.fmt.parseInt(usize, pick, 10) catch null;
    if (n) |idx| {
        if (idx > 0 and idx <= models.len) return models[idx - 1];
    }
    for (models) |m| {
        if (std.mem.eql(u8, m.id, pick)) return m;
    }
    return null;
}

fn collectModelOptions(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
) ![]ModelOption {
    var out = try std.ArrayList(ModelOption).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (connected) |cp| {
        const spec = findProviderSpecByID(providers, cp.id) orelse continue;
        for (spec.models) |m| {
            try out.append(allocator, .{ .provider_id = cp.id, .model_id = m.id, .display_name = m.display_name });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn filterModelOptions(allocator: std.mem.Allocator, options: []const ModelOption, query: []const u8) ![]ModelOption {
    const q = std.mem.trim(u8, query, " \t\r\n");
    if (q.len == 0) return allocator.dupe(ModelOption, options);

    var out = try std.ArrayList(ModelOption).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (options) |o| {
        if (containsIgnoreCase(o.model_id, q) or containsIgnoreCase(o.display_name, q) or containsIgnoreCase(o.provider_id, q)) {
            try out.append(allocator, o);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        var ok = true;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn resolveGlobalModelPick(options: []const ModelOption, pick: []const u8) ?ModelOption {
    const n = std.fmt.parseInt(usize, pick, 10) catch null;
    if (n) |idx| {
        if (idx > 0 and idx <= options.len) return options[idx - 1];
    }

    for (options) |m| {
        if (std.mem.eql(u8, m.model_id, pick)) return m;
        if (std.mem.eql(u8, m.provider_id, pick)) return m;
        if (std.mem.eql(u8, m.display_name, pick)) return m;
    }

    for (options) |m| {
        if (std.mem.eql(u8, m.provider_id, pick)) return m;
        if (containsIgnoreCase(m.model_id, pick)) return m;
        if (containsIgnoreCase(m.display_name, pick)) return m;
    }
    return null;
}

fn autoPickSingleModel(options: []const ModelOption) ?ModelOption {
    return if (options.len == 1) options[0] else null;
}

fn inferToolCallWithModel(allocator: std.mem.Allocator, active: ActiveModel, input: []const u8) !?llm.ToolRouteCall {
    var defs = try std.ArrayList(llm.ToolRouteDef).initCapacity(allocator, tools.definitions.len);
    defer defs.deinit(allocator);

    for (tools.definitions) |d| {
        try defs.append(allocator, .{ .name = d.name, .description = d.description, .parameters_json = d.parameters_json });
    }

    return llm.inferToolCall(allocator, active.provider_id, active.api_key, active.model_id, input, defs.items) catch |err| switch (err) {
        llm.QueryError.UnsupportedProvider => null,
        else => return err,
    };
}

fn isKnownToolName(name: []const u8) bool {
    for (tools.definitions) |d| {
        if (std.mem.eql(u8, name, d.name)) return true;
    }
    return false;
}

fn buildToolRoutingPrompt(allocator: std.mem.Allocator, user_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Use local tools when they improve correctness. For repository-specific questions, inspect files first with list_files and read_file before answering. For code changes, prefer read_file before write_file or replace_in_file. Only skip tools when the answer is purely general knowledge.\n\nUser request:\n{s}",
        .{user_text},
    );
}

fn buildStrictToolRoutingPrompt(allocator: std.mem.Allocator, user_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "This is a repository-specific question. You must call at least one local inspection tool before giving the final answer. First call list_files or read_file, then answer using concrete file evidence.\n\nUser request:\n{s}",
        .{user_text},
    );
}

fn isLikelyRepoSpecificQuestion(input: []const u8) bool {
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return false;

    if (std.mem.indexOf(u8, t, "/") != null) return true;
    if (containsIgnoreCase(t, "repo") or containsIgnoreCase(t, "codebase")) return true;
    if (containsIgnoreCase(t, "src/")) return true;
    if (containsIgnoreCase(t, ".zig")) return true;
    if (containsIgnoreCase(t, "function") or containsIgnoreCase(t, "file") or containsIgnoreCase(t, "harness")) return true;
    if (containsIgnoreCase(t, "how does") or containsIgnoreCase(t, "where is") or containsIgnoreCase(t, "explain")) return true;

    return false;
}

fn runModelTurnWithTools(allocator: std.mem.Allocator, stdout: anytype, active: ActiveModel, user_input: []const u8) ![]u8 {
    const max_tool_steps: usize = 6;
    var context_prompt = try allocator.dupe(u8, user_input);
    defer allocator.free(context_prompt);
    var forced_repo_probe_done = false;
    const repo_specific = isLikelyRepoSpecificQuestion(user_input);

    var step: usize = 0;
    while (step < max_tool_steps) : (step += 1) {
        const route_prompt = try buildToolRoutingPrompt(allocator, context_prompt);
        defer allocator.free(route_prompt);

        var routed = try inferToolCallWithModel(allocator, active, route_prompt);
        if (routed == null and step == 0 and repo_specific and !forced_repo_probe_done) {
            forced_repo_probe_done = true;
            const strict_prompt = try buildStrictToolRoutingPrompt(allocator, context_prompt);
            defer allocator.free(strict_prompt);
            routed = try inferToolCallWithModel(allocator, active, strict_prompt);
        }

        if (routed == null) {
            return llm.query(allocator, active.provider_id, active.api_key, active.model_id, context_prompt);
        }
        defer {
            var r = routed.?;
            r.deinit(allocator);
        }

        if (!isKnownToolName(routed.?.tool)) {
            return llm.query(allocator, active.provider_id, active.api_key, active.model_id, context_prompt);
        }

        try stdout.print("tool[{d}] {s}\n", .{ step + 1, routed.?.tool });

        const tool_out = tools.executeNamed(allocator, routed.?.tool, routed.?.arguments_json) catch |err| {
            return std.fmt.allocPrint(
                allocator,
                "Tool execution failed at step {d} ({s}): {s}",
                .{ step + 1, routed.?.tool, @errorName(err) },
            );
        };
        defer allocator.free(tool_out);

        const capped = if (tool_out.len > 4000) tool_out[0..4000] else tool_out;
        const next_prompt = try std.fmt.allocPrint(
            allocator,
            "{s}\n\nTool call {d}: {s}\nArguments JSON: {s}\nTool output:\n{s}\n\nYou may call another tool if needed. Otherwise return the final user-facing answer.",
            .{ context_prompt, step + 1, routed.?.tool, routed.?.arguments_json, capped },
        );
        allocator.free(context_prompt);
        context_prompt = next_prompt;
    }

    const fallback_prompt = try std.fmt.allocPrint(
        allocator,
        "{s}\n\nTool loop limit reached ({d}). Return the best final answer based on available context.",
        .{ context_prompt, max_tool_steps },
    );
    defer allocator.free(fallback_prompt);
    return llm.query(allocator, active.provider_id, active.api_key, active.model_id, fallback_prompt);
}

fn shellQuoteSingle(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (text) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn readFilterQueryRealtime(
    allocator: std.mem.Allocator,
    stdin_file: std.fs.File,
    stdout: anytype,
    options: []const ModelOption,
) !?[]u8 {
    const original = std.posix.tcgetattr(stdin_file.handle) catch return try allocator.dupe(u8, "");
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    try std.posix.tcsetattr(stdin_file.handle, .NOW, raw);
    defer std.posix.tcsetattr(stdin_file.handle, .NOW, original) catch {};

    var query = try allocator.alloc(u8, 0);
    defer allocator.free(query);

    var rendered_lines: usize = 0;
    try renderFilterPreview(allocator, stdout, options, query, &rendered_lines);

    var byte_buf: [1]u8 = undefined;
    while (true) {
        const n = try stdin_file.read(&byte_buf);
        if (n == 0) return null;
        const ch = byte_buf[0];
        if (ch == '\n' or ch == '\r') {
            try stdout.print("\n", .{});
            return try allocator.dupe(u8, query);
        }
        if (ch == 127 or ch == 8) {
            if (query.len > 0) query = try allocator.realloc(query, query.len - 1);
        } else if (ch >= 32 and ch != 127) {
            query = try allocator.realloc(query, query.len + 1);
            query[query.len - 1] = ch;
        }
        try renderFilterPreview(allocator, stdout, options, query, &rendered_lines);
    }
}

fn renderFilterPreview(
    allocator: std.mem.Allocator,
    stdout: anytype,
    options: []const ModelOption,
    query: []const u8,
    rendered_lines: *usize,
) !void {
    if (rendered_lines.* > 1) {
        try stdout.print("\x1b[{d}A", .{rendered_lines.* - 1});
    }

    if (rendered_lines.* > 0) {
        var i: usize = 0;
        while (i < rendered_lines.*) : (i += 1) {
            try stdout.print("\r\x1b[2K", .{});
            if (i + 1 < rendered_lines.*) try stdout.print("\x1b[1B", .{});
        }
        if (rendered_lines.* > 1) {
            try stdout.print("\x1b[{d}A", .{rendered_lines.* - 1});
        }
    }

    const block = try buildFilterPreviewBlock(allocator, options, query);
    defer allocator.free(block);
    try stdout.print("{s}", .{block});

    rendered_lines.* = 1;
    for (block) |ch| {
        if (ch == '\n') rendered_lines.* += 1;
    }
}

fn buildFilterPreviewBlock(allocator: std.mem.Allocator, options: []const ModelOption, query: []const u8) ![]u8 {
    const filtered = try filterModelOptions(allocator, options, query);
    defer allocator.free(filtered);

    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("Filter models: {s} | matches: {d}", .{ query, filtered.len });
    const limit = @min(filtered.len, 6);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        try w.print("\n  {d}) {s}/{s} ({s})", .{ i + 1, filtered[i].provider_id, filtered[i].model_id, filtered[i].display_name });
    }
    if (filtered.len > limit) {
        try w.print("\n  ... and {d} more", .{filtered.len - limit});
    }
    return out.toOwnedSlice(allocator);
}

fn buildFilterPreviewLine(allocator: std.mem.Allocator, options: []const ModelOption, query: []const u8) ![]u8 {
    const filtered = try filterModelOptions(allocator, options, query);
    defer allocator.free(filtered);

    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("Filter models: {s} | matches: {d}", .{ query, filtered.len });
    if (filtered.len > 0) {
        try w.print(" | top: ", .{});
        const limit = @min(filtered.len, 3);
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            if (i > 0) try w.print(", ", .{});
            try w.print("{s}/{s}", .{ filtered[i].provider_id, filtered[i].model_id });
        }
    }
    return out.toOwnedSlice(allocator);
}

fn supportsSubscription(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "openai");
}

fn chooseAuthMethod(input: []const u8, allow_subscription: bool) AuthMethod {
    if (!allow_subscription) return .api;
    if (std.mem.eql(u8, input, "subscription") or std.mem.eql(u8, input, "sub") or std.mem.eql(u8, input, "oauth")) {
        return .subscription;
    }
    return .api;
}

fn formatProvidersOutput(
    allocator: std.mem.Allocator,
    providers: []const pm.ProviderSpec,
    connected: []const pm.ProviderState,
) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer out.deinit(allocator);

    const w = out.writer(allocator);
    try w.print("Available providers:\n", .{});
    for (providers) |provider| {
        const status = if (isConnected(provider.id, connected)) "connected" else "not connected";
        const methods = if (supportsSubscription(provider.id)) "api|subscription" else "api";
        try w.print("- {s} ({s}) [{s}] methods={s}\n", .{ provider.id, provider.display_name, status, methods });
    }
    try w.print("Use /connect or /connect <provider-id> to set up a provider.\n", .{});

    return out.toOwnedSlice(allocator);
}

fn connectSubscription(
    allocator: std.mem.Allocator,
    stdin: anytype,
    stdout: anytype,
    provider_id: []const u8,
) !?[]u8 {
    if (!std.mem.eql(u8, provider_id, "openai")) {
        try stdout.print("Subscription flow is currently supported only for openai.\n", .{});
        return null;
    }

    const start = try openaiDeviceStart(allocator);
    defer allocator.free(start.device_auth_id);
    defer allocator.free(start.user_code);

    try stdout.print("Open this URL in your browser: {s}/codex/device\n", .{OPENAI_ISSUER});
    try stdout.print("Enter code: {s}\n", .{start.user_code});
    const open_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", "xdg-open https://auth.openai.com/codex/device >/dev/null 2>&1 || true" },
    });
    allocator.free(open_result.stdout);
    allocator.free(open_result.stderr);

    const proceed = try promptLine(allocator, stdin, stdout, "Press Enter after authorization (or type cancel): ");
    if (proceed) |p| {
        defer allocator.free(p);
        const t = std.mem.trim(u8, p, " \t\r\n");
        if (std.mem.eql(u8, t, "cancel")) return null;
    }

    const token = try openaiPollAndExchange(allocator, stdout, start.device_auth_id, start.user_code, start.interval_sec);
    if (token == null) {
        try stdout.print("Subscription login failed.\n", .{});
        return null;
    }
    return token;
}

const OpenAIDeviceStart = struct {
    device_auth_id: []u8,
    user_code: []u8,
    interval_sec: u64,
};

fn openaiDeviceStart(allocator: std.mem.Allocator) !OpenAIDeviceStart {
    const body = try std.fmt.allocPrint(allocator, "{{\"client_id\":\"{s}\"}}", .{OPENAI_CLIENT_ID});
    defer allocator.free(body);

    const out = try runCommandCapture(allocator, &.{
        "curl",                                               "-sS", "-X",                             "POST",
        OPENAI_ISSUER ++ "/api/accounts/deviceauth/usercode", "-H",  "Content-Type: application/json", "-H",
        "User-Agent: zagent/0.1",                             "-d",  body,
    });
    defer allocator.free(out);

    const StartResp = struct {
        device_auth_id: []const u8,
        user_code: []const u8,
        interval: ?[]const u8 = null,
    };
    var parsed = try std.json.parseFromSlice(StartResp, allocator, out, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const interval = if (parsed.value.interval) |s| std.fmt.parseInt(u64, s, 10) catch 5 else 5;
    return .{
        .device_auth_id = try allocator.dupe(u8, parsed.value.device_auth_id),
        .user_code = try allocator.dupe(u8, parsed.value.user_code),
        .interval_sec = if (interval == 0) 5 else interval,
    };
}

fn openaiPollAndExchange(
    allocator: std.mem.Allocator,
    stdout: anytype,
    device_auth_id: []const u8,
    user_code: []const u8,
    interval_sec: u64,
) !?[]u8 {
    var tries: usize = 0;
    while (tries < 120) : (tries += 1) {
        const poll_body = try std.fmt.allocPrint(
            allocator,
            "{{\"device_auth_id\":\"{s}\",\"user_code\":\"{s}\"}}",
            .{ device_auth_id, user_code },
        );
        defer allocator.free(poll_body);

        const poll = try runCommandCapture(allocator, &.{
            "curl",                                            "-sS", "-X",                             "POST",
            OPENAI_ISSUER ++ "/api/accounts/deviceauth/token", "-H",  "Content-Type: application/json", "-H",
            "User-Agent: zagent/0.1",                          "-d",  poll_body,
        });
        defer allocator.free(poll);

        const PollResp = struct {
            authorization_code: ?[]const u8 = null,
            code_verifier: ?[]const u8 = null,
        };
        var parsed = std.json.parseFromSlice(PollResp, allocator, poll, .{ .ignore_unknown_fields = true }) catch {
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        };
        defer parsed.deinit();

        if (parsed.value.authorization_code == null or parsed.value.code_verifier == null) {
            std.Thread.sleep(interval_sec * std.time.ns_per_s);
            continue;
        }

        const form = try std.fmt.allocPrint(
            allocator,
            "grant_type=authorization_code&code={s}&redirect_uri={s}/deviceauth/callback&client_id={s}&code_verifier={s}",
            .{ parsed.value.authorization_code.?, OPENAI_ISSUER, OPENAI_CLIENT_ID, parsed.value.code_verifier.? },
        );
        defer allocator.free(form);

        const token = try runCommandCapture(allocator, &.{
            "curl",                          "-sS", "-X",                                              "POST",
            OPENAI_ISSUER ++ "/oauth/token", "-H",  "Content-Type: application/x-www-form-urlencoded", "-d",
            form,
        });
        defer allocator.free(token);

        const TokenResp = struct {
            access_token: ?[]const u8 = null,
            refresh_token: ?[]const u8 = null,
        };
        var tok = std.json.parseFromSlice(TokenResp, allocator, token, .{ .ignore_unknown_fields = true }) catch {
            return null;
        };
        defer tok.deinit();

        if (tok.value.access_token) |access| {
            try stdout.print("Subscription authorized successfully.\n", .{});
            return try allocator.dupe(u8, access);
        }
        return null;
    }

    return null;
}

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 512 * 1024,
    });
    defer allocator.free(result.stderr);
    return result.stdout;
}
