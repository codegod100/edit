#!/usr/bin/env bash
set -euo pipefail

echo "--- Scaffolding/Resetting kv_store ---"
mkdir -p examples/kv_store
printf 'const std = @import("std");

// Legacy data file
version:1.2.0
user:nandi
status:active
' > examples/kv_store/db.txt
printf 'const std = @import("std");

// The Store Interface
pub const KVStore = struct {
    ptr: *anyopaque,
    getFn: *const fn (ptr: *anyopaque, key: []const u8) anyerror![]u8,
    setFn: *const fn (ptr: *anyopaque, key: []const u8, val: []const u8) anyerror!void,

    pub fn get(self: KVStore, key: []const u8) ![]u8 {
        return self.getFn(self.ptr, key);
    }
    pub fn set(self: KVStore, key: []const u8, val: []const u8) !void {
        return self.setFn(self.ptr, key, val);
    }
};
' > examples/kv_store/interface.zig
printf 'const std = @import("std");
const interface = @import("interface.zig");

// TASK: Implement FileStore here
// It should load examples/kv_store/db.txt and parse the key:value format.
' > examples/kv_store/file_store.zig
printf 'const std = @import("std");
const interface = @import("interface.zig");
const FileStore = @import("file_store.zig").FileStore;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var store_impl = try FileStore.init(allocator, "examples/kv_store/db.txt");
    defer store_impl.deinit();

    const store = store_impl.interface();

    const version = try store.get("version");
    std.debug.print("Version: {s}
", .{version});
    // BUG: missing allocator.free(version)

    try store.set("status", "inactive");
    
    const status = try store.get("status");
    std.debug.print("Status: {s}
", .{status});
    // BUG: missing allocator.free(status)
}
' > examples/kv_store/main.zig
