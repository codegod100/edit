#!/usr/bin/env bash
set -euo pipefail

output=$(zig run examples/weather_service/main.zig 2>&1)
if echo "$output" | grep -q "59.9 degrees (fahrenheit)"; then
    echo "✅ Verification passed: Output matches expected."
    exit 0
else
    echo "❌ Verification failed: Output was: $output"
    exit 1
fi
