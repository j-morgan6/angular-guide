#!/usr/bin/env bash
# hook-lint.sh — Write|Edit hook for angular-guide. The rules live in lint.py.
#
# Modes:
#   pre   Blocking checks (NG001-NG018). Only violations the change adds block.
#   post  Advisory checks (NG101-NG106) against the file now on disk.
#
# lint.py prints findings on stdout and exits 2; its stderr is discarded so a
# crash stays silent. Findings are forwarded to stderr, which Claude Code
# shows to the model on exit 2. Every other outcome exits 0 — a plugin
# defect must never block a write.
#
# Usage: hook-lint.sh <pre|post>

MODE="${1:-}"
case "$MODE" in pre|post) ;; *) exit 0 ;; esac

FINDINGS=$(python3 -I -B "$(dirname "$0")/lint.py" "$MODE" 2>/dev/null)
if [ $? -eq 2 ] && [ -n "$FINDINGS" ]; then
  printf '%s\n\n' "$FINDINGS" >&2
  exit 2
fi
exit 0
