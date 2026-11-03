#!/usr/bin/env bash
# analyze_quality.sh <file> — structural complexity analysis for NG106.
# Prints one finding per line to stdout. Always exits 0.
# Usable standalone: bash scripts/analyze_quality.sh src/app/foo.component.ts

FILE="${1:-}"
[ -n "$FILE" ] && [ -r "$FILE" ] || exit 0
python3 -I -B "$(dirname "$0")/lint.py" quality "$FILE" 2>/dev/null
exit 0
