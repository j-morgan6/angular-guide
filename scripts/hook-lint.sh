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

# The fp/tp handoff below is NOT done via a two-line stdout capture: a `$()`
# command substitution cannot hold a NUL byte (bash truncates the captured
# string at the first one), which is exactly why NUL is a safe field
# separator for filesystem paths -- a legitimate path can never contain one.
# So the two paths are written NUL-delimited into a small meta file created
# entirely by this script (its path is never attacker-influenced), and read
# back from that file with `read -d ''`, not through a captured string.
# (This is the fix for the second instance of this bug class in this file;
# the first, a plain-newline split of a two-line stdout protocol, was fixed
# in c805f35. See META_TMP below and the `file_path` newline rejection
# inside the python pass -- that rejection happens before any temp file for
# the content is ever created.)
META_TMP=$(mktemp "${TMPDIR:-/tmp}/angular-guide-meta.XXXXXX" 2>/dev/null) || exit 0

printf '%s' "$INPUT" | python3 -c '
import json, sys, os, tempfile

mode = sys.argv[1]
meta_path = sys.argv[2]
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
ti = d.get("tool_input", {}) or {}
fp = ti.get("file_path", "") or ""
if not fp:
    sys.exit(0)

# file_path is model-authored input, reachable from prompt injection with no
# rule needing to fire. A newline (or NUL) in it would corrupt the
# NUL-delimited protocol below (or, before this check existed, the older
# two-line stdout protocol) and could smuggle a second, attacker-chosen path
# into CONTENT_PATH/CODE_PATH. Reject it outright, before touching any temp
# file — no legitimate path ever contains one.
if "\n" in fp or "\r" in fp or "\x00" in fp:
    sys.exit(0)

if mode == "post":
    tp = fp
else:
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

with open(meta_path, "w") as mf:
    mf.write(fp + "\0" + tp + "\0")
' "$MODE" "$META_TMP" 2>/dev/null

FILE_PATH=""
CONTENT_PATH=""
if [ -s "$META_TMP" ]; then
  exec 9< "$META_TMP"
  IFS= read -r -d '' FILE_PATH <&9 || true
  IFS= read -r -d '' CONTENT_PATH <&9 || true
  exec 9<&-
fi
rm -f "$META_TMP"

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

# I6: NG007/008/009/010/011/012/014/015 have no version gate, so without
# this check they would fire in any .ts file in any repository at all — a
# plain Express file in a non-Angular repo would get blocked. No cached
# profile anywhere up the tree means detect_project.sh never found an
# angular.json here, i.e. this is not an Angular workspace (or the plugin
# is simply inert here), so the whole hook does nothing.
#
# A profile that DOES exist but reports angular_major "unknown" is a
# different case: detect_project.sh found both angular.json and
# package.json, so this genuinely IS an Angular workspace — the version
# just couldn't be resolved. Ungated rules still apply there; only the
# version-gated rules stay off, exactly as before (gate()/gate_eq() already
# return false for an unresolved version, unchanged by this check).
[ -n "${PROFILE:-}" ] && [ -f "$PROFILE" ] || exit 0

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

# Version thresholds expressed through the profile's derived gates:
#   standalone_default is true exactly when major >= 20
#   onpush_default     is true exactly when major >= 22
gate_v20() { gate standalone_default; }
gate_v22() { gate onpush_default; }

# Content with // and /* */ comments stripped, so rules never fire on prose.
# CODE_PATH must only ever be a path WE created via mktemp — never CONTENT_PATH
# or FILE_PATH. If mktemp fails (e.g. a full or unwritable TMPDIR), we must
# NOT fall back to writing into CONTENT_PATH: in post mode CONTENT_PATH IS
# FILE_PATH (the user's real source file), so writing the stripped output
# there would mangle it, and the cleanup trap would then delete it outright.
# Instead, degrade to reading CONTENT_PATH unmodified — matching gets
# slightly noisier (may fire on text inside comments) but the real file is
# never opened for writing and never removed.
CODE_TMP=$(mktemp "${TMPDIR:-/tmp}/angular-guide-code.XXXXXX" 2>/dev/null) || CODE_TMP=""
if [ -n "$CODE_TMP" ]; then
  CODE_PATH="$CODE_TMP"
  python3 -c '
import sys

