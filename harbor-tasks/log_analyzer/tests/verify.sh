#!/usr/bin/env bash
set -euo pipefail

LOGFILE="examples/log_analyzer/server.log"
SCRIPT="examples/log_analyzer/analyzer.py"

# 1. Verify Bug Fix (Regex)
# We expect: 
# INFO: ~102 (starts + 100 loop + retry + established)
# WARN: 1
# ERROR: 1
output=$(python3 "$SCRIPT" "$LOGFILE")

if echo "$output" | grep -q "WARN: 1" && echo "$output" | grep -q "ERROR: 1"; then
    echo "✅ Regex Fix Passed: Detected WARN and ERROR logs."
else
    echo "❌ Regex Fix Failed: Did not detect WARN/ERROR. Output:"
    echo "$output"
    exit 1
fi

# 2. Verify Optimization
if grep -q "readlines()" "$SCRIPT"; then
    echo "❌ Optimization Failed: Script still uses readlines()."
    exit 1
else
    echo "✅ Optimization Passed: readlines() removed."
fi

# 3. Verify JSON Output
json_output=$(python3 "$SCRIPT" "$LOGFILE" --json)
if echo "$json_output" | grep -q '"WARN": 1' && echo "$json_output" | grep -q '"ERROR": 1'; then
    echo "✅ Feature Passed: JSON output works."
else
    echo "❌ Feature Failed: JSON output incorrect. Output:"
    echo "$json_output"
    exit 1
fi

exit 0
