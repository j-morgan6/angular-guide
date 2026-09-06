#!/usr/bin/env bash
# Test suite for angular-guide.
# Run: bash tests/run-tests.sh
#
# Contract under test:
#   - All hook feedback goes to STDERR (Claude Code feeds stderr to the model
#     on exit 2; stdout is reserved for JSON hook output).
#   - Every script fails open: unexpected conditions exit 0, never non-zero.
#   - Version-gated rules are SKIPPED when the version is unknown, never guessed.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DETECT="$ROOT/scripts/detect_project.sh"
HOOK_LINT="$ROOT/scripts/hook-lint.sh"
BASH_GUARD="$ROOT/scripts/bash-guard.sh"
SUBAGENT="$ROOT/scripts/subagent-rules.sh"

PASS=0
FAIL=0
CODE=""
OUT=""
ERR=""
FAILED_NAMES=()

# run <stdin-json> <cmd...>  — captures OUT, ERR, CODE
run() {
  local stdin_data="$1"; shift
  local out_f err_f
  out_f=$(mktemp); err_f=$(mktemp)
  printf '%s' "$stdin_data" | "$@" >"$out_f" 2>"$err_f"
  CODE=$?
  OUT=$(cat "$out_f"); ERR=$(cat "$err_f")
  rm -f "$out_f" "$err_f"
}

check() { # <name> <condition-description> <pass:0/1>
  local name="$1" desc="$2" ok="$3"
  if [ "$ok" = "0" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_NAMES+=("$name: $desc")
    echo "FAIL $name — $desc"
    echo "     exit=$CODE"
    echo "     stdout: $(printf '%s' "$OUT" | head -3)"
    echo "     stderr: $(printf '%s' "$ERR" | head -3)"
  fi
}

expect() { # <name> <expected-exit> <stream:err|out|none> <substring-or-empty>
  local name="$1" want_code="$2" stream="$3" substr="${4:-}"
  local ok=0
  [ "$CODE" = "$want_code" ] || ok=1
  case "$stream" in
    err)  printf '%s' "$ERR" | grep -qF "$substr" || ok=1 ;;
    out)  printf '%s' "$OUT" | grep -qF "$substr" || ok=1 ;;
    none) [ -z "$OUT$ERR" ] || ok=1 ;;
  esac
  check "$name" "want exit=$want_code ${stream}~'$substr'" "$ok"
}

# JSON helpers — build the tool-input payloads Claude Code sends to hooks
write_json() { # file_path content
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"
}
edit_json() { # file_path old new
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3]}}))' "$1" "$2" "$3"
}
bash_json() { # command
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
}