def scan_delimited(src, i, opener_len, end_marker, out):
    # Skip content starting right after the opener (src[i:i+opener_len]),
    # looking for end_marker. If found, blank the content between (newlines
    # preserved for line-accounting) and return the index just past
    # end_marker. If end_marker is NEVER found anywhere in the rest of the
    # source -- an unterminated /* or <!-- -- swallowing everything after it
    # as "inside a comment" would silently disable every rule for the whole
    # rest of the file, which is a much worse failure mode than the syntax
    # error it reflects. So only the remainder of THIS LINE is treated as
    # commented; the newline itself is left for the caller to append
    # normally, and scanning resumes as usual from the next line.
    n = len(src)
    j = i + opener_len
    close = src.find(end_marker, j)
    if close != -1:
        for k in range(j, close):
            if src[k] == "\n":
                out.append("\n")
        return close + len(end_marker)
    nl = src.find("\n", j)
    return n if nl == -1 else nl

def strip_comments(src, is_html):
    out = []
    i, n = 0, len(src)
    in_str = None   # None, or the quote character ("\x27", "\"", "`") we are inside
    # in_tag is only meaningful for HTML content: true while scanning inside
    # a <tag ...> construct (between an opening "<" and its closing ">"), as
    # opposed to text content between tags.
    in_tag = False
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if in_str:
            # Inside a backtick (template-literal) string, an HTML comment
            # can still appear -- this is exactly where Angular inline
            # template markup lives -- so blank it here too, the same as
            # at the top level, instead of leaving it intact just because
            # it is inside a string.
            if in_str == "`" and src[i:i + 4] == "<!--":
                i = scan_delimited(src, i, 4, "-->", out)
                continue
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == in_str:
                in_str = None
            i += 1
            continue
        if src[i:i + 4] == "<!--":
            i = scan_delimited(src, i, 4, "-->", out)
            continue
        if is_html and c == "<" and (nxt.isalpha() or nxt in ("/", "!", "?")):
            # A bare "<" surrounded by whitespace/text ("1 < 2") is a
            # comparison in interpolated prose, not a tag opener -- only
            # treat it as one when followed by something an actual tag,
            # closing tag, doctype/comment, or processing instruction would
            # start with. Without this, "<p>1 < 2 and Don'"'"'t</p>" re-enters
            # in_tag on the bare "<", which then lets a following apostrophe
            # open a runaway string again (the same bug class as before,
            # just narrower).
            in_tag = True
            out.append(c)
            i += 1
            continue
        if is_html and c == ">" and in_tag:
            in_tag = False
            out.append(c)
            i += 1
            continue
        if c in ("\"", "\x27", "`"):
            # In HTML content, a quote is only a string delimiter INSIDE a
            # tag (an attribute value) -- at top level, in text content, a
            # bare apostrophe ("Don'"'"'t do this") is prose, not the start of a
            # string literal. Before this check, an apostrophe in HTML text
            # would flip in_str on with no matching close anywhere in the
            # file, trapping the scanner in "inside a string" for the rest
            # of the file -- which meant the <!-- --> handling above (only
            # reachable when not in_str) never ran again, so a real comment
            # later in the file was never blanked and its contents (e.g. a
            # commented-out *ngIf) fired a false positive. .ts content is
            # unaffected: is_html is only true for .html files, so a
            # top-level quote there still always opens a real string
            # literal, exactly as before.
            if c != "`" and is_html and not in_tag:
                out.append(c)
                i += 1
                continue
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
            i = scan_delimited(src, i, 2, "*/", out)
            continue
        out.append(c)
        i += 1
    return "".join(out)

src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
is_html = sys.argv[3] == "html"
open(sys.argv[2], "w").write(strip_comments(src, is_html))
' "$CONTENT_PATH" "$CODE_PATH" "$EXT" 2>/dev/null || cp "$CONTENT_PATH" "$CODE_PATH" 2>/dev/null
else
  CODE_PATH="$CONTENT_PATH"
fi

# Single-line copy of the code, for rules that must match across newlines.
COLLAPSED=$(tr '\n' ' ' < "$CODE_PATH" 2>/dev/null)

# ------------------------------------------------------------- pre: NG001-018

check_ng001() {
  gate_v20 || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE 'standalone:[[:space:]]*true' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG001: `standalone: true` in a decorator.
   💡 Fix: Delete the property. Standalone is the default since Angular v20 — writing it is redundant and signals a pre-v20 mental model.
   See: angular-essentials skill'
  fi
}

