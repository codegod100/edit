#!/usr/bin/env bash
set -euo pipefail

# 1. Check if it runs
output=$(zig run examples/legacy_math/main.zig 2>&1)
if ! echo "$output" | grep -q "Value: 15"; then
    echo "❌ Verification failed: Output missing 'Value: 15'"
    exit 1
fi

# 2. Check for dead code elimination
if grep -q "calculate_hypotenuse" examples/legacy_math/advanced.zig; then
    echo "❌ Verification failed: Dead function 'calculate_hypotenuse' still exists."
    exit 1
fi

if grep -q "multiply_legacy" examples/legacy_math/core.zig; then
    echo "❌ Verification failed: Dead function 'multiply_legacy' still exists."
    exit 1
fi

echo "✅ Verification passed."
exit 0
