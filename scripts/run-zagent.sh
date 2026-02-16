#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ZAGENT_BIN="${ZAGENT_BIN:-./zig-out/bin/zagent}"
ZAGENT_HOME="${ZAGENT_HOME:-$HOME}"

if [[ ! -x "$ZAGENT_BIN" ]]; then
  zig build
fi

SCENARIO_PROMPT="Implement a new multiplication feature in examples/calculator/main.zig: add pub fn multiply(a: i32, b: i32) i32 returning a*b; update main to call multiply(10, 5) and print '10 * 5 = 50'; keep it idempotent (no duplicate function/print); verify with 'zig run examples/calculator/main.zig'; then say DONE."

if [[ $# -gt 0 ]]; then
  PROMPT="$*"
  env HOME="$ZAGENT_HOME" "$ZAGENT_BIN" <<EOF
$PROMPT
/quit
EOF
else
  env HOME="$ZAGENT_HOME" "$ZAGENT_BIN" <<EOF
$SCENARIO_PROMPT
/quit
EOF
fi
