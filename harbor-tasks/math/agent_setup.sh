#!/usr/bin/env bash
set -euo pipefail

echo "--- Scaffolding/Resetting legacy_math ---"
mkdir -p examples/legacy_math
printf 'const std = @import("std");

pub fn add(a: f64, b: f64) f64 { return a + b; }
pub fn subtract(a: f64, b: f64) f64 { return a - b; }
pub fn multiply_legacy(a: f64, b: f64) f64 { return a * b; }
pub fn divide(a: f64, b: f64) !f64 { if (b == 0) return error.DivisionByZero; return a / b; }
' > examples/legacy_math/core.zig
printf 'const std = @import("std");
const core = @import("core.zig");
pub fn power(base: f64, exp: f64) f64 { return std.math.pow(f64, base, exp); }
pub fn complex_heuristic(val: f64) f64 { return core.add(val, 10.0) * 2.0; }
pub fn calculate_hypotenuse(a: f64, b: f64) f64 { const a2 = core.multiply_legacy(a, a); const b2 = core.multiply_legacy(b, b); return std.math.sqrt(a2 + b2); }
' > examples/legacy_math/advanced.zig
printf 'const std = @import("std");
pub fn log_value(val: f64) void { std.debug.print("Value: {d}
", .{val}); }
pub fn format_currency(val: f64) void { std.debug.print("${d:.2}
", .{val}); }
' > examples/legacy_math/utils.zig
printf 'const std = @import("std");
const core = @import("core.zig");
const advanced = @import("advanced.zig");
const utils = @import("utils.zig");
pub fn main() !void {
    const x: f64 = 10.0; const y: f64 = 5.0;
    const sum = core.add(x, y); utils.log_value(sum);
    const diff = core.subtract(x, y); utils.log_value(diff);
    const z = core.add(sum, diff); utils.log_value(z);
}
' > examples/legacy_math/main.zig
