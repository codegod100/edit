const std = @import("std");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn multiply(a: i32, b: i32) i32 {
    return a * b;
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("10 + 5 = {d}\n", .{add(10, 5)});
    try stdout.print("10 * 5 = {d}\n", .{multiply(10, 5)});
}
