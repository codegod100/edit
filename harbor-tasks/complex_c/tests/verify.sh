#!/usr/bin/env bash
set -euo pipefail

if [ -f "examples/complex_c/a.out" ] || [ -f "a.out" ] || [ -f "examples/complex_c/broken" ]; then
    echo "✅ Verification passed: Executable created."
    if [ -f "examples/complex_c/a.out" ]; then
        ./examples/complex_c/a.out
    elif [ -f "examples/complex_c/broken" ]; then
        ./examples/complex_c/broken
    else
        ./a.out
    fi
    exit 0
else
    echo "❌ Verification failed: No executable found."
    exit 1
fi