# ng_workspace <dir> <angular-version> [extra-devdeps-json]
# Creates a minimal Angular workspace for detection/gating fixtures.
ng_workspace() {
  local dir="$1" ver="$2" extra="${3:-}"
  mkdir -p "$dir"
  printf '{"version":1,"projects":{"app":{"projectType":"application","root":""}}}\n' > "$dir/angular.json"
  python3 -c '
import json,sys
dev = {"@angular/cli": "^"+sys.argv[2]}
if sys.argv[3]:
    dev.update(json.loads(sys.argv[3]))
json.dump({"name":"fixture","dependencies":{"@angular/core":"^"+sys.argv[2]},"devDependencies":dev},
          open(sys.argv[1]+"/package.json","w"))
' "$dir" "$ver" "$extra"
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

###############################################################################
echo "== manifests =="
###############################################################################

VERSION_FILE=$(cat "$ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')

M1_OK=0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || M1_OK=1
check M1-plugin-json-parses "plugin.json is valid JSON" "$M1_OK"

M2_OK=0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/.claude-plugin/marketplace.json" 2>/dev/null || M2_OK=1
check M2-marketplace-json-parses "marketplace.json is valid JSON" "$M2_OK"

M3_OK=0
PJ_VER=$(python3 -c 'import json;print(json.load(open("'"$ROOT"'/.claude-plugin/plugin.json"))["version"])' 2>/dev/null)
MP_VER=$(python3 -c 'import json;print(json.load(open("'"$ROOT"'/.claude-plugin/marketplace.json"))["plugins"][0]["version"])' 2>/dev/null)
[ -n "$VERSION_FILE" ] && [ "$PJ_VER" = "$VERSION_FILE" ] && [ "$MP_VER" = "$VERSION_FILE" ] || M3_OK=1
check M3-versions-agree "VERSION == plugin.json == marketplace.json (got '$VERSION_FILE'/'$PJ_VER'/'$MP_VER')" "$M3_OK"

M4_OK=0
python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["name"]=="angular-guide", d["name"]
assert d["license"]=="MIT"
assert "angular" in d["keywords"]
' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || M4_OK=1
check M4-plugin-identity "name=angular-guide, MIT, keywords include angular" "$M4_OK"

###############################################################################
echo
echo "== detect_project.sh =="
###############################################################################

# D1: v22 workspace — all v22 gates on
WORK="$TMPROOT/d1"; ng_workspace "$WORK" "22.0.1"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D1_OK=0
grep -q '"angular_major": 22' .angular-guide-project.json 2>/dev/null || D1_OK=1
grep -q '"onpush_default": true' .angular-guide-project.json 2>/dev/null || D1_OK=1
grep -q '"signal_forms_available": true' .angular-guide-project.json 2>/dev/null || D1_OK=1
grep -q '"service_decorator_available": true' .angular-guide-project.json 2>/dev/null || D1_OK=1
grep -q '"standalone_default": true' .angular-guide-project.json 2>/dev/null || D1_OK=1
check D1-v22-gates "v22 workspace sets all v22 gates true" "$D1_OK"

# D2: v21 workspace — onpush/signal-forms/@Service OFF, standalone ON
WORK="$TMPROOT/d2"; ng_workspace "$WORK" "21.2.0"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D2_OK=0
grep -q '"angular_major": 21' .angular-guide-project.json 2>/dev/null || D2_OK=1
grep -q '"onpush_default": false' .angular-guide-project.json 2>/dev/null || D2_OK=1
grep -q '"signal_forms_available": false' .angular-guide-project.json 2>/dev/null || D2_OK=1
grep -q '"standalone_default": true' .angular-guide-project.json 2>/dev/null || D2_OK=1
check D2-v21-gates "v21 leaves v22-only gates false, standalone true" "$D2_OK"

# D3: v20 workspace
WORK="$TMPROOT/d3"; ng_workspace "$WORK" "20.0.0"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D3_OK=0
grep -q '"angular_major": 20' .angular-guide-project.json 2>/dev/null || D3_OK=1
grep -q '"standalone_default": true' .angular-guide-project.json 2>/dev/null || D3_OK=1
check D3-v20-gates "v20 sets standalone_default true" "$D3_OK"

# D4: not an Angular workspace — exit 0, no cache, no output
WORK="$TMPROOT/d4"; mkdir -p "$WORK"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D4_OK=0
[ "$CODE" = "0" ] || D4_OK=1
[ ! -f .angular-guide-project.json ] || D4_OK=1
check D4-non-angular-inert "no angular.json → exit 0, no cache written" "$D4_OK"

# D5: zone.js present → zoneless false; absent → zoneless true
WORK="$TMPROOT/d5"; ng_workspace "$WORK" "22.0.0" '{"zone.js":"~0.15.0"}'; cd "$WORK" || exit 1
run "" bash "$DETECT"
D5_OK=0
grep -q '"zoneless": false' .angular-guide-project.json 2>/dev/null || D5_OK=1
check D5-zonejs-present "zone.js dependency → zoneless false" "$D5_OK"

WORK="$TMPROOT/d5b"; ng_workspace "$WORK" "22.0.0"; cd "$WORK" || exit 1
run "" bash "$DETECT"
D5B_OK=0
grep -q '"zoneless": true' .angular-guide-project.json 2>/dev/null || D5B_OK=1
check D5b-zonejs-absent "no zone.js → zoneless true" "$D5B_OK"

# D6: test runner detection
WORK="$TMPROOT/d6"; ng_workspace "$WORK" "22.0.0" '{"vitest":"^3.0.0"}'; cd "$WORK" || exit 1
run "" bash "$DETECT"
D6_OK=0
grep -q '"test_runner": "vitest"' .angular-guide-project.json 2>/dev/null || D6_OK=1
check D6-vitest "vitest devDependency detected" "$D6_OK"

WORK="$TMPROOT/d6b"; ng_workspace "$WORK" "21.0.0" '{"karma":"~6.4.0"}'; cd "$WORK" || exit 1
run "" bash "$DETECT"
D6B_OK=0
grep -q '"test_runner": "karma"' .angular-guide-project.json 2>/dev/null || D6B_OK=1
check D6b-karma "karma devDependency detected" "$D6B_OK"

# D7: unknown version → gates must be false, never guessed
WORK="$TMPROOT/d7"; mkdir -p "$WORK"; cd "$WORK" || exit 1
printf '{"version":1,"projects":{}}\n' > angular.json
printf '{"name":"x","dependencies":{}}\n' > package.json
run "" bash "$DETECT"
D7_OK=0
grep -q '"angular_major": "unknown"' .angular-guide-project.json 2>/dev/null || D7_OK=1
grep -q '"onpush_default": false' .angular-guide-project.json 2>/dev/null || D7_OK=1
grep -q '"standalone_default": false' .angular-guide-project.json 2>/dev/null || D7_OK=1
check D7-unknown-version "unknown version → every gate false, never guessed" "$D7_OK"

# D8: package manager from lockfile
WORK="$TMPROOT/d8"; ng_workspace "$WORK" "22.0.0"; cd "$WORK" || exit 1
touch pnpm-lock.yaml
run "" bash "$DETECT"
D8_OK=0
grep -q '"package_manager": "pnpm"' .angular-guide-project.json 2>/dev/null || D8_OK=1
check D8-pnpm-lockfile "pnpm-lock.yaml → package_manager pnpm" "$D8_OK"

# D9: detection runs from a nested subdirectory and finds the workspace root
WORK="$TMPROOT/d9"; ng_workspace "$WORK" "22.0.0"
mkdir -p "$WORK/src/app/feature"; cd "$WORK/src/app/feature" || exit 1
run "" bash "$DETECT"
D9_OK=0
[ -f "$WORK/.angular-guide-project.json" ] || D9_OK=1
check D9-walks-up "runs from nested dir, writes cache at workspace root" "$D9_OK"

# D10: announces to stdout for session context
D10_OK=0
printf '%s' "$OUT" | grep -q "Angular" || D10_OK=1
check D10-announces "emits a summary on stdout" "$D10_OK"

# D11: package.json range unresolvable, package-lock.json resolves the version
WORK="$TMPROOT/d11"; ng_workspace "$WORK" "22.0.1"; cd "$WORK" || exit 1
python3 -c '
import json
d = json.load(open("package.json"))
d["dependencies"]["@angular/core"] = "latest"
d["devDependencies"]["@angular/cli"] = "latest"
json.dump(d, open("package.json", "w"))
'
python3 -c '
import json
json.dump(
    {"name": "fixture", "lockfileVersion": 3,
     "packages": {"": {}, "node_modules/@angular/core": {"version": "22.0.1"}}},
    open("package-lock.json", "w"))
'
run "" bash "$DETECT"
D11_OK=0
grep -q '"angular_major": 22' .angular-guide-project.json 2>/dev/null || D11_OK=1
grep -q '"onpush_default": true' .angular-guide-project.json 2>/dev/null || D11_OK=1
check D11-package-lock-fallback "unresolvable package.json range, package-lock.json resolves version" "$D11_OK"

# D12: package.json range unresolvable, yarn.lock resolves the version
WORK="$TMPROOT/d12"; ng_workspace "$WORK" "22.0.1"; cd "$WORK" || exit 1
python3 -c '
import json
d = json.load(open("package.json"))
d["dependencies"]["@angular/core"] = "latest"
d["devDependencies"]["@angular/cli"] = "latest"
json.dump(d, open("package.json", "w"))
'
printf '%s\n' \
  '"@angular/core@^22.0.0":' \
  '  version "22.0.1"' \
  '  resolved "https://registry.yarnpkg.com/@angular/core/-/core-22.0.1.tgz"' \
  > yarn.lock
run "" bash "$DETECT"
D12_OK=0
grep -q '"angular_major": 22' .angular-guide-project.json 2>/dev/null || D12_OK=1
grep -q '"onpush_default": true' .angular-guide-project.json 2>/dev/null || D12_OK=1
check D12-yarn-lock-fallback "unresolvable package.json range, yarn.lock resolves version" "$D12_OK"

# D13: package.json range unresolvable, pnpm-lock.yaml resolves the version
WORK="$TMPROOT/d13"; ng_workspace "$WORK" "22.0.1"; cd "$WORK" || exit 1
python3 -c '
import json
d = json.load(open("package.json"))
d["dependencies"]["@angular/core"] = "latest"
d["devDependencies"]["@angular/cli"] = "latest"
json.dump(d, open("package.json", "w"))
'
printf "packages:\n  '@angular/core@22.0.1':\n" > pnpm-lock.yaml
run "" bash "$DETECT"
D13_OK=0
grep -q '"angular_major": 22' .angular-guide-project.json 2>/dev/null || D13_OK=1
grep -q '"onpush_default": true' .angular-guide-project.json 2>/dev/null || D13_OK=1
check D13-pnpm-lock-fallback "unresolvable package.json range, pnpm-lock.yaml resolves version" "$D13_OK"

###############################################################################
echo
echo "== hook-lint.sh pipeline =="
###############################################################################

WORK="$TMPROOT/hl"; ng_workspace "$WORK" "22.0.0"; cd "$WORK" || exit 1
mkdir -p "$WORK/src/app"
bash "$DETECT" >/dev/null 2>&1

# H1: Write payload — violation in pending content is caught
run "$(write_json "$WORK/src/app/a.ts" 'const x: any = 1;')" bash "$HOOK_LINT" pre
expect H1-write-any 2 err "NG007"

# H2: clean content passes silently
run "$(write_json "$WORK/src/app/a.ts" 'const x: number = 1;')" bash "$HOOK_LINT" pre
expect H2-clean-passes 0 none ""

# H3: Edit — violation introduced ONLY by new_string is caught against on-disk context
cat > "$WORK/src/app/b.ts" <<'EOF'
export function f(input: string) {
  return input.trim();
}
EOF
run "$(edit_json "$WORK/src/app/b.ts" 'input: string' 'input: any')" bash "$HOOK_LINT" pre
expect H3-edit-introduces 2 err "NG007"

# H4: Edit that REMOVES the violation must not report it
cat > "$WORK/src/app/c.ts" <<'EOF'
export function g(input: any) {
  return input;
}
EOF
run "$(edit_json "$WORK/src/app/c.ts" 'input: any' 'input: unknown')" bash "$HOOK_LINT" pre
expect H4-edit-removes 0 none ""

# H5: non-Angular extension ignored
run "$(write_json "$WORK/notes.md" 'const x: any = 1;')" bash "$HOOK_LINT" pre
expect H5-ignores-md 0 none ""

# H6: malformed stdin fails open
run 'not json at all' bash "$HOOK_LINT" pre
expect H6-malformed-json 0 none ""

# H7: unknown mode fails open
run "$(write_json "$WORK/src/app/a.ts" 'const x: any = 1;')" bash "$HOOK_LINT" bogus
expect H7-unknown-mode 0 none ""

# H8: missing file_path fails open
run '{"tool_name":"Write","tool_input":{}}' bash "$HOOK_LINT" pre
expect H8-no-filepath 0 none ""

# H9: findings go to stderr, never stdout
run "$(write_json "$WORK/src/app/a.ts" 'const x: any = 1;')" bash "$HOOK_LINT" pre
H9_OK=0
[ -z "$OUT" ] || H9_OK=1
check H9-stderr-only "findings on stderr, stdout empty" "$H9_OK"

# H10: comments are stripped before matching — no fire on prose
run "$(write_json "$WORK/src/app/d.ts" 'const company = "acme"; // takes any value')" bash "$HOOK_LINT" pre
expect H10-comment-stripped 0 none ""

# H11: a failing `mktemp` (e.g. full/unwritable TMPDIR) in post mode must never
# mangle or delete the real source file. Shadow `mktemp` on PATH with a stub
# that always fails, rather than relying on TMPDIR/permissions tricks that
# some platforms' mktemp ignores for `-t`.
FAKEBIN="$TMPROOT/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/mktemp" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$FAKEBIN/mktemp"

WORK11="$TMPROOT/hl11"; mkdir -p "$WORK11/src/app"
cat > "$WORK11/src/app/e.ts" <<'EOF'
export const x: any = 1;
EOF
ORIG_H11=$(cat "$WORK11/src/app/e.ts")
run "$(write_json "$WORK11/src/app/e.ts" '')" env PATH="$FAKEBIN:$PATH" bash "$HOOK_LINT" post
H11_OK=0
[ "$CODE" = "0" ] || H11_OK=1
[ -f "$WORK11/src/app/e.ts" ] || H11_OK=1
[ "$(cat "$WORK11/src/app/e.ts" 2>/dev/null)" = "$ORIG_H11" ] || H11_OK=1
check H11-mktemp-fail-preserves-file "post-mode mktemp failure must never mangle or delete the source file" "$H11_OK"

# H12: a `//` inside a string literal is not a comment start — the violation
# after it on the same line must still be caught.
run "$(write_json "$WORK/src/app/a.ts" 'const label = "a // b"; const y: any = 1;')" bash "$HOOK_LINT" pre
expect H12-string-slash-not-comment 2 err "NG007"

# H13: a URL inside a string must not be mangled — code after it still lints.
run "$(write_json "$WORK/src/app/a.ts" 'const url = "https://x"; const bad: any = 4;')" bash "$HOOK_LINT" pre
expect H13-url-in-string-safe 2 err "NG007"

###############################################################################
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { printf '  - %s\n' "${FAILED_NAMES[@]}"; exit 1; }
exit 0
