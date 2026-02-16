#!/usr/bin/env bash
set -euo pipefail

echo "--- Scaffolding/Resetting weather_service ---"
mkdir -p examples/weather_service
printf 'pub const Unit = enum { celsius, fahrenheit };
pub const Forecast = struct {
    temp: f32,
    desc: []const u8,
    unit: Unit,
};
' > examples/weather_service/models.zig
printf 'const std = @import("std");
const models = @import("models.zig");

pub fn fetchTemperature(city: []const u8) !f32 {
    if (std.mem.eql(u8, city, "San Francisco")) return 15.5;
    if (std.mem.eql(u8, city, "Beijing")) return 5.0;
    return 20.0;
}
' > examples/weather_service/provider.zig
printf 'const std = @import("std");
const provider = @import("provider.zig");
const models = @import("models.zig");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const city = "San Francisco";
    const temp = try provider.fetchTemperature(city);
    try stdout.print("Weather in {s}: {d:.1} degrees
", .{ city, temp });
}
' > examples/weather_service/main.zig
