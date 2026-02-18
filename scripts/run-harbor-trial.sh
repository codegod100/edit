#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Run a Harbor trial with the local zagent adapter.

Usage:
  scripts/run-harbor-trial.sh --task /abs/or/rel/task/path [options] [-- <extra harbor args>]

Required:
  --task PATH              Path to Harbor task directory

Options:
  --model MODEL_ID         zagent model id (default: glm-4.7)
  --provider PROVIDER_ID   provider id in adapter (default: zai)
  --zagent-bin PATH        zagent binary path for adapter (default: ./zig-out/bin/zagent)
  --harbor-bin CMD         harbor CLI command (default: harbor)
  --trial-name NAME        explicit Harbor trial name
  --dry-run                print final harbor command only
  -h, --help               show this help

Environment:
  ZAI_API_KEY              required for provider=zai

Examples:
  scripts/run-harbor-trial.sh --task ./tasks/my-task
  scripts/run-harbor-trial.sh --task ./tasks/my-task --model glm-4.7 -- --timeout-multiplier 1.2
EOF
}

TASK_PATH=""
MODEL_ID="${MODEL_ID:-glm-4.7}"
PROVIDER_ID="${PROVIDER_ID:-zai}"
ZAGENT_BIN="${ZAGENT_BIN:-$ROOT_DIR/zig-out/bin/zagent}"
HARBOR_BIN="${HARBOR_BIN:-harbor}"
TRIAL_NAME="${TRIAL_NAME:-}"
DRY_RUN=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      TASK_PATH="${2:-}"
      shift 2
      ;;
    --model)
      MODEL_ID="${2:-}"
      shift 2
      ;;
    --provider)
      PROVIDER_ID="${2:-}"
      shift 2
      ;;
    --zagent-bin)
      ZAGENT_BIN="${2:-}"
      shift 2
      ;;
    --harbor-bin)
      HARBOR_BIN="${2:-}"
      shift 2
      ;;
    --trial-name)
      TRIAL_NAME="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        EXTRA_ARGS+=("$1")
        shift
      done
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TASK_PATH" ]]; then
  echo "--task is required" >&2
  usage
  exit 1
fi

if [[ ! -d "$TASK_PATH" ]]; then
  echo "Task path does not exist: $TASK_PATH" >&2
  exit 1
fi

# If running with rootless Podman and DOCKER_HOST is unset, default Docker CLI
# to the user podman socket so Harbor talks to the intended engine.
if [[ -z "${DOCKER_HOST:-}" ]]; then
  PODMAN_SOCK="/run/user/$(id -u)/podman/podman.sock"
  if [[ -S "$PODMAN_SOCK" ]]; then
    export DOCKER_HOST="unix://$PODMAN_SOCK"
    echo "Using Podman socket via DOCKER_HOST=$DOCKER_HOST"
  fi
fi

if [[ "$PROVIDER_ID" == "zai" && -z "${ZAI_API_KEY:-}" ]]; then
  echo "ZAI_API_KEY is required for provider=zai" >&2
  exit 1
fi

if [[ ! -x "$ZAGENT_BIN" ]]; then
  echo "zagent binary not found at $ZAGENT_BIN; building..."
  zig build
fi

ABS_TASK_PATH="$(cd "$TASK_PATH" && pwd)"
ABS_ZAGENT_BIN="$(cd "$(dirname "$ZAGENT_BIN")" && pwd)/$(basename "$ZAGENT_BIN")"
TASK_BASENAME="$(basename "$ABS_TASK_PATH")"
TASK_SETUP_SCRIPT="$ABS_TASK_PATH/agent_setup.sh"

if [[ -z "$TRIAL_NAME" ]]; then
  TRIAL_NAME="${TASK_BASENAME}_$(date +%Y%m%d_%H%M%S)"
fi

if ! command -v "$HARBOR_BIN" >/dev/null 2>&1; then
  echo "Harbor CLI not found: $HARBOR_BIN" >&2
  echo "Install: uv tool install harbor" >&2
  exit 1
fi

# Harbor's docker environment uploads agent/tests via `docker compose cp`.
# Podman's docker-compose v1 shim commonly lacks `cp`, which causes late trial failure.
if command -v docker >/dev/null 2>&1; then
  if ! docker compose --help 2>/dev/null | grep -Eq '^[[:space:]]+cp[[:space:]]'; then
    cat >&2 <<'EOF'
Your current compose backend does not support `docker compose cp`.
Harbor needs this for uploading agent artifacts and tests.

Detected backend:
  docker compose -> docker-compose v1 shim (no `cp`)

Fix options:
  1) Install Docker Compose v2 plugin (recommended).
  2) Configure podman to use a compose provider that supports `cp`.

After fixing, verify:
  docker compose --help | grep -E '^[[:space:]]+cp[[:space:]]'
EOF
    exit 1
  fi
fi

CMD=(
  "$HARBOR_BIN" trials start
  -p "$ABS_TASK_PATH"
  --agent-import-path harbor_adapter.zagent_agent:ZagentHarborAgent
  --agent-kwarg "zagent_binary_path=$ABS_ZAGENT_BIN"
  --agent-kwarg "provider_id=$PROVIDER_ID"
  --agent-kwarg "zagent_model_id=$MODEL_ID"
  --agent-kwarg "instruction_prefix=Work from the task workspace only. Start by checking pwd and local files. If /app/task_file exists, use it as task root. Never run global filesystem scans like find /. If only numeric threshold tests fail (cost/latency/%), prioritize objective optimization and rerun failing checks before finishing."
)

if [[ -f "$TASK_SETUP_SCRIPT" ]]; then
  CMD+=(--agent-kwarg "task_setup_script_path=$TASK_SETUP_SCRIPT")
fi

CMD+=(--trial-name "$TRIAL_NAME")

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

export PYTHONPATH="$ROOT_DIR${PYTHONPATH:+:$PYTHONPATH}"

echo "Running Harbor trial with:"
DISPLAY_CMD=("${CMD[@]}")
for i in "${!DISPLAY_CMD[@]}"; do
  if [[ "${DISPLAY_CMD[$i]}" == ZAI_API_KEY=* ]]; then
    DISPLAY_CMD[$i]="ZAI_API_KEY=***REDACTED***"
  fi
done
printf '  %q' "${DISPLAY_CMD[@]}"
echo
echo "Logs:"
echo "  trials/$TRIAL_NAME/trial.log"
echo "  trials/$TRIAL_NAME/result.json"
echo "  trials/$TRIAL_NAME/exception.txt"
echo "  trials/$TRIAL_NAME/agent/zagent.txt"
echo "  trials/$TRIAL_NAME/verifier/test-stdout.txt"

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

"${CMD[@]}"