check_ng002() {
  gate_v20 || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -q '@NgModule' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG002: `@NgModule` declaration.
   💡 Fix: Use standalone components. Put shared providers in `providers` at bootstrap or on a route, and import components directly via the `imports` array.
   See: angular-essentials skill'
  fi
}

check_ng003() {
  gate_v20 || return 0
  if grep -qE '\*ngIf|\*ngFor|\*ngSwitch|\[ngSwitch\]' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG003: Legacy structural directive (`*ngIf` / `*ngFor` / `*ngSwitch`).
   💡 Fix: Use native control flow — `@if (cond) { }`, `@for (x of xs; track x.id) { }`, `@switch (v) { @case (a) { } }`. It needs no imports, is faster, and is the only supported form going forward.
   See: angular-essentials skill'
  fi
}

check_ng004() {
  gate_v20 || return 0
  [ "$EXT" = "ts" ] || return 0
  # Constructor-parameter properties are ordinary TypeScript and are common
  # in plain data/value classes (e.g. `constructor(private amount: number)`
  # on a Money class) that have nothing to do with Angular DI. The pattern
  # below is only an anti-pattern inside a class Angular actually manages,
  # so require an Angular class decorator somewhere in the file (matched
  # against $CODE_PATH, comments already stripped, so a commented-out
  # decorator does not count) before treating it as a finding.
  grep -qE '@(Component|Directive|Injectable|Service|Pipe|NgModule)\b' "$CODE_PATH" 2>/dev/null || return 0
  # Known limitation, left unfixed deliberately: a default-value expression
  # containing its own parens before the injected param, e.g.
  #   constructor(fn = () => 1, private http: HttpClient) {}
  # closes the `[^)]*` at the default value's `)` and the rule stays silent
  # (a false negative) instead of firing. Missed detections are recoverable
  # by review; blocked correct writes are not, so this is not tightened.
  if printf '%s' "$COLLAPSED" \
     | grep -qE 'constructor[[:space:]]*\([^)]*\b(private|public|protected|readonly)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*:'; then
    add '🚫 NG004: Constructor-parameter dependency injection.
   💡 Fix: Use the `inject()` function at field level:
     private readonly http = inject(HttpClient);
   It gives better type inference, works in field initializers and functional guards/interceptors, and avoids inheritance boilerplate.
   See: angular-essentials skill'
  fi
}

check_ng005() {
  gate_v20 || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE '@Input[[:space:]]*\(|@Output[[:space:]]*\(' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG005: `@Input()` / `@Output()` decorator.
   💡 Fix: Use the signal-based functions:
     readonly name = input.required<string>();
     readonly saved = output<Item>();
     readonly value = model<string>("");
   Signal inputs are readable in computed() without a lifecycle hook.
   See: angular-essentials skill'
  fi
}

check_ng006() {
  gate_v22 || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE 'changeDetection:[[:space:]]*ChangeDetectionStrategy\.OnPush' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG006: Explicit `changeDetection: ChangeDetectionStrategy.OnPush`.
   💡 Fix: Delete the property and its import. OnPush is the default strategy in Angular v22 — setting it explicitly is now noise.
   See: performance-and-zoneless skill'
  fi
}

check_ng008() {
  if grep -qE '\[ngClass\]|\[ngStyle\]|[[:space:]]ngClass=|[[:space:]]ngStyle=' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG008: `ngClass` / `ngStyle`.
   💡 Fix: Use native bindings — `[class.active]="isActive()"`, `[style.width.px]="w()"`, or `[class]="classRecord()"`. They need no import and avoid an extra directive instance per element.
   See: angular-essentials skill'
  fi
}

check_ng009() {
  [ "$EXT" = "ts" ] || return 0
  if grep -qE '@HostBinding|@HostListener' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG009: `@HostBinding` / `@HostListener` decorator.
   💡 Fix: Use the `host` object in the decorator metadata:
     @Component({ host: { "[class.active]": "isActive()", "(click)": "onClick($event)" } })
   It keeps host behaviour in one place and is statically analysable.
   See: angular-essentials skill'
  fi
}

