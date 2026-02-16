# Plan: Terminal UI & Scrolling System Rewrite

## Objective
Replace the current "flickery" and "scrollback-corrupting" UI with a robust architecture that supports a pinned status bar while allowing the main conversation and prompt to scroll naturally and infinitely.

## Goals
1.  **Pinned Status Bar**: A dedicated 1-line bar at the physical bottom of the terminal window for the spinner and high-level status.
2.  **Scrolling Prompt History**: Every input turn prints a fresh prompt box (╭─...─╮) that encapsulates the user's command. These boxes scroll up with the log, creating a clear visual history of what was asked.
3.  **Infinite Scrollback**: No full-screen clearing or complex cursor saves that break the terminal's native scrollback buffer. Use standard scrolling logic.
4.  **Session Traceability**: Display Session ID on startup and maintain `transcript_<id>.txt` for deep analysis.

## Technical Strategy

### 1. Scrolling Region (The "Correct" way)
Use the ANSI `DECSTBM` escape sequence (`\x1b[1;<height-1>r`) to define a scrolling region that excludes the bottom line.
-   **Main Area**: Lines 1 to `term_height - 1`.
-   **Status Area**: Line `term_height`.
-   **Impact**: When the terminal reaches the end of the main area, it scrolls *only* that area, leaving the status bar untouched.

### 2. Implementation Status

- [x] **`src/display.zig`**:

    - [x] Implement `setupScrollingRegion()` and `resetScrollingRegion()`.

    - [x] Refactor `renderStatusBar()` to target the absolute bottom line using `\x1b[s` and `\x1b[u`.

- [x] **`src/repl/main.zig`**:

    - [x] Call `setupScrollingRegion` on start and `resetScrollingRegion` on exit.

    - [x] Simplify the input loop: Print fresh prompt box every turn, let it scroll.

- [x] **`src/line_editor.zig`**:

    - [x] Removed absolute cursor positioning hacks. Prompt scrolls normally.

### 3. Verification
-   Test with long outputs (e.g., `ls -R /`) to ensure the status bar doesn't move.
-   Verify that manual scrolling (mouse wheel/PgUp) reveals the entire history without missing lines.
-   Confirm Session IDs match the transcript filenames.

## Success Criteria
-   [ ] Status bar stays at line `N` regardless of log activity.
-   [ ] `Ctrl+C` works instantly.
-   [ ] No corrupted characters or "ghost" prompts in the scrollback.
