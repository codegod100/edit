# README Overhaul Design

**Date:** 2026-02-20
**Status:** Approved

## Goal
Fully clean up and overhaul README as a single-source document, optimized for both users and contributors in one file.

## High-level Decisions
- Continue work on current `main` working state (user-selected)
- Full overhaul scope (not light cleanup)
- Audience split inside one README: quickstart-first + contributor section
- Keep README single-source (do not offload deep detail to docs links)
- Tone/style: hybrid (crisp bullets + practical examples)
- Document intended behavior only (no known-issues section)

---

## Section 1: README Information Architecture

README will be restructured into a linear workflow:

1. **What is zagent?**
   - concise project purpose and capability snapshot

2. **5-minute Quickstart**
   - build, run, connect, choose model, first prompt, exit
   - copy/paste command flow

3. **Core Commands**
   - grouped by intent:
     - setup/auth (`/connect`, `/providers`, `/provider`)
     - model controls (`/model`, `/models`, `--model`)
     - session controls (`/restore`, `/clear`, `/quit`)
     - utility commands

4. **How zagent works**
   - model loop, tool routing, context, spinner/status behavior
   - completion guard behavior (work or blocker)

5. **Contributor Workflow**
   - repo layout
   - build/test commands
   - key files and where to edit

6. **Troubleshooting + FAQ**
   - auth/model/provider/command resolution issues

---

## Section 2: Content Contract (Accuracy Rules)

README must be behavior-accurate and code-grounded:

- Every command listed must exist in `src/repl/commands.zig`
- Every command behavior claim must match `src/repl/handlers.zig`
- Auth flow claims must match `src/auth.zig` + provider/model resolution
- Model/backend behavior claims must match model loop/orchestrator paths
- Spinner/status claims must match display + tool wiring

Required explicit documentation:
- Interactive + non-interactive entry points
- `--model provider/model` semantics
- Auth sources and precedence for supported flows
- Command examples with expected effect
- Implementation reliability contract (concrete work or explicit blocker)

No speculative or future-only behavior in README.

---

## Section 3: Validation + Migration Strategy

### Validation gates
1. **Accuracy pass** against code
2. **Execution pass**: run Quickstart sequence from README
3. **Terminology pass** for consistent language

### Migration plan
- Replace README in one coherent commit
- Preserve/normalize section anchors where reasonable
- Keep examples short, realistic, and runnable
- Avoid placeholder behavior that diverges from runtime

### Ongoing maintenance rule
Any PR that changes command UX/auth/model flow must update corresponding README section in same PR.

---

## Success Criteria

README is:
- structurally clean and scan-friendly
- accurate to current runtime behavior
- sufficient for first-run onboarding
- sufficient for contributor orientation
- single-source and maintainable
