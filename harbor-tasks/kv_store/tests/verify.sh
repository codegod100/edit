#!/usr/bin/env bash
set -euo pipefail

output=$(zig run examples/kv_store/main.zig 2>&1)
if echo "$output" | grep -q "Status: inactive"; then
    echo "✅ Verification passed: Output matches expected."
else
    echo "❌ Verification failed: Output missing 'Status: inactive'"
    exit 1
fi

# Ideally we'd use valgrind or similar, but checking for manual deallocation in main.zig is a decent proxy
if ! grep -q "allocator.free(version)" examples/kv_store/main.zig; then
    echo "❌ Verification failed: Memory leak fix (free version) missing."
    exit 1
fi

exit 0
