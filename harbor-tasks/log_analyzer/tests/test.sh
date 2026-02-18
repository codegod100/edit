#!/usr/bin/env bash
set -euo pipefail

REWARD_DIR="/logs/verifier"
if ! mkdir -p "$REWARD_DIR" 2>/dev/null; then
  REWARD_DIR=".harbor-logs/verifier"
  mkdir -p "$REWARD_DIR"
fi

bash /tests/setup.sh

if bash /tests/verify.sh; then
  echo "1.0" > "$REWARD_DIR/reward.txt"
  printf '{"reward":1.0}\n' > "$REWARD_DIR/reward.json"
  exit 0
fi

echo "0.0" > "$REWARD_DIR/reward.txt"
printf '{"reward":0.0}\n' > "$REWARD_DIR/reward.json"
exit 1
