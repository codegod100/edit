# Codex OAuth Support Design

**Date:** 2026-02-20  
**Status:** Approved (brainstormed)

## Goal
Add first-class Codex OAuth support to zagent via `/connect codex`, with runtime auth resolution using:
1. `GITHUB_COPILOT_API_KEY` environment variable (highest priority)
2. `~/.codex/copilot_auth.json` fallback

Token persistence for this feature is Codex-native only: write to `~/.codex/copilot_auth.json`.

---

## Scope (This Iteration)

- Add `/connect codex` command flow
- Run interactive OAuth login (browser/device style) for Codex
- Persist token to `~/.codex/copilot_auth.json` (atomic write)
- Update runtime auth lookup order for Codex provider:
  - Env first
  - Codex auth file fallback
- Show actionable errors when auth unavailable

### Out of Scope (YAGNI)

- No token refresh daemon
- No multi-account switching
- No provider-store mirroring
- No logout/account manager command
- No background refresh loop

---

## Architecture

Add a dedicated module, e.g.:
- `src/auth/codex_oauth.zig`

Responsibilities:
- Run OAuth connect flow for Codex
- Open browser / provide manual URL+code fallback
- Poll authorization endpoint until success/timeout/cancel
- Validate token payload
- Persist token to `~/.codex/copilot_auth.json` atomically
- Return structured result to REPL handler

Integrations:
- REPL `/connect codex` command handler invokes module
- Provider auth resolution path uses env-first then codex-file fallback
- Existing model/provider state refresh updates immediately after successful connect

---

## Runtime Auth Resolution

For Codex provider:

1. Check `GITHUB_COPILOT_API_KEY` environment variable
   - If present and non-empty, use it
2. Else, read `~/.codex/copilot_auth.json`
   - Parse token payload
   - If valid (and not expired when expiry available), use token
3. Else, return unauthenticated state with clear guidance (`/connect codex`)

This keeps behavior deterministic and compatible with standard Codex tooling.

---

## `/connect codex` Data Flow

1. User runs `/connect codex`
2. REPL handler calls `codex_oauth.connect(...)`
3. OAuth module:
   - starts browser/device login flow
   - prints progress updates
   - polls until authorized/denied/timeout/cancel
4. On success:
   - validate token structure
   - write `~/.codex/copilot_auth.json` atomically (temp file + rename)
5. Return success to REPL
6. REPL refreshes provider state and confirms connection

---

## Error Handling

- **Network issues / transient polling failures:** bounded retries with clear status
- **Browser open failure:** print manual URL/code path
- **Authorization denied/timeout:** descriptive error, no partial persistence
- **File write permission/path errors:** include exact path and remediation hint
- **User cancellation (Ctrl+C):** abort cleanly, return to prompt, no partial write
- **Malformed codex auth file at runtime:** ignore file for auth, show connect guidance

---

## Testing Strategy

### Unit Tests
- Parse codex auth file (valid/invalid/missing fields)
- Env precedence over file token
- Atomic write helper behavior
- Expiry interpretation where applicable

### Integration Tests
- `/connect codex` happy path with mocked OAuth transport
- timeout/denied/cancel flows
- provider resolution fallback from env -> file

### Manual Verification
- Run `/connect codex`, complete login, verify `~/.codex/copilot_auth.json`
- Restart zagent; confirm codex auth auto-detected
- Set env var and confirm env override
- Corrupt file and confirm graceful fallback messages

---

## Implementation Notes

- Keep OAuth and filesystem concerns isolated in `auth/codex_oauth.zig`
- Keep command handler thin: parse args, call module, print result
- Avoid coupling codex token storage with provider store in this version
- Use atomic file writes to prevent corrupted partial tokens

---

## Suggested Next Step
Create a detailed implementation plan and then execute in small commits:
1. OAuth module skeleton + token file parser/writer
2. `/connect codex` command wiring
3. provider auth resolution update (env -> file)
4. tests and manual verification
