#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
Migrate benchmark tasks from benchmarks/<name>/ into Harbor task format at harbor-tasks/<name>/.

Usage:
  scripts/migrate-benchmarks-to-harbor.sh [--task NAME]

Options:
  --task NAME   Migrate only one benchmark task (directory name under benchmarks/)
  -h, --help    Show help
EOF
}

ONLY_TASK=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      ONLY_TASK="${2:-}"
      shift 2
      ;;
    -h|--help)
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

mkdir -p harbor-tasks

migrate_one() {
  local name="$1"
  local src="benchmarks/$name"
  local dst="harbor-tasks/$name"

  if [[ ! -f "$src/prompt.txt" || ! -f "$src/setup.sh" || ! -f "$src/verify.sh" ]]; then
    echo "Skipping $name: missing prompt/setup/verify files"
    return
  fi

  mkdir -p "$dst/environment" "$dst/tests"

  cat "$src/prompt.txt" > "$dst/instruction.md"

  cat > "$dst/task.toml" <<'EOF'
version = "1.0"

[metadata]

[verifier]
timeout_sec = 600.0

[agent]
timeout_sec = 600.0

[environment]
build_timeout_sec = 600.0
cpus = 1
memory_mb = 2048
storage_mb = 10240
gpus = 0
allow_internet = true
mcp_servers = []

[verifier.env]

[solution.env]
EOF

  cat > "$dst/environment/Dockerfile" <<'EOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    coreutils \
    curl \
    gcc \
    git \
    grep \
    python3 \
    sed \
    xz-utils \
 && rm -rf /var/lib/apt/lists/*

# Install Zig (stable) for Zig-based tasks.
RUN curl -fsSL https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz -o /tmp/zig.tar.xz \
 && mkdir -p /opt \
 && tar -xJf /tmp/zig.tar.xz -C /opt \
 && ln -s /opt/zig-linux-x86_64-0.13.0/zig /usr/local/bin/zig \
 && rm -f /tmp/zig.tar.xz

WORKDIR /app
EOF

  cp "$src/setup.sh" "$dst/agent_setup.sh"
  chmod +x "$dst/agent_setup.sh"
  cp "$src/setup.sh" "$dst/tests/setup.sh"
  cp "$src/verify.sh" "$dst/tests/verify.sh"
  chmod +x "$dst/tests/setup.sh" "$dst/tests/verify.sh"

  cat > "$dst/tests/test.sh" <<'EOF'
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
EOF

  chmod +x "$dst/tests/test.sh"
  echo "Migrated: $src -> $dst"
}

if [[ -n "$ONLY_TASK" ]]; then
  if [[ ! -d "benchmarks/$ONLY_TASK" ]]; then
    echo "Task not found: benchmarks/$ONLY_TASK" >&2
    exit 1
  fi
  migrate_one "$ONLY_TASK"
  exit 0
fi

for dir in benchmarks/*; do
  [[ -d "$dir" ]] || continue
  migrate_one "$(basename "$dir")"
done
