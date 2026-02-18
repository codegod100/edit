#!/usr/bin/env python3
"""
One-time migration script for zagent context files.

Backfills `project_path` in ~/.config/zagent/context-*.json using aggressive
heuristics from title + turns, with optional in-place writes.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Optional


PROJECT_ROOT_MARKERS = (
    "Active project root:",
    "Project set to",
)


def is_abs_dir(path_str: str) -> bool:
    p = Path(path_str).expanduser()
    return p.is_absolute() and p.is_dir()


def normalize_path(path_str: str) -> str:
    return str(Path(path_str).expanduser().resolve())


def extract_absolute_paths(text: str) -> list[str]:
    # Capture slash-prefixed tokens up to obvious delimiters.
    candidates = re.findall(r"(/[^\s\"'<>]+)", text)
    out: list[str] = []
    for c in candidates:
        c = c.rstrip(".,;:)]}")
        if c.startswith("//"):
            continue
        out.append(c)
    return out


def score_candidate(path: str, context_text: str) -> int:
    score = 0
    if is_abs_dir(path):
        score += 10
    for marker in PROJECT_ROOT_MARKERS:
        if f"{marker} {path}" in context_text:
            score += 50
    if "/home/" in path:
        score += 2
    score += max(0, 20 - len(path) // 8)
    return score


def infer_project_path(payload: dict) -> Optional[str]:
    existing = payload.get("project_path")
    if isinstance(existing, str) and is_abs_dir(existing):
        return normalize_path(existing)

    candidates: list[str] = []
    context_blob_parts: list[str] = []

    title = payload.get("title")
    if isinstance(title, str):
        context_blob_parts.append(title)
        if title.startswith("/"):
            candidates.append(title.strip())

    turns = payload.get("turns", [])
    if isinstance(turns, list):
        for turn in turns:
            if not isinstance(turn, dict):
                continue
            content = turn.get("content")
            if not isinstance(content, str):
                continue
            context_blob_parts.append(content)

            for marker in PROJECT_ROOT_MARKERS:
                idx = content.find(marker)
                if idx >= 0:
                    maybe = content[idx + len(marker) :].strip()
                    if maybe.startswith("/"):
                        line = maybe.splitlines()[0].strip()
                        if line:
                            candidates.append(line)
            candidates.extend(extract_absolute_paths(content))

    context_blob = "\n".join(context_blob_parts)
    if not candidates:
        return None

    ranked: list[tuple[int, str]] = []
    seen = set()
    for c in candidates:
        if c in seen:
            continue
        seen.add(c)
        ranked.append((score_candidate(c, context_blob), c))

    ranked.sort(key=lambda x: x[0], reverse=True)
    best_score, best = ranked[0]
    if best_score < 10:
        return None
    if not is_abs_dir(best):
        return None
    return normalize_path(best)


def process_file(path: Path, write: bool, verbose: bool) -> tuple[str, Optional[str]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return ("failed", None)

    if not isinstance(payload, dict):
        return ("failed", None)

    existing = payload.get("project_path")
    if isinstance(existing, str) and is_abs_dir(existing):
        return ("skipped", normalize_path(existing))

    inferred = infer_project_path(payload)
    if not inferred:
        return ("skipped", None)

    payload["project_path"] = inferred
    if write:
        try:
            text = json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n"
            path.write_text(text, encoding="utf-8")
        except Exception:
            return ("failed", None)
    if verbose:
        print(f"{path.name}: {inferred}")
    return ("updated", inferred)


def main() -> int:
    parser = argparse.ArgumentParser(description="Backfill project_path in zagent context files.")
    parser.add_argument(
        "--config-dir",
        default=str(Path.home() / ".config" / "zagent"),
        help="Path to zagent config directory (default: ~/.config/zagent)",
    )
    parser.add_argument("--write", action="store_true", help="Write changes in place (default is dry-run)")
    parser.add_argument("--verbose", action="store_true", help="Print each updated file/path")
    args = parser.parse_args()

    config_dir = Path(args.config_dir).expanduser()
    files = sorted(config_dir.glob("context-*.json"))

    scanned = 0
    updated = 0
    skipped = 0
    failed = 0

    for f in files:
        scanned += 1
        status, _ = process_file(f, write=args.write, verbose=args.verbose)
        if status == "updated":
            updated += 1
        elif status == "skipped":
            skipped += 1
        else:
            failed += 1

    mode = "write" if args.write else "dry-run"
    print(f"mode={mode} scanned={scanned} updated={updated} skipped={skipped} failed={failed}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
