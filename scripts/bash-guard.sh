#!/usr/bin/env bash
# bash-guard.sh — Bash PreToolUse hook for angular-guide (BG001-BG006).
# Findings go to stderr; exit 2 blocks the command. Fails open on any error.

set -u

INPUT=$(cat)

CMD=$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
print((d.get("tool_input", {}) or {}).get("command", "") or "")
' 2>/dev/null)

[ -n "${CMD:-}" ] || exit 0

find_profile() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.angular-guide-project.json" ]; then
      echo "$dir/.angular-guide-project.json"; return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 0
}
PROFILE=$(find_profile 2>/dev/null || true)

profile_str() { # <key> — echoes the string value, empty if unavailable
  [ -n "${PROFILE:-}" ] && [ -f "$PROFILE" ] || return 0
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$PROFILE" 2>/dev/null \
    | sed -E 's/.*"([^"]*)"$/\1/' | head -1
}

FINDINGS=()
add() { FINDINGS+=("$1"); }

# BG001 — force push to the default branch
FORCE_PUSH=0
if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+push' \
   && printf '%s' "$CMD" | grep -qE '(--force([^-]|$)|[[:space:]]-f([[:space:]]|$))'; then
  FORCE_PUSH=1
fi

if [ "$FORCE_PUSH" = "1" ]; then
  NAMES_DEFAULT_BRANCH=0
  if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(main|master)([[:space:]]|$)'; then
    NAMES_DEFAULT_BRANCH=1
  fi

  # Tokenize the arguments after "push" — needed both to check refspec
  # destinations (below) and, if nothing named the default branch yet, to
  # tell whether any branch was named at all. Disable pathname expansion
  # first and restore whatever it was before: an unquoted `for tok in
  # $PUSH_ARGS` would otherwise glob-expand a bare `*` (or any other
  # metacharacter) in the analyzed command text against THIS script's cwd,
  # inflating the word count and defeating the "no refspec named" inference
  # below — the guard must not be foolable by its own tokenizer.
  PUSH_ARGS=$(printf '%s' "$CMD" | sed -E 's/^.*git[[:space:]]+push//')
  case $- in *f*) _PREV_NOGLOB=1 ;; *) _PREV_NOGLOB=0 ;; esac
  set -f
  POSITIONAL=0
  for tok in $PUSH_ARGS; do
    case "$tok" in
      -*) ;;
      *:*)
        POSITIONAL=$((POSITIONAL + 1))
        # A colon refspec is <src>:<dst> — what a force push actually
        # overwrites is the destination, not the source, so a source that
        # merely shares a name with the default branch (main:feature/x)
        # must NOT be treated as targeting it.
        dst="${tok#*:}"
        if [ "$dst" = "main" ] || [ "$dst" = "master" ]; then
          NAMES_DEFAULT_BRANCH=1
        fi
        ;;
      *) POSITIONAL=$((POSITIONAL + 1)) ;;
    esac
  done
  [ "$_PREV_NOGLOB" = "1" ] || set +f

  if [ "$NAMES_DEFAULT_BRANCH" != "1" ] && [ "$POSITIONAL" -le 1 ]; then
    # Zero non-flag words (no remote) or one (remote only, no refspec) means
    # no branch was named, so the push targets whatever branch is currently
    # checked out. Fails open: a detached HEAD or a non-repo directory makes
    # `git symbolic-ref` fail, CURRENT_BRANCH stays empty, and neither
    # comparison below matches.
    CURRENT_BRANCH=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)
    if [ "$CURRENT_BRANCH" = "main" ] || [ "$CURRENT_BRANCH" = "master" ]; then
      NAMES_DEFAULT_BRANCH=1
    fi
  fi

  if [ "$NAMES_DEFAULT_BRANCH" = "1" ]; then
    add '🚫 BG001: Force push to the default branch rewrites shared history.
   💡 Fix: Use --force-with-lease, and push to a feature branch instead.'
  fi
fi

# BG002 — ng build --prod (flag removed in Angular 12)
if printf '%s' "$CMD" | grep -qE 'ng[[:space:]]+build' \
   && printf '%s' "$CMD" | grep -qE -- '--prod([[:space:]]|$)'; then
  add '🚫 BG002: `ng build --prod` — the flag was removed in Angular 12.
   💡 Fix: Run `ng build`. Production is the default configuration.'
fi

# BG003 — package manager mismatching the lockfile
PM=$(profile_str package_manager)
if [ -n "$PM" ]; then
  for other in npm pnpm yarn bun; do
    [ "$other" = "$PM" ] && continue
    if printf '%s' "$CMD" | grep -qE "(^|[;&|])[[:space:]]*$other[[:space:]]+(install|i|add|ci)([[:space:]]|$)"; then
      add "🚫 BG003: \`$other\` invoked but this workspace uses \`$PM\` (per its lockfile).
   💡 Fix: Use \`$PM\` — mixing package managers produces a second lockfile and divergent dependency trees."
      break
    fi
  done
fi

# BG004 — ng test without --watch=false hangs an agent session
if printf '%s' "$CMD" | grep -qE '(^|[[:space:]&|;])ng[[:space:]]+test([[:space:]]|$)' \
   && ! printf '%s' "$CMD" | grep -qE -- '--watch[= ]false|--no-watch|--run([[:space:]=]|$)|--ci([[:space:]=]|$)'; then
  add '🚫 BG004: `ng test` runs in watch mode by default and will hang this session.
   💡 Fix: Run `ng test --watch=false` (Karma) or `ng test --run` (Vitest).'
fi

# BG005 — deleting node_modules together with the lockfile
# Note the asymmetry with BG003's command-position anchor: `rm` is frequently
# prefix-wrapped (sudo, time, xargs, ...), so a strict command-position anchor
# would miss `sudo rm -rf ...` — the exact destructive invocation this rule
# exists to catch. A left word-boundary (preceding char not alphanumeric)
# rejects an `rm` embedded in a longer word (e.g. `confirm -rf ...`) without
# losing wrapped invocations. Package manager names in BG003 don't have this
# prefix-wrapping pattern, so the looser word-boundary test there would just
# fire on prose instead — hence the different anchors for the two rules.
if printf '%s' "$CMD" | grep -qE "(^|[^a-zA-Z0-9])rm[[:space:]]+-[a-zA-Z]*r" \
   && printf '%s' "$CMD" | grep -qE '(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lock)'; then
  add '🚫 BG005: Deleting the lockfile discards every pinned transitive version.
   💡 Fix: Delete node_modules alone and reinstall. Only remove the lockfile when deliberately re-resolving the whole dependency tree.'
fi

# BG006 — ng update --force skips the checks that make updating safe
if printf '%s' "$CMD" | grep -qE 'ng[[:space:]]+update' \
   && printf '%s' "$CMD" | grep -qE -- '--force([[:space:]]|$)'; then
  add '🚫 BG006: `ng update --force` bypasses peer-dependency and migration checks.
   💡 Fix: Resolve the reported incompatibilities, or update one package at a time. Run `ng update` without --force first to see what it objects to.'
fi

if [ ${#FINDINGS[@]} -gt 0 ]; then
  for f in "${FINDINGS[@]}"; do
    printf '%s\n\n' "$f" >&2
  done
  exit 2
fi
exit 0
