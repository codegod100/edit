const std = @import("std");
const types = @import("types.zig");
const json = @import("json.zig");
const errors = @import("errors.zig");

pub fn buildCodexResponsesBody(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    messages_json: []const u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, messages_json, .{ .ignore_unknown_fields = true }) catch {
        errors.setLastProviderError("invalid messages json");
        return errors.ProviderError.ModelResponseParseError;
    };
    defer parsed.deinit();
    if (parsed.value != .array) {
        errors.setLastProviderError("messages json must be an array");
        return errors.ProviderError.ModelResponseParseError;
    }

    var instructions: []const u8 = "";

    var input = std.ArrayList(u8).empty;
    defer input.deinit(allocator);
    const w_in = input.writer(allocator);

    try w_in.writeAll("[");
    var wrote_any = false;

    for (parsed.value.array.items) |msg_val| {
        if (msg_val != .object) continue;
        const obj = msg_val.object;

        // Any per-message allocations must live until we've serialized this message.
        var owned_content: ?[]u8 = null;
        defer if (owned_content) |b| allocator.free(b);

        const role_val = obj.get("role") orelse continue;
        if (role_val != .string) continue;
        const role = role_val.string;

        if (std.mem.eql(u8, role, "system")) {
            if (obj.get("content")) |c| {
                if (c == .string) instructions = c.string;
            }
            continue;
        }

        const content_val = obj.get("content") orelse continue;
        if (content_val != .string) continue;
        var content = content_val.string;
        if (content.len == 0) continue;

        var out_role: []const u8 = if (std.mem.eql(u8, role, "assistant")) "assistant" else "user";
        if (std.mem.eql(u8, role, "tool")) {
            out_role = "user";
            // Keep tool output visible to the model even though we don't encode tool_result items.
            owned_content = try std.fmt.allocPrint(allocator, "[tool]\n{s}", .{content});
            content = owned_content.?;
        }

        if (wrote_any) try w_in.writeAll(",");
        wrote_any = true;

        try w_in.writeAll("{\"type\":\"message\",\"role\":\"");
        try json.writeJsonStringEscaped(w_in, out_role);
        const content_type: []const u8 = if (std.mem.eql(u8, out_role, "assistant")) "output_text" else "input_text";
        try w_in.writeAll("\",\"content\":[{\"type\":\"");
        try w_in.writeAll(content_type);
        try w_in.writeAll("\",\"text\":\"");
        try json.writeJsonStringEscaped(w_in, content);
        try w_in.writeAll("\"}]}");
    }

    try w_in.writeAll("]");

    // Codex backend is strict about JSON Schema: additionalProperties must be present and false,
    // and required must include every key in properties.
    const tools_json =
        "[" ++
        "{\"type\":\"function\",\"name\":\"bash\",\"description\":\"Execute a shell command and return stdout.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"web_fetch\",\"description\":\"Fetch the text content of a URL.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"respond_text\",\"description\":\"Return final plain-text response when no more tools are needed.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read a file and return its contents.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"path\",\"offset\",\"limit\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"write_file\",\"description\":\"Write content to a file.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]},\"strict\":true}" ++
        ",{\"type\":\"function\",\"name\":\"replace_in_file\",\"description\":\"Replace text in a file.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"}},\"required\":[\"path\",\"find\",\"replace\"]},\"strict\":true}" ++
        "]";

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const w_out = out.writer(allocator);

    try w_out.writeAll("{\"model\":\"");
    try json.writeJsonStringEscaped(w_out, model_id);
    try w_out.writeAll("\",\"instructions\":\"");
    try json.writeJsonStringEscaped(w_out, instructions);
    try w_out.writeAll("\",\"input\":");
    try w_out.writeAll(input.items);

    try w_out.writeAll(",\"tools\":");
    try w_out.writeAll(tools_json);
    try w_out.writeAll(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":false,\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"]}");

    return out.toOwnedSlice(allocator);
}

pub fn buildChatBody(
    allocator: std.mem.Allocator,
    model_id: []const u8,
    messages_json: []const u8,
    reasoning_effort: ?[]const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.print("{{\"model\":{f},\"messages\":{s}", .{ std.json.fmt(model_id, .{}), messages_json });
    try w.writeAll(",\"tools\":[");
    // Keep schemas minimal and strict; some providers validate required/additionalProperties aggressively.
    try w.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"bash\",\"description\":\"Execute a shell command and return stdout.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"web_fetch\",\"description\":\"Fetch the text content of a URL.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"url\":{\"type\":\"string\"}},\"required\":[\"url\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"respond_text\",\"description\":\"Return final plain-text response when no more tools are needed.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read a file and return its contents.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"offset\":{\"type\":\"integer\"},\"limit\":{\"type\":\"integer\"}},\"required\":[\"path\",\"offset\",\"limit\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"description\":\"Write content to a file.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}},\"required\":[\"path\",\"content\"]},\"strict\":true}}");
    try w.writeAll(",{\"type\":\"function\",\"function\":{\"name\":\"replace_in_file\",\"description\":\"Replace text in a file.\",\"parameters\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"path\":{\"type\":\"string\"},\"find\":{\"type\":\"string\"},\"replace\":{\"type\":\"string\"}},\"required\":[\"path\",\"find\",\"replace\"]},\"strict\":true}}");
    try w.writeAll("]");
    if (reasoning_effort) |effort| {
        try w.print(",\"reasoning_effort\":{f}", .{std.json.fmt(effort, .{})});
    }
    try w.writeAll("}");

    return out.toOwnedSlice(allocator);
}