check_ng007() {
  # Unlike NG005/NG009/NG011, this rule used to have no extension guard, so
  # it ran on .html templates too (e.g. "Pick a size: any of these will
  # do."). Restrict it to .ts, matching the other type-level rules.
  [ "$EXT" = "ts" ] || return 0
  local rc
  # `any` the TYPE must not fire on `any` the WORD sitting inside a string
  # literal (e.g. `"expected type: any but got string"`). $CODE_PATH already
  # has comments stripped but NOT string content blanked -- that stripper is
  # shared by all 24 rules and deliberately preserves string content (see
  # H12/H13: a `//` or `https://` inside a string must not be misread as a
  # comment start). So this reuses that same quote-tracking state machine as
  # a second, NG007-local pass that additionally blanks string-literal
  # content before matching, rather than writing an unrelated second
  # scanner. Same fail-open contract as NG010/NG012/NG013: read the exit
  # code directly, do not gate with `|| return 0`.
  python3 - "$CODE_PATH" <<'PY' 2>/dev/null
import re, sys
try:
    src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
    out = []
    i, n = 0, len(src)
    in_str = None  # None, or the quote character ("'", '"', "`") we are inside
    while i < n:
        c = src[i]
        if in_str:
            if c == "\\" and i + 1 < n:
                out.append("  ")
                i += 2
                continue
            if c == in_str:
                in_str = None
                out.append(c)
                i += 1
                continue
            out.append(c if c == "\n" else " ")
            i += 1
            continue
        if c in ("\"", "\x27", "`"):
            in_str = c
            out.append(c)
            i += 1
            continue
        out.append(c)
        i += 1
    blanked = "".join(out)
    hit = bool(re.search(r"(:\s*any\b|\bas\s+any\b|<any>)", blanked))
    sys.exit(1 if hit else 0)
except Exception:
    sys.exit(0)
PY
  rc=$?
  if [ "$rc" -eq 1 ]; then
    add '🚫 NG007: `any` type detected.
   💡 Fix: Use `unknown` when the type is genuinely uncertain and narrow it, or give the value its real type. `any` disables every check TypeScript exists to provide.
   See: angular-essentials skill'
  fi
}

check_ng010() {
  [ "$EXT" = "ts" ] || return 0
  is_spec && return 0
  local rc
  # For each .subscribe( call, inspect the chain back to the start of its
  # statement. A chain carrying takeUntilDestroyed (or an explicit take/first
  # completion operator) is considered self-terminating.
  #
  # The python pass wraps its logic in try/except and only ever exits 0 or 1
  # itself: 1 means "found a bare subscribe", 0 means "clean or the pass
  # errored" (fail-open). Do NOT gate this invocation with `|| return 0` --
  # sys.exit(1) is a real, expected exit code here (the violation signal),
  # and `||` would treat it identically to a crash and swallow every finding.
  python3 - "$CODE_PATH" <<'PY' 2>/dev/null
import re, sys
try:
    src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
    SAFE = ("takeUntilDestroyed", "takeUntil(", "take(", "first(", "firstValueFrom", "lastValueFrom")
    hit = False
    for m in re.finditer(r"\.subscribe\s*\(", src):
        start = max(src.rfind(";", 0, m.start()), src.rfind("{", 0, m.start()),
                    src.rfind("}", 0, m.start()), src.rfind("=>", 0, m.start()))
        chain = src[start + 1:m.start()]
        if not any(s in chain for s in SAFE):
            hit = True
            break
    sys.exit(1 if hit else 0)
except Exception:
    sys.exit(0)
PY
  rc=$?
  if [ "$rc" -eq 1 ]; then
    add '🚫 NG010: `.subscribe()` with no teardown in its chain.
   💡 Fix: Prefer not subscribing at all — use the `async` pipe, `toSignal(obs$)`, or `httpResource()`. When you must subscribe, add teardown:
     obs$.pipe(takeUntilDestroyed(this.destroyRef)).subscribe(...)
   Manual subscriptions without teardown are the most common memory leak in Angular apps.
   See: rxjs-interop skill'
  fi
}

check_ng011() {
  [ "$EXT" = "ts" ] || return 0
  if grep -qE '\.mutate[[:space:]]*\(' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG011: `.mutate()` on a signal — the API was removed.
   💡 Fix: Use `set()` with a new value, or `update()` with a pure transform:
     this.items.update((xs) => [...xs, item]);
   Signals compare by reference, so in-place mutation would not notify readers.
   See: signals-essentials skill'
  fi
}

