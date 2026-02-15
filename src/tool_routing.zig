const std = @import("std");
const tools = @import("tools.zig");
const llm = @import("llm.zig");
const utils = @import("utils.zig");
const context = @import("context.zig"); // For ActiveModel

pub fn inferToolCallWithModel(allocator: std.mem.Allocator, stdout: anytype, active: context.ActiveModel, input: []const u8, force: bool) !?llm.ToolRouteCall {
    _ = stdout;
    var defs = try std.ArrayList(llm.ToolRouteDef).initCapacity(allocator, tools.definitions.len);
    defer defs.deinit(allocator);

    for (tools.definitions) |d| {
        try defs.append(allocator, .{ .name = d.name, .description = d.description, .parameters_json = d.parameters_json });
    }

    const result = try llm.inferToolCallWithThinking(allocator, active.provider_id, active.api_key, active.model_id, input, defs.items, force);
    if (result) |r| {
        if (r.thinking) |thinking| allocator.free(thinking);
        return r.call;
    }
    return null;
}

pub fn buildFallbackToolInferencePrompt(allocator: std.mem.Allocator, user_text: []const u8, require_mutation: bool) ![]u8 {
    var tools_list = std.ArrayList(u8).init(allocator);
    defer tools_list.deinit(allocator);
    for (tools.definitions) |d| {
        try tools_list.writer(allocator).print("- {s}: {s}\n", .{ d.name, d.parameters_json });
    }

    return std.fmt.allocPrint(
        allocator,
        "Return exactly one line in this format and nothing else: TOOL_CALL <tool_name> <arguments_json>. Choose one tool from the list below. Arguments must be valid JSON object. Prefer bash+rg first to locate targets, then read_file/read with offset+limit (bisection-style chunks) only on candidate files. {s}\n\nTools:\n{s}\nUser request:\n{s}",
        .{ if (require_mutation) "This request requires file mutation; prefer write_file, replace_in_file/edit, or apply_patch." else "", tools_list.items, user_text },
    );
}

pub fn hasPseudoToolCallText(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "Tool:") or std.mem.startsWith(u8, trimmed, "tool:")) return true;
    }
    return false;
}

pub fn parseFallbackToolCallFromText(allocator: std.mem.Allocator, text: []const u8) !?llm.ToolRouteCall {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "Tool:") or std.mem.startsWith(u8, trimmed, "tool:")) return null;
    if (!std.mem.startsWith(u8, trimmed, "TOOL_CALL ")) return null;

    const rest = std.mem.trim(u8, trimmed[10..], " \t");
    const brace = std.mem.indexOfScalar(u8, rest, '{') orelse return null;
    const name = std.mem.trim(u8, rest[0..brace], " \t");
    const args = std.mem.trim(u8, rest[brace..], " \t");
    if (name.len == 0 or args.len < 2) return null;

    return .{
        .tool = try allocator.dupe(u8, name),
        .arguments_json = try allocator.dupe(u8, args),
    };
}

pub fn inferToolCallWithTextFallback(allocator: std.mem.Allocator, active: context.ActiveModel, input: []const u8, require_mutation: bool) !?llm.ToolRouteCall {
    const prompt = try buildFallbackToolInferencePrompt(allocator, input, require_mutation);
    defer allocator.free(prompt);

    const raw = llm.query(allocator, active.provider_id, active.api_key, active.model_id, prompt, utils.toolDefsToLlm(tools.definitions[0..])) catch return null;
    defer allocator.free(raw);
    return parseFallbackToolCallFromText(allocator, raw);
}

pub fn buildToolRoutingPrompt(allocator: std.mem.Allocator, user_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Use local tools when they improve correctness. For repository-specific questions, start with bash+rg to find files and symbols, then inspect only candidate files with read_file/read using offset+limit. For long files, bisect with multiple bounded reads instead of broad scans. For code changes, use read_file, write_file, or replace_in_file/edit directly. Only skip tools when the answer is purely general knowledge.\n\nUser request:\n{s}",
        .{user_text},
    );
}

pub fn buildStrictToolRoutingPrompt(allocator: std.mem.Allocator, user_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "This is a repository-specific question. You must call at least one local tool before giving the final answer. First call bash with rg to locate relevant files/symbols, then read_file/read only targeted files with explicit offset+limit; use bisection-style chunking for large files. If the user asked to change code, use write_file/replace_in_file/edit/apply_patch and do not claim success without running them. Then answer using concrete file evidence or action results.\n\nUser request:\n{s}",
        .{user_text},
    );
}

pub fn isLikelyRepoSpecificQuestion(input: []const u8) bool {
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return false;

    if (std.mem.indexOf(u8, t, "/") != null) return true;
    if (utils.containsIgnoreCase(t, "repo") or utils.containsIgnoreCase(t, "codebase")) return true;
    if (utils.containsIgnoreCase(t, "src/")) return true;
    if (utils.containsIgnoreCase(t, ".zig")) return true;
    if (utils.containsIgnoreCase(t, "function") or utils.containsIgnoreCase(t, "file") or utils.containsIgnoreCase(t, "harness")) return true;
    if (utils.containsIgnoreCase(t, "how does") or utils.containsIgnoreCase(t, "where is") or utils.containsIgnoreCase(t, "explain")) return true;

    return false;
}

