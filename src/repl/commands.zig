const std = @import("std");

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
    set_provider,
    set_model,
    list_models,
    set_effort,
    stats,
    ping,
    todo,
    clear, // Added clear command
};

pub fn parseCommand(input: []const u8) CommandTag {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "/")) return .none;

    const cmd_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    const cmd = trimmed[0..cmd_end];

    if (std.mem.eql(u8, cmd, "/quit") or std.mem.eql(u8, cmd, "/exit")) return .quit;
    if (std.mem.eql(u8, cmd, "/skills")) return .list_skills;
    if (std.mem.eql(u8, cmd, "/skill")) return .load_skill;
    if (std.mem.eql(u8, cmd, "/tools")) return .list_tools;
    if (std.mem.eql(u8, cmd, "/tool")) return .run_tool;
    if (std.mem.eql(u8, cmd, "/providers")) return .list_providers;
    if (std.mem.eql(u8, cmd, "/default-model")) return .default_model;
    if (std.mem.eql(u8, cmd, "/connect")) return .connect_provider;
    if (std.mem.eql(u8, cmd, "/provider")) return .set_provider;
    if (std.mem.eql(u8, cmd, "/model")) return .set_model;
    if (std.mem.eql(u8, cmd, "/models")) return .list_models;
    if (std.mem.eql(u8, cmd, "/effort")) return .set_effort;
    if (std.mem.eql(u8, cmd, "/stats")) return .stats;
    if (std.mem.eql(u8, cmd, "/ping")) return .ping;
    if (std.mem.eql(u8, cmd, "/todo")) return .todo;
    if (std.mem.eql(u8, cmd, "/clear")) return .clear;

    return .none;
}