check_ng012() {
  [ "$EXT" = "ts" ] || return 0
  local rc
  # Same fail-open contract as NG010: the python pass exits 1 only for a
  # deliberately detected violation, 0 for clean or an internal error, and
  # the shell must read that exit code directly rather than via `|| return 0`.
  python3 - "$CODE_PATH" <<'PY' 2>/dev/null
import re, sys

def balanced_span(s, open_paren_index):
    # s[open_paren_index] is the "(" that opens the call; returns the index
    # just past its matching ")".
    depth, k, n = 0, open_paren_index, len(s)
    while k < n:
        if s[k] == "(":
            depth += 1
        elif s[k] == ")":
            depth -= 1
            if depth == 0:
                return k + 1
        k += 1
    return n

try:
    src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
    hit = False
    for m in re.finditer(r"\beffect\s*\(", src):
        j = balanced_span(src, m.end() - 1)
        body = src[m.end() - 1:j]

        # untracked() is Angular's documented escape hatch for reading (or,
        # here, writing) outside the reactive graph from inside an effect --
        # `effect(() => { untracked(() => this.b.set(v)); })` is the
        # sanctioned pattern, not the anti-pattern this rule exists to
        # catch. Find every untracked(...) call's balanced-paren span within
        # the effect body and exclude any .set(/.update( that falls inside
        # one of them.
        untracked_spans = []
        for um in re.finditer(r"\buntracked\s*\(", body):
            uend = balanced_span(body, um.end() - 1)
            untracked_spans.append((um.start(), uend))

        def in_untracked(pos):
            return any(a <= pos < b for a, b in untracked_spans)

        for sm in re.finditer(r"\.(set|update)\s*\(", body):
            if not in_untracked(sm.start()):
                hit = True
                break
        if hit:
            break
    sys.exit(1 if hit else 0)
except Exception:
    sys.exit(0)
PY
  rc=$?
  if [ "$rc" -eq 1 ]; then
    add '🚫 NG012: `effect()` writes a signal.
   💡 Fix: Effects are for side effects that leave the reactive graph — logging, third-party DOM, analytics. Derived state belongs in `computed()`; writable state derived from other signals belongs in `linkedSignal()`. Writing signals inside an effect creates feedback loops and re-entrant change detection. If you genuinely need to write from inside an effect, wrap that write in `untracked()` — NG012 excludes writes lexically inside an `untracked(...)` callback.
   See: signals-essentials skill'
  fi
}