pub fn isLikelyFileMutationRequest(input: []const u8) bool {
    const t = std.mem.trim(u8, input, " \t\r\n");
    if (t.len == 0) return false;

    const mentions_target = utils.containsIgnoreCase(t, "file") or utils.containsIgnoreCase(t, "src/") or utils.containsIgnoreCase(t, ".zig");
    if (!mentions_target) return false;

    return utils.containsIgnoreCase(t, "create") or
        utils.containsIgnoreCase(t, "edit") or
        utils.containsIgnoreCase(t, "write") or
        utils.containsIgnoreCase(t, "modify") or
        utils.containsIgnoreCase(t, "update") or
        utils.containsIgnoreCase(t, "replace") or
        utils.containsIgnoreCase(t, "refactor") or
        utils.containsIgnoreCase(t, "add line");
}

pub fn buildStrictMutationToolRoutingPrompt(allocator: std.mem.Allocator, user_text: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "This request requires actual file mutation. You must call at least one write-capable tool before giving a final answer. Use write_file, replace_in_file/edit, or apply_patch. Do not claim success unless a tool has run successfully.\n\nUser request:\n{s}",
        .{user_text},
    );
}

pub fn isLikelyMultiStepMutationRequest(input: []const u8) bool {
    return isLikelyFileMutationRequest(input) and (utils.containsIgnoreCase(input, " then ") or utils.containsIgnoreCase(input, " and "));
}

fn trimTargetToken(token: []const u8) []const u8 {
    return std.mem.trim(u8, token, " \t\r\n`\"'.,:;!?()[]{}<>");
}

fn isMutationVerb(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "create") or
        std.ascii.eqlIgnoreCase(token, "edit") or
        std.ascii.eqlIgnoreCase(token, "write") or
        std.ascii.eqlIgnoreCase(token, "modify") or
        std.ascii.eqlIgnoreCase(token, "update") or
        std.ascii.eqlIgnoreCase(token, "replace") or
        std.ascii.eqlIgnoreCase(token, "add") or
        std.ascii.eqlIgnoreCase(token, "refactor");
}

fn isIgnoredTargetWord(token: []const u8) bool {
    return std.ascii.eqlIgnoreCase(token, "file") or
        std.ascii.eqlIgnoreCase(token, "folder") or
        std.ascii.eqlIgnoreCase(token, "directory") or
        std.ascii.eqlIgnoreCase(token, "named") or
        std.ascii.eqlIgnoreCase(token, "name") or
        std.ascii.eqlIgnoreCase(token, "this") or
        std.ascii.eqlIgnoreCase(token, "that") or
        std.ascii.eqlIgnoreCase(token, "it") or
        std.ascii.eqlIgnoreCase(token, "the") or
        std.ascii.eqlIgnoreCase(token, "a") or
        std.ascii.eqlIgnoreCase(token, "an") or
        std.ascii.eqlIgnoreCase(token, "to") or
        std.ascii.eqlIgnoreCase(token, "then") or
        std.ascii.eqlIgnoreCase(token, "and") or
        std.ascii.eqlIgnoreCase(token, "with");
}

fn looksLikePathTarget(token: []const u8) bool {
    return std.mem.indexOfScalar(u8, token, '/') != null or std.mem.indexOfScalar(u8, token, '.') != null;
}

pub fn targetSatisfied(touched_paths: []const []const u8, target: []const u8) bool {
    for (touched_paths) |p| {
        if (utils.containsIgnoreCase(p, target)) return true;
        const base = std.fs.path.basename(p);
        if (std.ascii.eqlIgnoreCase(base, target)) return true;

        if (std.mem.indexOfScalar(u8, target, '.') == null and std.mem.indexOfScalar(u8, target, '/') == null) {
            if (base.len == target.len + 1 and base[0] == '.') {
                if (std.ascii.eqlIgnoreCase(base[1..], target)) return true;
            }
        }
    }
    return false;
}

pub fn collectRequiredTargets(allocator: std.mem.Allocator, user_input: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(allocator);
    defer out.deinit(allocator);

    var words = std.mem.tokenizeAny(u8, user_input, " \t\r\n");
    var prev_was_verb = false;
    while (words.next()) |raw| {
        const token = trimTargetToken(raw);
        if (token.len == 0) continue;

        if (isMutationVerb(token)) {
            prev_was_verb = true;
            continue;
        }

        if (isIgnoredTargetWord(token)) {
            if (!std.ascii.eqlIgnoreCase(token, "named") and !std.ascii.eqlIgnoreCase(token, "name")) {
                prev_was_verb = false;
            }
            continue;
        }

        if (looksLikePathTarget(token) or prev_was_verb) {
            var exists = false;
            for (out.items) |existing| {
                if (std.ascii.eqlIgnoreCase(existing, token)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) try out.append(allocator, token);
        }
        prev_was_verb = false;
    }

    return out.toOwnedSlice(allocator);
}

pub fn hasUnmetRequiredEdits(user_input: []const u8, touched_paths: []const []const u8) bool {
    const required = collectRequiredTargets(std.heap.page_allocator, user_input) catch return false;
    defer std.heap.page_allocator.free(required);

    for (required) |target| {
        if (!targetSatisfied(touched_paths, target)) return true;
    }
    return false;
}
