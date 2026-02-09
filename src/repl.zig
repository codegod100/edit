const std = @import("std");
const skills = @import("skills.zig");
const tools = @import("tools.zig");
const pm = @import("provider_manager.zig");
const store = @import("provider_store.zig");

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
    if (std.mem.eql(u8, trimmed, "/connect")) {
        return .{ .tag = .connect_provider, .arg = "" };
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

fn applyEditKey(
    allocator: std.mem.Allocator,
    current: []const u8,
    key: EditKey,
    character: u8,
) ![]u8 {
    _ = key;
    _ = character;
    return allocator.dupe(u8, current);
}

pub fn run(allocator: std.mem.Allocator) !void {
    const stdin = std.fs.File.stdin().deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const home = std.posix.getenv("HOME") orelse "";
    const skill_list = try skills.discover(allocator, cwd, home);
    defer skills.freeList(allocator, skill_list);

    const providers = defaultProviderSpecs();
    var stored_pairs = try store.load(allocator, cwd);
    defer store.free(allocator, stored_pairs);

    var provider_states = try resolveProviderStates(allocator, providers, stored_pairs);
    defer pm.ProviderManager.freeResolved(allocator, provider_states);

    try stdout.print(
        "zagent MVP. Commands: /skills, /skill <name>, /tools, /tool <spec>, /providers, /default-model <provider>, /connect, /quit\n",
        .{},
    );
    while (true) {
        try stdout.print("> ", .{});
        const line_opt = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 64 * 1024);
        if (line_opt == null) {
            try stdout.print("\n", .{});
            break;
        }

        const line = line_opt.?;
        defer allocator.free(line);

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
                if (provider_states.len == 0) {
                    try stdout.print("No connected providers found from env vars.\n", .{});
                    continue;
                }
                for (provider_states) |p| {
                    try stdout.print("- {s} ({s}) models={d}\n", .{ p.id, p.display_name, p.models.len });
                }
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
                const chosen = try chooseProvider(allocator, stdin, stdout, providers, provider_states);
                if (chosen == null) continue;

                const provider = chosen.?;
                if (provider.env_vars.len == 0) {
                    try stdout.print("Provider {s} has no API key env mapping.\n", .{provider.id});
                    continue;
                }

                const env_name = provider.env_vars[0];
                const key_opt = try promptLine(allocator, stdin, stdout, "API key: ");
                if (key_opt == null) continue;
                defer allocator.free(key_opt.?);
                const key = std.mem.trim(u8, key_opt.?, " \t\r\n");
                if (key.len == 0) {
                    try stdout.print("Cancelled: empty key.\n", .{});
                    continue;
                }

                try store.upsertFile(allocator, cwd, env_name, key);
                try stdout.print("Stored {s} in .zagent/providers.env\n", .{env_name});

                store.free(allocator, stored_pairs);
                stored_pairs = try store.load(allocator, cwd);

                pm.ProviderManager.freeResolved(allocator, provider_states);
                provider_states = try resolveProviderStates(allocator, providers, stored_pairs);
            },
            .none => {
                const trimmed = std.mem.trim(u8, normalized, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (trimmed[0] == '/') {
                    try stdout.print("Unknown command: {s}\n", .{trimmed});
                    continue;
                }
                try stdout.print("MVP: LLM loop not wired yet. Use /skills and /skill.\n", .{});
            },
        }
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