check_ng013() {
  gate_v20 || return 0
  local rc
  # Same fail-open contract as NG010/NG012 -- read the python pass's exit
  # code directly; do not gate the invocation with `|| return 0`.
  #
  # The @for clause must be extracted with balanced-paren matching, not
  # `[^)]*` up to the first `)`: the near-universal `@for (x of xs(); track
  # x.id)` form calls a signal, so `[^)]*` would stop at the `)` that closes
  # `xs()` and never see `track` at all -- a false NG013 on the very pattern
  # this plugin exists to encourage.
  python3 - "$CODE_PATH" <<'PY' 2>/dev/null
import re, sys
try:
    src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
    hit = False
    for m in re.finditer(r"@for\s*\(", src):
        i = m.end() - 1
        depth, j, n = 0, i, len(src)
        while j < n:
            if src[j] == "(":
                depth += 1
            elif src[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        clause = src[i + 1:j]
        if "track" not in clause:
            hit = True
            break
    sys.exit(1 if hit else 0)
except Exception:
    sys.exit(0)
PY
  rc=$?
  if [ "$rc" -eq 1 ]; then
    add '🚫 NG013: `@for` without a `track` expression.
   💡 Fix: Add a stable identity — `@for (item of items(); track item.id) { }`. `track` is mandatory; without it Angular cannot reuse DOM nodes and rebuilds the whole list on every change.
   See: performance-and-zoneless skill'
  fi
}

check_ng014() {
  if grep -qE '\[innerHTML\]|\[outerHTML\]' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG014: `[innerHTML]` binding.
   💡 Fix: Render text with interpolation, or compose real components. If you must render untrusted markup, sanitize it server-side and render through a vetted component — Angular sanitizes `[innerHTML]` but the pattern still invites XSS as soon as someone reaches for bypassSecurityTrust.
   See: angular-essentials skill'
  fi
}

check_ng015() {
  [ "$EXT" = "ts" ] || return 0
  if grep -q 'bypassSecurityTrust' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG015: `bypassSecurityTrust*` call.
   💡 Fix: This disables Angular XSS protection for that value. Sanitize upstream and render normally. If a genuine trusted-value case exists, it belongs in one reviewed, narrowly-scoped helper — never inline in a component.
   See: angular-essentials skill'
  fi
}

check_ng016() {
  [ "$EXT" = "ts" ] || return 0
  printf '%s' "$FILE_PATH" | grep -qE '/environments?/|environment(\.[a-z]+)*\.ts$' || return 0
  local rc
  # Rewritten from two file-wide greps to a per-occurrence python scan:
  #   - The process.env/import.meta.env exemption used to be file-wide, so
  #     one unrelated env read anywhere in the file suppressed a real
  #     `apiKey: "sk-live-..."` on a completely different line. It now only
  #     exempts an occurrence that shares its OWN line with the env read.
  #   - A value that parses as a URL (e.g. `tokenEndpoint: "https://auth/
  #     token"`) is excluded outright -- a URL is not a secret, however
  #     secret-shaped its key name looks.
  # Same fail-open contract as NG010/012/013/007: read the exit code
  # directly, do not gate with `|| return 0`.
  python3 - "$CODE_PATH" <<'PY' 2>/dev/null
import re, sys
try:
    src = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
    pattern = re.compile(
        r'(?:key|secret|token|password|credential)[A-Za-z]*\s*:\s*(["\'])([^"\']*)\1',
        re.IGNORECASE,
    )
    url_re = re.compile(r'^[A-Za-z][A-Za-z0-9+.\-]*://')
    hit = False
    for line in src.splitlines():
        if "process.env" in line or "import.meta.env" in line:
            continue
        for m in pattern.finditer(line):
            value = m.group(2)
            if not value or url_re.match(value):
                continue
            hit = True
            break
        if hit:
            break
    sys.exit(1 if hit else 0)
except Exception:
    sys.exit(0)
PY
  rc=$?
  if [ "$rc" -eq 1 ]; then
    add '🚫 NG016: Secret-shaped value in an environment file.
   💡 Fix: `environment.ts` is compiled into the browser bundle — anything in it is public. Move the secret behind your backend and have the client call your API. Build-time injection does not help; the value still ships.
   See: angular-essentials skill'
  fi
}

check_ng017() {
  gate zoneless || return 0
  if grep -qE "(import|require).*['\"]zone\.js" "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG017: `zone.js` import in a zoneless workspace.
   💡 Fix: Remove the import. This app runs with `provideZonelessChangeDetection()`; loading zone.js re-introduces monkey-patching of every async API and negates the benefit.
   See: performance-and-zoneless skill'
  fi
}

check_ng018() {
  gate_eq test_runner vitest || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE '\bjasmine\.|\bjasmine\b[[:space:]]*\.' "$CODE_PATH" 2>/dev/null; then
    add '🚫 NG018: Jasmine API in a Vitest workspace.
   💡 Fix: Use the Vitest equivalents — `vi.fn()` for `jasmine.createSpy()`, `vi.spyOn()` for `spyOn()`, `expect.objectContaining()` for `jasmine.objectContaining()`. TestBed itself is unchanged.
   See: testing-essentials skill'
  fi
}

# ------------------------------------------------------------ post: NG101-106

check_ng101() {
  [ "$EXT" = "ts" ] || return 0
  printf '%s' "$FILE_PATH" | grep -qE 'routes?\.ts$|\.routes\.ts$|routing' || return 0
  if grep -qE '\bcomponent:[[:space:]]*[A-Z]' "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG101: Route declared with an eager `component:` reference.
   💡 Fix: Lazy-load it so the feature leaves the initial bundle:
     { path: "admin", loadComponent: () => import("./admin/admin-page").then((m) => m.AdminPage) }
   Eager routes are defensible for a small shell route — for a feature screen they are almost always a mistake.
   See: performance-and-zoneless skill'
  fi
}

check_ng102() {
  gate signal_forms_available || return 0
  [ "$EXT" = "ts" ] || return 0
  is_spec && return 0
  if grep -qE '\bFormBuilder\b|\bnew[[:space:]]+FormGroup\b|\bfb\.group\(' "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG102: Reactive Forms in a workspace where Signal Forms are stable.
   💡 Fix: Prefer Signal Forms for new forms on v22+ — form state is signals, so it composes with computed() and needs no valueChanges subscription. Staying on Reactive Forms is correct when extending an existing Reactive Forms screen; starting a new one there is not.
   See: angular-essentials skill'
  fi
}

check_ng103() {
  gate service_decorator_available || return 0
  [ "$EXT" = "ts" ] || return 0
  if grep -qE "@Injectable\([[:space:]]*\{[^}]*providedIn:[[:space:]]*['\"]root['\"]" "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG103: `@Injectable({ providedIn: "root" })`.
   💡 Fix: On v22+ use the `@Service` decorator — it is the same root-provided singleton with less ceremony:
     @Service()
     export class ItemStore {}
   See: state-management skill'
  fi
}

check_ng104() {
  # [^>]* (not [^>]+): an <img> whose ONLY attribute is a literal src, e.g.
  # `<img src="...">`, has no characters between the tag name and the space
  # before `src=`. Requiring one or more there (`+`) makes the single most
  # common case never match; `*` also matches when other attributes precede
  # src (e.g. `<img class="hero" src="...">`).
  #
  # Matched against $COLLAPSED, not $CODE_PATH: Prettier wraps long <img>
  # tags across multiple lines as a matter of course, and grep matches
  # line-by-line, so a line-based match on $CODE_PATH misses exactly the
  # long, attribute-heavy tags that most need optimizing. [^>]* still cannot
  # cross a `>`, so flattening to one line cannot produce a spurious match
  # spanning two adjacent tags.
  if printf '%s' "$COLLAPSED" | grep -qE '<img[^>]*[[:space:]]src=["'"'"']' 2>/dev/null; then
    add '⚠️  NG104: Static `<img src>` without NgOptimizedImage.
   💡 Fix: Import NgOptimizedImage and use `ngSrc` with explicit width/height (or `fill`):
     <img ngSrc="/assets/hero.png" width="800" height="600" alt="Hero">
   It adds lazy loading, srcset generation, and priority hints, and it prevents layout shift.
   See: performance-and-zoneless skill'
  fi
}

check_ng105() {
  [ "$EXT" = "ts" ] || return 0
  is_spec && return 0
  # A file is a component when its path ends .component.ts, or when its
  # comment-stripped content ($CODE_PATH, not the raw file) contains
  # @Component -- so a commented-out decorator cannot trigger this rule.
  printf '%s' "$FILE_PATH" | grep -qE '\.component\.ts$' || grep -q '@Component' "$CODE_PATH" 2>/dev/null || return 0
  if grep -qE '\b(document|window)\.[a-zA-Z]' "$CODE_PATH" 2>/dev/null; then
    add '⚠️  NG105: Direct `document` / `window` access in a component.
   💡 Fix: Use `viewChild()` signal queries for element access, `afterRenderEffect()` for DOM work that must run post-render, and inject `DOCUMENT` rather than reaching for the global. Direct globals break SSR, where neither exists.
   See: component-architecture skill'
  fi
}

check_ng106() {
  [ "$EXT" = "ts" ] || return 0
  is_spec && return 0
  local out
  out=$(bash "$(dirname "$0")/analyze_quality.sh" "$CONTENT_PATH" 2>/dev/null)
  # analyze_quality.sh inspects content; component-ness is decided by the real
  # filename, so re-check it here rather than trusting the temp file's name.
  printf '%s' "$FILE_PATH" | grep -qE '\.component\.ts$' || \
    grep -q '@Component' "$CODE_PATH" 2>/dev/null || return 0
  if [ -n "$out" ]; then
    add "⚠️  NG106: Component complexity.
   $out
   See: component-architecture skill"
  fi
}

# -------------------------------------------------------------------- driver

if [ "$MODE" = "pre" ]; then
  check_ng001
  check_ng002
  check_ng003
  check_ng004
  check_ng005
  check_ng006
  check_ng007
  check_ng008
  check_ng009
  check_ng010
  check_ng011
  check_ng012
  check_ng013
  check_ng014
  check_ng015
  check_ng016
  check_ng017
  check_ng018
else
  check_ng101
  check_ng102
  check_ng103
  check_ng104
  check_ng105
  check_ng106
fi

if [ ${#FINDINGS[@]} -gt 0 ]; then
  for f in "${FINDINGS[@]}"; do
    printf '%s\n\n' "$f" >&2
  done
  exit 2
fi
exit 0
