# Context Management v2 Implementation Plan

> **REQUIRED SUB-SKILL:** Use the executing-plans skill to implement this plan task-by-task.

**Goal:** Implement hard-cutover Context v2 storage and loading with deterministic save/load behavior.

**Architecture:** Introduce `contexts-v2/<project-id>/` layout with `meta.json`, `snapshot.json`, and `events.ndjson`. Replace current context persistence/load/session listing to use v2 only. Keep in-memory `ContextWindow` API stable so REPL/web integrations continue to work.

**Tech Stack:** Zig stdlib JSON/fs APIs, existing `src/context.zig` and REPL/web context integration.

---

### Task 1: Add failing tests for v2 persistence and hard cutover

**TDD scenario:** New feature — full TDD cycle

**Files:**
- Modify: `src/context.zig` (tests section)

**Step 1: Write failing test**
- Add test verifying `saveContextWindow` creates `contexts-v2/<hash>/meta.json`, `snapshot.json`, `events.ndjson`.
- Add test verifying load ignores legacy `contexts/context-<hash>.json` when no v2 snapshot exists.

**Step 2: Run test to verify failure**
Run: `zig build test`
Expected: FAIL on missing v2 paths or legacy behavior mismatch.

**Step 3: Minimal implementation**
- None in this task.

**Step 4: Re-run test**
- Still failing until implementation tasks complete.

**Step 5: Commit**
- Commit together with implementation in later tasks.

### Task 2: Implement v2 path helpers + save/load

**TDD scenario:** New feature — full TDD cycle

**Files:**
- Modify: `src/paths.zig`
- Modify: `src/context.zig`

**Step 1: Implement path constants/helpers**
- Add `CONTEXTS_V2_DIR_NAME` and helpers for v2 project dir + files.

**Step 2: Implement v2 save**
- Write `meta.json`, `snapshot.json`, `events.ndjson` under project dir.

**Step 3: Implement v2 load**
- Load from snapshot only (v2 only); do not read legacy file.

**Step 4: Run tests**
Run: `zig build test`
Expected: new tests pass.

**Step 5: Commit**
- Commit code + tests.

### Task 3: Update session listing to v2 layout

**TDD scenario:** Modifying tested code — run existing tests first and after

**Files:**
- Modify: `src/context.zig`

**Step 1: Update `listContextSessions` to scan `contexts-v2/*/snapshot.json`**
- Populate existing `SessionInfo` fields from v2 snapshot/meta.

**Step 2: Run tests/build**
Run: `zig build && zig build test`
Expected: PASS.

**Step 3: Commit**
- Commit if separated from Task 2.

### Task 4: Verify integration call sites remain compatible

**TDD scenario:** Modifying code with existing tests

**Files:**
- Validate compatibility in: `src/main.zig`, `src/repl/main.zig`, `src/web_main.zig`

**Step 1: Build and run tests**
Run: `zig build && zig build test`
Expected: PASS.

**Step 2: Smoke-check key flows**
- `/restore`
- `--resume`
- session listing in CLI/web

**Step 3: Commit**
- Final integration commit if needed.
