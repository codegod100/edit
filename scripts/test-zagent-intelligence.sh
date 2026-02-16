#!/usr/bin/env bash
set -euo pipefail

# This function restores the 'broken' state of the weather service.
scaffold_test() {
  echo "--- Scaffolding/Resetting weather_service challenge ---"
  mkdir -p examples/weather_service
  printf 'pub const Unit = enum { celsius, fahrenheit };\npub const Forecast = struct {\n    temp: f32,\n    desc: []const u8,\n    unit: Unit,\n};\n' > examples/weather_service/models.zig
  printf 'const std = @import("std");\nconst models = @import("models.zig");\n\npub fn fetchTemperature(city: []const u8) !f32 {\n    if (std.mem.eql(u8, city, "San Francisco")) return 15.5;\n    if (std.mem.eql(u8, city, "Beijing")) return 5.0;\n    return 20.0;\n}\n' > examples/weather_service/provider.zig
  printf 'const std = @import("std");\nconst provider = @import("provider.zig");\nconst models = @import("models.zig");\n\npub fn main() !void {\n    const stdout = std.io.getStdOut().writer();\n    const city = "San Francisco";\n    const temp = try provider.fetchTemperature(city);\n    try stdout.print("Weather in {s}: {d:.1} degrees\\n", .{ city, temp });\n}\n' > examples/weather_service/main.zig
}

CHALLENGE="Refactor the weather service in examples/weather_service/ to support temperature units properly:
1. In models.zig, add a function 'pub fn convert(temp: f32, from: Unit, to: Unit) f32' to handle the math (C to F is (c * 9/5) + 32).
2. In provider.zig, update fetchTemperature to take a 'models.Unit' argument. It still returns Celsius from the hardcoded values, but MUST use models.convert to return the requested unit.
3. Update main.zig to use the new provider signature. It should fetch 'San Francisco' in Fahrenheit and print 'Weather in San Francisco: 59.9 degrees (fahrenheit)'.
4. Ensure the project builds and runs with 'zig run examples/weather_service/main.zig'.
5. Reply DONE when verified."

# 1. Start fresh
scaffold_test

# 2. Run the agent
./scripts/run-zagent.sh "$CHALLENGE"

# 3. Reset afterwards as requested
scaffold_test
echo "Test reset complete."
