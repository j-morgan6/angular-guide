#!/usr/bin/env bash
# bash-guard.sh — Bash PreToolUse hook for angular-guide (BG001-BG006).
# The rules live in guard.py.
#
# guard.py prints findings on stdout and exits 2; its stderr is discarded so
# a crash stays silent. Findings are forwarded to stderr, which Claude Code
# shows to the model on exit 2. Every other outcome exits 0.

FINDINGS=$(python3 -I -B "$(dirname "$0")/guard.py" 2>/dev/null)
if [ $? -eq 2 ] && [ -n "$FINDINGS" ]; then
  printf '%s\n\n' "$FINDINGS" >&2
  exit 2
fi
exit 0
