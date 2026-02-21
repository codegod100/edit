# Context Management v2 Design

**Date:** 2026-02-20  
**Status:** Approved (Brainstorm complete)  
**Decision:** Hard cutover to v2 context format (no backward read path)

## Goal
Redesign context management for higher reliability, stronger retrieval quality, and predictable prompt construction.

## Scope Decisions
- Optimize in balanced order: reliability foundation → quality → cost
- Allow breaking on-disk format changes
- Hard cutover migration strategy (v2 only)

---

## 1) Evaluation of Current Context Management

Current implementation in `src/context.zig` and `src/repl/main.zig` provides working persistence, compaction, and restore, but has structural weaknesses:

- One JSON blob stores mixed concerns (turn transcript + summary + project metadata)
- Retrieval relies on recency + lightweight lexical scoring; relevance can drift
- Compaction is coarse (`max_chars`, `keep_recent_turns`) and may discard useful detail
- Path-hash identity can fragment memory across path changes
- Limited integrity/version controls for persistence and replay behavior

These issues reduce confidence in long-running sessions and degrade continuity quality.

---

## 2) Recommended Target Architecture

### Recommended approach
**Event log + derived state files** (selected over patching monolith JSON):

- Better crash recovery
- Deterministic replay for testability
- Clean separation between persistence, memory reduction, and retrieval

### Core components
1. **ContextStore v2**
   - append-only event writer
   - atomic snapshot writes
   - schema/integrity checks
2. **MemoryReducer**
   - rebuilds in-memory state from events
   - produces working window + durable memory
3. **Retriever**
   - selects relevant context pack (recent turns + durable facts + thread links + lexical hits)
4. **PromptAssembler**
   - deterministic prompt sections with strict per-section budgets

---

## 3) v2 Storage Schema (Hard Cutover)

Per-project layout:

- `contexts-v2/<project_id>/meta.json`
- `contexts-v2/<project_id>/events.ndjson`
- `contexts-v2/<project_id>/snapshot.json`
- `contexts-v2/<project_id>/index.json` (optional derived cache)

### `meta.json`
- `schema_version: 2`
- `project_id`
- `project_root`
- `created_at`
- `last_compacted_at`
- `integrity_mode`

### `events.ndjson`
Typed events with monotonic sequencing, e.g.:
- `user_turn`
- `assistant_turn`
- `tool_event`
- `status_event`
- `decision_event`
- `error_event`

Each event includes at least: `event_seq`, `session_id`, timestamp, payload.

### `snapshot.json`
Reducer output checkpoint for fast restore:
- working short-term window
- durable facts/decisions
- open threads/tasks
- last applied `event_seq`

---

## 4) Data Flow

### Turn execution
1. Append `user_turn`
2. Build retrieval context pack
3. Call model
4. Append `assistant_turn` (+ tool/error/status events)
5. Run reducer update
6. Snapshot/compact on checkpoint conditions

### Restore
1. Load `meta`
2. Load `snapshot`
3. Replay events after snapshot `event_seq`
4. Reconstruct in-memory context deterministically

---

## 5) Error Handling Strategy

- Event append must be atomic at record boundary
- Snapshot writes use temp file + rename
- Truncated final NDJSON line: discard only tail line and log recovery
- Invalid snapshot: ignore snapshot, replay full event log
- Catastrophic failure: start fresh context with explicit warning (no silent fallback)
- Detect gaps/cross-session contamination via `event_seq` + `session_id`

---

## 6) Testing Strategy

1. **Reducer determinism tests** (same stream => same state)
2. **Crash recovery tests** (partial writes, truncated lines)
3. **Retrieval relevance fixtures** (expected decisions/files/issues selected)
4. **Prompt budget tests** (section caps enforced)
5. **Hard cutover tests** (v1 ignored with explicit messaging)
6. **Integration tests** (`/restore`, resume, compaction checkpoints)

---

## 7) Prioritized Implementation Suggestions

1. Implement `ContextStore v2` with schema + atomic IO
2. Implement reducer + snapshot replay path
3. Replace current context message builder with `PromptAssembler` budgets
4. Improve retrieval scoring (thread/decision weighting)
5. Add `/context debug` observability command for selected context pack
6. Remove v1 context path usage and update docs/README accordingly

---

## Success Criteria

- Deterministic replay and reliable restore under fault conditions
- Better relevance in multi-turn coding tasks
- Predictable bounded prompt construction
- Clear operational observability for debugging context selection
