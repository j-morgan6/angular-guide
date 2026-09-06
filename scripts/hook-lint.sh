#!/usr/bin/env bash
# hook-lint.sh — Write|Edit hook checks for angular-guide.
# Called by the PreToolUse and PostToolUse hooks in hooks/hooks.json.
#
# Claude Code feeds a hook's STDERR to the model on exit code 2 (stdout is
# reserved for JSON hook output), so every finding here is written to stderr.
#
# Modes:
#   pre   Blocking checks (NG001-NG018) against the EFFECTIVE post-edit content:
#         for Write that is the pending `content`; for Edit it is the on-disk
#         file with `old_string` replaced by `new_string`, so an edit that
#         introduces a violation into existing context is caught too.
#         Exit 2 blocks the write and the model sees the findings.
#   post  Advisory checks (NG101-NG106) against the file now on disk. Exit 2
#         feeds the findings back to the model without undoing the write.
#
# Every unexpected condition exits 0. A plugin defect must never block a write.
#
# Usage: hook-lint.sh <pre|post>

set -u

MODE="${1:-}"
INPUT=$(cat)

case "$MODE" in pre|post) ;; *) exit 0 ;; esac

DATA=$(printf '%s' "$INPUT" | python3 -c '
import json, sys, os, tempfile

mode = sys.argv[1]
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
ti = d.get("tool_input", {}) or {}
fp = ti.get("file_path", "") or ""
if not fp:
    sys.exit(0)

if mode == "post":
    print(fp); print(fp); sys.exit(0)

if ti.get("content") is not None:
    content = ti["content"]
else:
    base = ""
    try:
        with open(fp, encoding="utf-8", errors="ignore") as f:
            base = f.read()
    except Exception:
        pass
    old = ti.get("old_string") or ""
    new = ti.get("new_string") or ""
    if old and old in base:
        content = base.replace(old, new) if ti.get("replace_all") else base.replace(old, new, 1)
    elif new:
        # old_string was not found on disk. Claude Code validates old_string
        # against the real file before ever invoking Edit, so this path is
        # defensive-only and should not be reachable in practice. Appending
        # new_string (rather than silently linting only the unchanged base)
        # is the safe default: it guarantees the substance of the edit is
        # still covered by the checks below instead of being dropped.
        content = base + "\n" + new
    else:
        content = base

fd, tp = tempfile.mkstemp(prefix="angular-guide-hook-")
with os.fdopen(fd, "w") as f:
    f.write(content)
print(fp); print(tp)
' "$MODE" 2>/dev/null)

FILE_PATH=$(printf '%s\n' "$DATA" | sed -n '1p')
CONTENT_PATH=$(printf '%s\n' "$DATA" | sed -n '2p')

CODE_PATH=""
# NEVER remove CODE_PATH if it turned out to alias FILE_PATH or CONTENT_PATH
# (see the CODE_PATH assignment below) — deleting the user's real source file
# would be catastrophic, so this guard is unconditional, not best-effort.
cleanup() {
  if [ -n "${CODE_PATH:-}" ] && [ "$CODE_PATH" != "$FILE_PATH" ] && [ "$CODE_PATH" != "${CONTENT_PATH:-}" ]; then
    rm -f "$CODE_PATH"
  fi
  if [ "$MODE" = "pre" ] && [ -n "${CONTENT_PATH:-}" ] && [ "$CONTENT_PATH" != "$FILE_PATH" ]; then
    rm -f "$CONTENT_PATH"
  fi
  return 0
}
trap cleanup EXIT

[ -n "$FILE_PATH" ] && [ -r "$CONTENT_PATH" ] || exit 0

EXT=$(printf '%s' "${FILE_PATH##*.}" | tr '[:upper:]' '[:lower:]')
case "$EXT" in ts|html) ;; *) exit 0 ;; esac

# ------------------------------------------------------------------ profile
# Walk up from the edited file (NOT $PWD — the hook's cwd may differ from the
# workspace root) to find the profile written by detect_project.sh.
find_profile() {
  local dir
  dir="$(cd "$(dirname "$FILE_PATH")" 2>/dev/null && pwd)" || dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.angular-guide-project.json" ]; then
      echo "$dir/.angular-guide-project.json"; return 0
    fi
    dir="$(dirname "$dir")"
  done
  [ -f "$PWD/.angular-guide-project.json" ] && echo "$PWD/.angular-guide-project.json"
  return 0
}
PROFILE=$(find_profile 2>/dev/null || true)

# gate <boolean-key> — true only when the profile explicitly says true.
# A missing profile or unknown version means the rule is SKIPPED, never guessed.
gate() {
  [ -n "${PROFILE:-}" ] && [ -f "$PROFILE" ] || return 1
  grep -q "\"$1\"[[:space:]]*:[[:space:]]*true" "$PROFILE" 2>/dev/null
}

# gate_eq <string-key> <value>
gate_eq() {
  [ -n "${PROFILE:-}" ] && [ -f "$PROFILE" ] || return 1
  grep -q "\"$1\"[[:space:]]*:[[:space:]]*\"$2\"" "$PROFILE" 2>/dev/null
}

is_spec() { printf '%s' "$FILE_PATH" | grep -qE '\.spec\.ts$|\.test\.ts$'; }

FINDINGS=()
add() { FINDINGS+=("$1"); }

# Content with // and /* */ comments stripped, so rules never fire on prose.
# CODE_PATH must only ever be a path WE created via mktemp — never CONTENT_PATH
# or FILE_PATH. If mktemp fails (e.g. a full or unwritable TMPDIR), we must
# NOT fall back to writing into CONTENT_PATH: in post mode CONTENT_PATH IS
# FILE_PATH (the user's real source file), so writing the stripped output
# there would mangle it, and the cleanup trap would then delete it outright.
# Instead, degrade to reading CONTENT_PATH unmodified — matching gets
# slightly noisier (may fire on text inside comments) but the real file is
# never opened for writing and never removed.
CODE_TMP=$(mktemp -t angular-guide-code 2>/dev/null) || CODE_TMP=""
if [ -n "$CODE_TMP" ]; then
  CODE_PATH="$CODE_TMP"
  python3 -c '
import sys

def strip_comments(src):
    out = []
    i, n = 0, len(src)
    in_str = None   # None, or the quote character ("\x27", "\"", "`") we are inside
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        if c in ("\"", "\x27", "`"):
            in_str = c
            out.append(c)
            i += 1
            continue
        if c == "/" and nxt == "/":
            i += 2
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            i += 2
            while i < n and not (src[i] == "*" and i + 1 < n and src[i + 1] == "/"):
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)

src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
open(sys.argv[2], "w").write(strip_comments(src))
' "$CONTENT_PATH" "$CODE_PATH" 2>/dev/null || cp "$CONTENT_PATH" "$CODE_PATH" 2>/dev/null
else
  CODE_PATH="$CONTENT_PATH"
fi

# ------------------------------------------------------------- pre: NG001-018

check_ng007() {
  if grep -qE '(:[[:space:]]*any\b|\bas[[:space:]]+any\b|<any>)' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG007: `any` type detected.
   💡 Fix: Use `unknown` when the type is genuinely uncertain and narrow it, or give the value its real type. `any` disables every check TypeScript exists to provide.
   See: angular-essentials skill'
  fi
}

# -------------------------------------------------------------------- driver

if [ "$MODE" = "pre" ]; then
  check_ng007
else
  :
fi

if [ ${#FINDINGS[@]} -gt 0 ]; then
  for f in "${FINDINGS[@]}"; do
    printf '%s\n\n' "$f" >&2
  done
  exit 2
fi
exit 0
