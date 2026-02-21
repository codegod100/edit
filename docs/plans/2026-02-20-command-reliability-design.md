# Command Reliability Design (No Fake Progress)

**Date:** 2026-02-20
**Status:** Approved

## Goal
Ensure implementation-intent turns cannot end in fake progress (e.g., “I’ll implement this” with no concrete edits), and must end with either:
1) verifiable work evidence, or
2) explicit blocker with actionable reason.

---

## Problem
Current behavior can produce low-reliability turns where the assistant appears to proceed but does not actually execute required work. This causes user distrust and wasted iterations.

Observed failure classes:
- claims intent, performs no meaningful tool actions
- calls read-only tools repeatedly and stalls
- produces ambiguous completion text without concrete file changes
- exits turn without explicit blocker despite inability to proceed

---

## Proposed Architecture: Turn Completion Guard

Introduce a turn-level validator in `src/model_loop/orchestrator.zig` (or helper module) that evaluates completion before accepting a turn.

### Outcomes
- `CompletedWithWork`
- `CompletedWithBlocker`
- `InsufficientProgress`

### Evidence Inputs
Reuse existing orchestrator telemetry:
- tool call count
- mutating tool execution count
- files touched
- verification tool executions (where relevant)
- final response text presence

### Acceptance Contract (implementation-intent turns)
A turn is accepted only if one path is true:

1. **Work path**
   - concrete mutation evidence (`write/edit/patch` etc.)
   - final response present

2. **Blocker path**
   - explicit blocker message with concrete cause and next action

Otherwise → `InsufficientProgress`.

---

## Data Flow

1. Classify request as implementation-intent or not (using existing heuristics + lightweight additions).
2. Run normal model/tool loop.
3. Before final return, call `CompletionGuard.evaluate(...)`.
4. If `InsufficientProgress`:
   - inject corrective user message:
     - “Implementation intent detected but no concrete work or explicit blocker. Execute required edits now or return actionable blocker.”
   - retry with bounded budget (e.g., 2)
5. If retries exhausted:
   - return explicit reliability failure (not fake success)

---

## Failure Handling Rules

- **No-op intent**: reject and reprompt
- **Read-only loops**: reject unless request is analysis-only
- **Tool errors**: require explicit blocker if no successful mutation
- **Partial work, no closure**: reprompt for concrete completion or blocker
- **Repeated insufficiency**: fail explicitly after budget

---

## Testing Strategy

### Unit Tests
- intent + no mutation + no blocker => `InsufficientProgress`
- intent + mutation + response => `CompletedWithWork`
- intent + blocker text => `CompletedWithBlocker`
- non-implementation prompt with read-only behavior remains acceptable

### Integration Tests
- simulated “I will implement…” + no edits triggers corrective retry
- retry exhaustion returns explicit failure
- successful mutation path bypasses correction

### Manual Validation
- prompt for concrete implementation task
- verify either real file changes occur or explicit blocker appears
- confirm no fake-success turns remain

---

## Rollout

1. Add guard with low retry budget (default-on)
2. Tune blocker phrase detection with logs
3. Optional future: stricter contracts for specific slash commands

---

## Non-Goals (This Iteration)

- full workflow state machine refactor
- major prompt architecture rewrite
- command-specific custom planners

---

## Success Criteria

For implementation-intent requests, every completed turn yields:
- concrete edit evidence + completion text, or
- explicit blocker with actionable reason.

No silent/no-op “implemented” responses.
