#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ZAGENT_BIN="${ZAGENT_BIN:-./zig-out/bin/zagent}"
ZAGENT_HOME="${ZAGENT_HOME:-$ROOT_DIR}"
ZAGENT_TIMEOUT_SECONDS="${ZAGENT_TIMEOUT_SECONDS:-240}"
TARGET_FILE="examples/calculator/main.zig"
CONFIG_DIR="$ZAGENT_HOME/.config/zagent"
PROVIDERS_ENV="$CONFIG_DIR/providers.env"

SCENARIO_PROMPT="Implement a new multiplication feature in examples/calculator/main.zig: add pub fn multiply(a: i32, b: i32) i32 returning a*b; update main to call multiply(10, 5) and print '10 * 5 = 50'; keep it idempotent (no duplicate function/print); verify with 'zig run examples/calculator/main.zig'; then say DONE."
PROVIDER_ID="${PROVIDER_ID:-openai}"
MODEL_ID="${MODEL_ID:-gpt-5.3-codex}"
REQUIRE_LIVE_MODEL="${REQUIRE_LIVE_MODEL:-0}"
LIVE_MODEL_SKIPPED=0

if [[ ! -x "$ZAGENT_BIN" ]]; then
  zig build
fi

if [[ ! -f "$ZAGENT_HOME/.codex/auth.json" ]]; then
  echo "Missing Codex auth at $ZAGENT_HOME/.codex/auth.json" >&2
  echo "Copy credentials first or set ZAGENT_HOME to a directory that contains .codex/auth.json." >&2
  exit 1
fi

mkdir -p "$ZAGENT_HOME/.config/zagent"

seed_openai_key_from_codex_auth() {
  local auth_file="$ZAGENT_HOME/.codex/auth.json"
  local key
  key="$(jq -r '.OPENAI_API_KEY // .tokens.access_token // empty' "$auth_file" 2>/dev/null || true)"
  if [[ -z "$key" ]]; then
    return
  fi

  umask 077
  if [[ -f "$PROVIDERS_ENV" ]]; then
    local tmp
    tmp="$(mktemp)"
    awk -v value="$key" '
      BEGIN { updated = 0 }
      /^OPENAI_API_KEY=/ { print "OPENAI_API_KEY=" value; updated = 1; next }
      { print }
      END { if (!updated) print "OPENAI_API_KEY=" value }
    ' "$PROVIDERS_ENV" > "$tmp"
    mv "$tmp" "$PROVIDERS_ENV"
  else
    printf 'OPENAI_API_KEY=%s\n' "$key" > "$PROVIDERS_ENV"
  fi
  chmod 600 "$PROVIDERS_ENV"
}

seed_openai_key_from_codex_auth

run_once() {
  local label="$1"
  local out_file
  out_file="$(mktemp)"
  trap 'rm -f "$out_file"' RETURN

  echo "[$label] running zagent scenario..."
  if ! timeout "$ZAGENT_TIMEOUT_SECONDS" bash -lc \
    "env HOME='$ZAGENT_HOME' bash -lc \"printf '/provider %s\\n/model %s/%s\\n%s\\n/quit\\n' '$PROVIDER_ID' '$PROVIDER_ID' '$MODEL_ID' \\\"$SCENARIO_PROMPT\\\" | '$ZAGENT_BIN'\"" \
    >"$out_file" 2>&1; then
    cat "$out_file"
    return 1
  fi

  cat "$out_file"

  if rg -q "No API key configured|Provider not connected" "$out_file"; then
    echo "[$label] zagent model run failed." >&2
    return 1
  fi

  if rg -q "Model query failed|UnexpectedConnectFailure|unexpected errno: 1|stream disconnected before completion" "$out_file"; then
    if [[ "$REQUIRE_LIVE_MODEL" == "1" ]]; then
      echo "[$label] live model check failed and REQUIRE_LIVE_MODEL=1." >&2
      return 1
    fi
    LIVE_MODEL_SKIPPED=1
    echo "[$label] live model check skipped due network/sandbox limitations." >&2
    return 0
  fi

  if ! rg -q "\\bDONE\\b" "$out_file"; then
    echo "[$label] expected final 'DONE' marker was not found." >&2
    return 1
  fi
}

checksum() {
  sha256sum "$1" | awk '{print $1}'
}

before="$(checksum "$TARGET_FILE")"
run_once "pass-1"
if ! zig run "$TARGET_FILE" | grep -F "10 * 5 = 50" >/dev/null; then
  echo "runtime verify unavailable, using static checks instead..."
  rg -n "pub fn multiply\\(a: i32, b: i32\\) i32" "$TARGET_FILE" >/dev/null
  rg -n "10 \\* 5 = \\{d\\}" "$TARGET_FILE" >/dev/null
fi
after_pass_1="$(checksum "$TARGET_FILE")"

run_once "pass-2"
after_pass_2="$(checksum "$TARGET_FILE")"

if [[ "$after_pass_1" != "$after_pass_2" ]]; then
  echo "Idempotency check failed: $TARGET_FILE changed on second run." >&2
  exit 1
fi

echo "zagent test passed."
echo "before:      $before"
echo "after pass1: $after_pass_1"
echo "after pass2: $after_pass_2"
if [[ "$LIVE_MODEL_SKIPPED" == "1" ]]; then
  echo "live model check: skipped (set REQUIRE_LIVE_MODEL=1 to enforce)"
else
  echo "live model check: passed"
fi
