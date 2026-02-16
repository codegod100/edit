#!/usr/bin/env bash
set -euo pipefail

scaffold_weather() {
  echo "--- Scaffolding/Resetting weather_service ---"
  mkdir -p examples/weather_service
  printf 'pub const Unit = enum { celsius, fahrenheit };\npub const Forecast = struct {\n    temp: f32,\n    desc: []const u8,\n    unit: Unit,\n};\n' > examples/weather_service/models.zig
  printf 'const std = @import("std");\nconst models = @import("models.zig");\n\npub fn fetchTemperature(city: []const u8) !f32 {\n    if (std.mem.eql(u8, city, "San Francisco")) return 15.5;\n    if (std.mem.eql(u8, city, "Beijing")) return 5.0;\n    return 20.0;\n}\n' > examples/weather_service/provider.zig
  printf 'const std = @import("std");\nconst provider = @import("provider.zig");\nconst models = @import("models.zig");\n\npub fn main() !void {\n    const stdout = std.io.getStdOut().writer();\n    const city = "San Francisco";\n    const temp = try provider.fetchTemperature(city);\n    try stdout.print("Weather in {s}: {d:.1} degrees\\n", .{ city, temp });\n}\n' > examples/weather_service/main.zig
}

scaffold_math() {
  echo "--- Scaffolding/Resetting legacy_math ---"
  mkdir -p examples/legacy_math
  printf 'const std = @import("std");\n\npub fn add(a: f64, b: f64) f64 { return a + b; }\npub fn subtract(a: f64, b: f64) f64 { return a - b; }\npub fn multiply_legacy(a: f64, b: f64) f64 { return a * b; }\npub fn divide(a: f64, b: f64) !f64 { if (b == 0) return error.DivisionByZero; return a / b; }\n' > examples/legacy_math/core.zig
  printf 'const std = @import("std");\nconst core = @import("core.zig");\npub fn power(base: f64, exp: f64) f64 { return std.math.pow(f64, base, exp); }\npub fn complex_heuristic(val: f64) f64 { return core.add(val, 10.0) * 2.0; }\npub fn calculate_hypotenuse(a: f64, b: f64) f64 { const a2 = core.multiply_legacy(a, a); const b2 = core.multiply_legacy(b, b); return std.math.sqrt(a2 + b2); }\n' > examples/legacy_math/advanced.zig
  printf 'const std = @import("std");\npub fn log_value(val: f64) void { std.debug.print("Value: {d}\\n", .{val}); }\npub fn format_currency(val: f64) void { std.debug.print("${d:.2}\\n", .{val}); }\n' > examples/legacy_math/utils.zig
  printf 'const std = @import("std");\nconst core = @import("core.zig");\nconst advanced = @import("advanced.zig");\nconst utils = @import("utils.zig");\npub fn main() !void {\n    const x: f64 = 10.0; const y: f64 = 5.0;\n    const sum = core.add(x, y); utils.log_value(sum);\n    const diff = core.subtract(x, y); utils.log_value(diff);\n    const z = core.add(sum, diff); utils.log_value(z);\n}\n' > examples/legacy_math/main.zig
}

