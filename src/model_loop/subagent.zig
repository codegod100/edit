const std = @import("std");
const active_module = @import("../context.zig");
const subagent = @import("../subagent.zig");
const todo = @import("../todo.zig");
const types = @import("types.zig");

fn buildSubagentSystemPrompt(allocator: std.mem.Allocator, task_type: subagent.SubagentType) ![]u8 {
    const base = subagent.SubagentManager.getSystemPrompt(task_type);
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\nUse the function-call tool interface for any tool usage. Prefer bash+rg before reading files unless the user gave an explicit path. Read using explicit offset+limit. Avoid repeating identical tool calls. Finish by calling respond_text.",
        .{base},
    );
}

pub fn subagentThreadMain(args_ptr: *types.SubagentThreadArgs) void {
    const allocator = std.heap.page_allocator;
    defer {
        args_ptr.deinit(allocator);
        allocator.destroy(args_ptr);
    }
    const args = args_ptr.*;

    _ = args.manager.updateStatus(args.id, .running);

    var todo_list = todo.TodoList.init(allocator);
    defer todo_list.deinit();
    if (todo_list.add(args.description)) |new_id| {
        _ = todo_list.update(new_id, .in_progress) catch {};
    } else |_| {}

    const sys_prompt = buildSubagentSystemPrompt(allocator, args.task_type) catch null;
    defer if (sys_prompt) |s| allocator.free(s);

    const input = blk: {
        if (args.parent_context) |ctx| {
            break :blk std.fmt.allocPrint(
                allocator,
                "Subagent task:\n{s}\n\nParent context:\n{s}",
                .{ args.description, ctx },
            ) catch null;
        }
        break :blk allocator.dupe(u8, args.description) catch null;
    };
    defer if (input) |s| allocator.free(s);

    const NullOut = struct {
        pub fn writeAll(_: *@This(), _: []const u8) !void {}
        pub fn print(_: *@This(), comptime _: []const u8, _: anytype) !void {}
    };
    var out = NullOut{};

    if (input == null) {
        _ = args.manager.setError(args.id, "subagent: failed to allocate input") catch {};
        _ = args.manager.updateStatus(args.id, .failed);
        return;
    }

    // Import legacy to call runModel
    var result = @import("legacy.zig").runModel(
        allocator,
        &out,
        args.active,
        args.description,
        input.?,
        false,
        &todo_list,
        null,
        sys_prompt,
    ) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "subagent: run failed: {s}", .{@errorName(err)}) catch null;
        if (msg) |m| {
            defer allocator.free(m);
            _ = args.manager.setError(args.id, m) catch {};
        } else {
            _ = args.manager.setError(args.id, "subagent: run failed") catch {};
        }
        _ = args.manager.updateStatus(args.id, .failed);
        return;
    };
    defer result.deinit(allocator);

    if (result.error_count == 0) {
        _ = args.manager.setResult(args.id, result.response, result.tool_calls) catch {};
        _ = args.manager.updateStatus(args.id, .completed);
    } else {
        _ = args.manager.setError(args.id, result.response) catch {};
        _ = args.manager.updateStatus(args.id, .failed);
    }
}
