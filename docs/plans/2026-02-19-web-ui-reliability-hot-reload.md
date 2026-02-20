# Web UI Reliability + Hot Reload Implementation Plan

> **REQUIRED SUB-SKILL:** Use the executing-plans skill to implement this plan task-by-task.

**Goal:** Stop JSON parse noise from non-text WebSocket frames, keep chat/table content within viewport, and add auto-refresh hot reloading for `web_ui` files.

**Architecture:** Harden message intake in `web_main` and frame parsing in `web/server` so only valid UTF-8 JSON text reaches the app handler. Add a lightweight file watcher thread in `web_main` that broadcasts a `dev_reload` event to connected WebSocket clients when `web_ui/index.html`, `web_ui/app.js`, or `web_ui/styles.css` change. Client-side JS listens for that event and reloads the page.

**Tech Stack:** Zig 0.15.2 (`std`, threads, fs stat polling), custom WebSocket server, vanilla HTML/CSS/JS.

---

### Task 1: Baseline + safety checkpoint

**Files:**
- Modify: none
- Test/Run: repo root

**Step 1: Capture current behavior**

Run:
```bash
zig build web
```
Expected: server starts; currently may log `Failed to parse message ... SyntaxError` warnings.

**Step 2: Capture build health before changes**

Run:
```bash
zig build
```
Expected: succeeds (or capture exact failing output to avoid regressions).

**Step 3: Commit checkpoint (optional but recommended)**

```bash
git add -A
git commit -m "chore: checkpoint before websocket and hot-reload hardening"
```

---

### Task 2: Add failing server tests for WebSocket parsing hardening

**Files:**
- Modify: `src/web/server.zig` (add `test` blocks at end of file)
- Test: `src/web/server.zig`

**Step 1: Write failing test for binary frame handling**

Add a test that builds a minimal binary frame (`opcode 0x2`) and verifies parser returns an empty message (ignored), not application payload.

**Step 2: Write failing test for ping/pong ignore semantics**

Add tests for `opcode 0x9` and `0xA` confirming they are consumed and yield empty message.

**Step 3: Run tests to verify fail first**

Run:
```bash
zig test src/web/server.zig
```
Expected: FAIL for new expectations before implementation is finalized.

**Step 4: Commit test-only change**

```bash
git add src/web/server.zig
git commit -m "test: add websocket frame filtering expectations"
```

---

### Task 3: Implement WebSocket parse filtering

**Files:**
- Modify: `src/web/server.zig` (`parseWebSocketFrame`)
- Test: `src/web/server.zig`

**Step 1: Implement minimal parser behavior**

In `parseWebSocketFrame`:
- Keep close/ping/pong behavior.
- Treat binary (`opcode 0x2`) as consumed + ignored (`message = empty slice`).
- Accept only text (`opcode 0x1`) payload for app messages.

**Step 2: Run parser tests**

Run:
```bash
zig test src/web/server.zig
```
Expected: PASS.

**Step 3: Run full build**

Run:
```bash
zig build
```
Expected: PASS.

**Step 4: Commit**

```bash
git add src/web/server.zig
git commit -m "fix: ignore binary websocket frames in server parser"
```

---

### Task 4: Harden `web_main` message intake for JSON text only

**Files:**
- Modify: `src/web_main.zig` (`handleMessage`)
- Test: manual runtime verification

**Step 1: Add pre-parse guards**

In `handleMessage` before JSON parse:
- trim input
- return empty response for zero-length payloads
- return empty response unless first non-whitespace byte is `{`
- return empty response if payload is not valid UTF-8

**Step 2: Parse trimmed payload only**

Use `trimmed` (not raw buffer) in `std.json.parseFromSlice`.

**Step 3: Keep warning logs concise**

Log parse warning without dumping binary garbage bytes into logs.

**Step 4: Verify compile**

Run:
```bash
zig build
```
Expected: PASS.

**Step 5: Commit**

```bash
git add src/web_main.zig
git commit -m "fix: guard websocket messages before json parsing"
```

---

### Task 5: Implement hot reload option 1 (auto refresh)

**Files:**
- Modify: `src/web_main.zig` (watcher thread + broadcaster)
- Modify: `web_ui/app.js` (listen for `dev_reload` and reload page)
- Modify: `web_ui/index.html` (optional small dev badge placeholder, if desired)
- Test: runtime manual

**Step 1: Add watcher state and thread entrypoint in `web_main`**

Add minimal polling watcher (e.g., 500ms-1000ms):
- track last modified timestamps for:
  - `web_ui/index.html`
  - `web_ui/app.js`
  - `web_ui/styles.css`
- on change, broadcast:
```json
{"type":"dev_reload","reason":"file_changed"}
```

**Step 2: Start watcher in `main()` and clean shutdown**

- spawn watcher thread after server init
- use a shared atomic/running flag
- join/stop cleanly on shutdown paths

**Step 3: Add client listener**

In `web_ui/app.js` `handleMessage` switch:
- case `dev_reload`: call `window.location.reload()`

**Step 4: Verify behavior manually**

Run server:
```bash
zig build web
```
Then edit `web_ui/styles.css` and save.
Expected: open browser tab auto-refreshes within ~1s.

**Step 5: Commit**

```bash
git add src/web_main.zig web_ui/app.js web_ui/index.html
git commit -m "feat: add web ui hot reload on static file changes"
```

---

### Task 6: Ensure chat/table width remains viewport-safe

**Files:**
- Modify: `web_ui/styles.css`
- Test: manual browser verification

**Step 1: Keep fixed-layout markdown tables + wrapping**

Ensure styles include:
- `.message-content { overflow-wrap:anywhere; word-break:break-word; }`
- `.message-content table { width:100%; max-width:100%; table-layout:fixed; }`
- `th, td` wrapping enabled (no forced nowrap)

**Step 2: Verify with long markdown table content**

Manual test prompt in chat:
- ask assistant to render a table with very long strings/URLs.
Expected: no horizontal overflow from message pane; content wraps within chat width.

**Step 3: Commit**

```bash
git add web_ui/styles.css
git commit -m "fix: constrain markdown tables and long chat content to viewport"
```

---

### Task 7: End-to-end verification and final integration commit

**Files:**
- Modify: none expected
- Test: runtime + build

**Step 1: Run full compile/test checks**

```bash
zig build
zig test src/web/server.zig
```
Expected: PASS.

**Step 2: Runtime verification**

Run:
```bash
zig build web
```
Check in browser:
- connected/model status looks clean
- no JSON parse warning spam in server logs while idle
- hot reload works on file save
- long chat + markdown tables fit viewport

**Step 3: Final commit**

```bash
git add -A
git commit -m "feat: harden websocket intake and add web ui hot reload"
```

---

## Notes for implementer

- Prefer minimal incremental changes per task (YAGNI).
- Keep each commit focused and reversible.
- If watcher thread complexity grows, stop and refactor into a tiny helper struct with explicit init/deinit and atomic run flag.
- Do not broaden hot reload scope beyond the three static files unless required.