scaffold_kv() {
  echo "--- Scaffolding/Resetting kv_store ---"
  mkdir -p examples/kv_store
  printf 'const std = @import("std");\n\n// Legacy data file\nversion:1.2.0\nuser:nandi\nstatus:active\n' > examples/kv_store/db.txt
  printf 'const std = @import("std");\n\n// The Store Interface\npub const KVStore = struct {\n    ptr: *anyopaque,\n    getFn: *const fn (ptr: *anyopaque, key: []const u8) anyerror![]u8,\n    setFn: *const fn (ptr: *anyopaque, key: []const u8, val: []const u8) anyerror!void,\n\n    pub fn get(self: KVStore, key: []const u8) ![]u8 {\n        return self.getFn(self.ptr, key);\n    }\n    pub fn set(self: KVStore, key: []const u8, val: []const u8) !void {\n        return self.setFn(self.ptr, key, val);\n    }\n};\n' > examples/kv_store/interface.zig
  printf 'const std = @import("std");\nconst interface = @import("interface.zig");\n\n// TASK: Implement FileStore here\n// It should load examples/kv_store/db.txt and parse the key:value format.\n' > examples/kv_store/file_store.zig
  printf 'const std = @import("std");\nconst interface = @import("interface.zig");\nconst FileStore = @import("file_store.zig").FileStore;\n\npub fn main() !void {\n    var gpa = std.heap.GeneralPurposeAllocator(.{}){};\n    const allocator = gpa.allocator();\n    defer _ = gpa.deinit();\n\n    var store_impl = try FileStore.init(allocator, "examples/kv_store/db.txt");\n    defer store_impl.deinit();\n\n    const store = store_impl.interface();\n\n    const version = try store.get("version");\n    std.debug.print("Version: {s}\\n", .{version});\n    // BUG: missing allocator.free(version)\n\n    try store.set("status", "inactive");\n    \n    const status = try store.get("status");\n    std.debug.print("Status: {s}\\n", .{status});\n    // BUG: missing allocator.free(status)\n}\n' > examples/kv_store/main.zig
}

CHALLENGE_WEATHER="Refactor the weather service in examples/weather_service/ to support temperature units properly:
1. In models.zig, add a function 'pub fn convert(temp: f32, from: Unit, to: Unit) f32' to handle the math (C to F is (c * 9/5) + 32).
2. In provider.zig, update fetchTemperature to take a 'models.Unit' argument. It still returns Celsius from the hardcoded values, but MUST use models.convert to return the requested unit.
3. Update main.zig to use the new provider signature. It should fetch 'San Francisco' in Fahrenheit and print 'Weather in San Francisco: 59.9 degrees (fahrenheit)'.
4. Ensure the project builds and runs with 'zig run examples/weather_service/main.zig'.
5. Reply DONE when verified."

CHALLENGE_MATH="Perform a Legacy Migration & Dead Code Elimination on examples/legacy_math/:
1. In core.zig, define 'pub const Number = struct { value: f64 };'.
2. Refactor 'core.add', 'core.subtract', and 'utils.log_value' to accept and return 'Number' instead of 'f64'.
3. ANALYZE dependencies starting from main.zig. Identify functions that are NOT reachable from main.zig (even if they call each other).
   - Hint: 'calculate_hypotenuse' calls 'multiply_legacy', but is 'calculate_hypotenuse' called by main?
4. DELETE all unreachable functions from core.zig, advanced.zig, and utils.zig.
5. Update main.zig to use the new Number struct (e.g. 'Number{ .value = 10.0 }').
6. Ensure 'zig run examples/legacy_math/main.zig' works.
7. Reply DONE."

CHALLENGE_KV="Align and Extend the KV Store in examples/kv_store/:
1. Implement 'FileStore' in file_store.zig. It must parse the 'key:value' format in db.txt.
2. Extend the 'KVStore' interface in interface.zig to include a 'delete' method.
3. Implement 'delete' in FileStore.
4. MEMORY AUDIT: Identify and fix any memory leaks in main.zig (Hint: check return values of 'get').
5. Update main.zig to delete the 'user' key after printing status.
6. Verify with 'zig run examples/kv_store/main.zig'.
7. Reply DONE."

case "${1:-all}" in
  weather) scaffold_weather; ./scripts/run-zagent.sh "$CHALLENGE_WEATHER"; scaffold_weather ;;
  math) scaffold_math; ./scripts/run-zagent.sh "$CHALLENGE_MATH"; scaffold_math ;;
  kv) scaffold_kv; ./scripts/run-zagent.sh "$CHALLENGE_KV"; scaffold_kv ;;
  all) echo "Usage: $0 [weather|math|kv]"; exit 1 ;;
esac
