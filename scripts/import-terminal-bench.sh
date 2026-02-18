#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Import Terminal-Bench tasks, build a flat task view, and optionally run N tasks.

Usage:
  scripts/import-terminal-bench.sh [options]

Options:
  --dataset NAME@VER     Dataset reference (default: terminal-bench@2.0)
  --sample               Shortcut for --dataset terminal-bench-sample@2.0
  --output-dir PATH      Download root (default: third_party/terminal-bench-2)
  --flat-dir PATH        Flat symlink dir (default: <output-dir>/flat)
  --index-file PATH      Task index file (default: <output-dir>/task-list.txt)
  --refresh-import       Force re-download + re-index even if cache exists
  --run N                Run first N tasks sequentially with run-harbor-trial.sh
  --task-index N         Run exactly task N from the index (1-based)
  --force-build          Pass --force-build to each trial run
  --dry-run              Print intended run commands without executing
  --help, -h             Show help
EOF
}

DATASET="terminal-bench@2.0"
OUTPUT_DIR="third_party/terminal-bench-2"
FLAT_DIR=""
INDEX_FILE=""
RUN_COUNT=0
TASK_INDEX=0
FORCE_BUILD=0
DRY_RUN=0
REFRESH_IMPORT=0
SAMPLE_MODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dataset)
      DATASET="${2:-}"
      shift 2
      ;;
    --sample)
      SAMPLE_MODE=1
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --flat-dir)
      FLAT_DIR="${2:-}"
      shift 2
      ;;
    --index-file)
      INDEX_FILE="${2:-}"
      shift 2
      ;;
    --run)
      RUN_COUNT="${2:-0}"
      shift 2
      ;;
    --task-index)
      TASK_INDEX="${2:-0}"
      shift 2
      ;;
    --refresh-import)
      REFRESH_IMPORT=1
      shift
      ;;
    --force-build)
      FORCE_BUILD=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! command -v harbor >/dev/null 2>&1; then
  echo "harbor CLI not found. Install with: uv tool install harbor" >&2
  exit 1
fi

if [[ "$RUN_COUNT" =~ ^[0-9]+$ ]] && [[ "$RUN_COUNT" -lt 0 ]]; then
  echo "--run must be a non-negative integer" >&2
  exit 1
fi
if ! [[ "$TASK_INDEX" =~ ^[0-9]+$ ]]; then
  echo "--task-index must be a positive integer (1-based)" >&2
  exit 1
fi
if [[ "$TASK_INDEX" -lt 0 ]]; then
  echo "--task-index must be a positive integer (1-based)" >&2
  exit 1
fi
if [[ "$TASK_INDEX" -gt 0 && "$RUN_COUNT" -gt 0 ]]; then
  echo "Use either --run or --task-index, not both." >&2
  exit 1
fi

if [[ -z "$FLAT_DIR" ]]; then
  FLAT_DIR="$OUTPUT_DIR/flat"
fi
if [[ -z "$INDEX_FILE" ]]; then
  INDEX_FILE="$OUTPUT_DIR/task-list.txt"
fi
if [[ "$SAMPLE_MODE" -eq 1 ]]; then
  DATASET="terminal-bench-sample@2.0"
  OUTPUT_DIR="third_party/terminal-bench-sample-2"
  FLAT_DIR="$OUTPUT_DIR/flat"
  INDEX_FILE="$OUTPUT_DIR/task-list.txt"
  if [[ "$RUN_COUNT" -eq 0 ]]; then
    RUN_COUNT=1
  fi
fi
DATASET_MARKER="$OUTPUT_DIR/.dataset_ref"

mkdir -p "$OUTPUT_DIR"

need_import=1
if [[ "$REFRESH_IMPORT" -eq 0 && -s "$INDEX_FILE" && -d "$FLAT_DIR" && -f "$DATASET_MARKER" ]]; then
  cached_dataset="$(cat "$DATASET_MARKER" 2>/dev/null || true)"
  if [[ "$cached_dataset" == "$DATASET" ]]; then
    need_import=0
  fi
fi

if [[ "$need_import" -eq 1 ]]; then
  echo "Importing dataset: $DATASET -> $OUTPUT_DIR"
  harbor datasets download "$DATASET" -o "$OUTPUT_DIR" --overwrite

  echo "Building flat task links: $FLAT_DIR"
  rm -rf "$FLAT_DIR"
  mkdir -p "$FLAT_DIR"

  tmp_index="$(mktemp)"
  while IFS= read -r task_dir; do
    parent_hash="$(basename "$(dirname "$task_dir")")"
    task_name="$(basename "$task_dir")"
    link_name="$task_name"
    link_path="$FLAT_DIR/$link_name"

    if [[ -e "$link_path" ]]; then
      link_name="${task_name}-${parent_hash:0:8}"
      link_path="$FLAT_DIR/$link_name"
    fi

    ln -s "$(realpath "$task_dir")" "$link_path"
    printf "%s\n" "$(realpath "$link_path")" >> "$tmp_index"
  done < <(find "$OUTPUT_DIR" -mindepth 2 -maxdepth 2 -type d | sort)

  sort -u "$tmp_index" > "$INDEX_FILE"
  rm -f "$tmp_index"
  printf "%s\n" "$DATASET" > "$DATASET_MARKER"
else
  echo "Using cached import at: $OUTPUT_DIR"
fi

task_total="$(wc -l < "$INDEX_FILE" | tr -d ' ')"
echo "Indexed $task_total tasks at: $INDEX_FILE"

if [[ "$RUN_COUNT" -eq 0 ]]; then
  if [[ "$TASK_INDEX" -eq 0 ]]; then
    echo "Import complete. No trials run."
    exit 0
  fi
else
  if [[ "$TASK_INDEX" -gt 0 ]]; then
    echo "Use either --run or --task-index, not both." >&2
    exit 1
  fi
fi

if [[ "$TASK_INDEX" -gt 0 ]]; then
  if [[ "$TASK_INDEX" -gt "$task_total" ]]; then
    echo "--task-index $TASK_INDEX is out of range (1..$task_total)" >&2
    exit 1
  fi
  task_path="$(sed -n "${TASK_INDEX}p" "$INDEX_FILE")"
  task_name="$(basename "$task_path")"
  trial_name="tb2_${task_name}_$(date +%Y%m%d_%H%M%S)"
  cmd=(scripts/run-harbor-trial.sh --task "$task_path" --trial-name "$trial_name")
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    cmd+=(-- --force-build)
  fi
  echo "[${TASK_INDEX}/${task_total}] ${cmd[*]}"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "${cmd[@]}"
  fi
  echo "Done."
  exit 0
fi

if [[ "$RUN_COUNT" -eq 0 ]]; then
  echo "Import complete. No trials run."
  exit 0
fi

echo "Running first $RUN_COUNT task(s) from index..."
count=0
while IFS= read -r task_path; do
  (( count += 1 ))
  if [[ "$count" -gt "$RUN_COUNT" ]]; then
    break
  fi

  task_name="$(basename "$task_path")"
  trial_name="tb2_${task_name}_$(date +%Y%m%d_%H%M%S)"
  cmd=(scripts/run-harbor-trial.sh --task "$task_path" --trial-name "$trial_name")
  if [[ "$FORCE_BUILD" -eq 1 ]]; then
    cmd+=(-- --force-build)
  fi

  echo "[$count/$RUN_COUNT] ${cmd[*]}"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    "${cmd[@]}"
  fi
done < "$INDEX_FILE"

echo "Done."
