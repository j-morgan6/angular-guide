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
  python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"
}
edit_json() { # file_path old new
  python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":sys.argv[2],"new_string":sys.argv[3]}}))' "$1" "$2" "$3"
}
bash_json() { # command
  python3 -I -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"
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

# H11: a failing `mktemp` (e.g. full/unwritable TMPDIR) in post mode must
# never mangle or delete the real source file. Targets CODE_TMP specifically
# (the comment-stripped copy), not META_TMP (the fp/tp handoff file added by
# the C1 fix): the stub below only fails for a template containing
# "angular-guide-code" and delegates everything else (including META_TMP's
# "angular-guide-meta" template) to the real mktemp. If it failed
# unconditionally, hook-lint.sh would now exit at its very first mktemp call
# (META_TMP, before FILE_PATH/CONTENT_PATH are even known) and this fixture
# would pass vacuously without ever reaching the CODE_TMP-failure fallback
# path it exists to cover.
REAL_MKTEMP="$(command -v mktemp)"
FAKEBIN="$TMPROOT/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/mktemp" <<EOF
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    *angular-guide-code*) exit 1 ;;
  esac
done
exec "$REAL_MKTEMP" "\$@"
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
check H11-mktemp-fail-preserves-file "post-mode CODE_TMP mktemp failure must never mangle or delete the source file" "$H11_OK"

# H12: a `//` inside a string literal is not a comment start — the violation
# after it on the same line must still be caught.
run "$(write_json "$WORK/src/app/a.ts" 'const label = "a // b"; const y: any = 1;')" bash "$HOOK_LINT" pre
expect H12-string-slash-not-comment 2 err "NG007"

# H13: a URL inside a string must not be mangled — code after it still lints.
run "$(write_json "$WORK/src/app/a.ts" 'const url = "https://x"; const bad: any = 4;')" bash "$HOOK_LINT" pre
expect H13-url-in-string-safe 2 err "NG007"

###############################################################################
echo
echo "== bash-guard.sh =="
###############################################################################

WORK="$TMPROOT/bg"; ng_workspace "$WORK" "22.0.0"; cd "$WORK" || exit 1
touch pnpm-lock.yaml
bash "$DETECT" >/dev/null 2>&1

PUSH="git push"; FORCE="--force"; SHORTF="-f"

run "$(bash_json "$PUSH $FORCE origin main")" bash "$BASH_GUARD"
expect B1-force-push-main 2 err "BG001"

run "$(bash_json "$PUSH $SHORTF origin master")" bash "$BASH_GUARD"
expect B2-force-push-master 2 err "BG001"

run "$(bash_json "$PUSH ${FORCE}-with-lease origin feature/x")" bash "$BASH_GUARD"
expect B3-force-with-lease-ok 0 none ""

run "$(bash_json "$PUSH origin main")" bash "$BASH_GUARD"
expect B4-normal-push-ok 0 none ""

run "$(bash_json 'ng build --prod')" bash "$BASH_GUARD"
expect B5-ng-build-prod 2 err "BG002"

run "$(bash_json 'ng build')" bash "$BASH_GUARD"
expect B6-ng-build-ok 0 none ""

run "$(bash_json 'npm install')" bash "$BASH_GUARD"
expect B7-pm-mismatch 2 err "BG003"

run "$(bash_json 'pnpm install')" bash "$BASH_GUARD"
expect B8-pm-match-ok 0 none ""

run "$(bash_json 'ng test')" bash "$BASH_GUARD"
expect B9-ng-test-watch 2 err "BG004"

run "$(bash_json 'ng test --watch=false')" bash "$BASH_GUARD"
expect B10-ng-test-nowatch-ok 0 none ""

run "$(bash_json 'rm -rf node_modules pnpm-lock.yaml')" bash "$BASH_GUARD"
expect B11-nuke-lockfile 2 err "BG005"

run "$(bash_json 'rm -rf node_modules')" bash "$BASH_GUARD"
expect B12-rm-nodemodules-ok 0 none ""

run "$(bash_json 'ng update @angular/core --force')" bash "$BASH_GUARD"
expect B13-ng-update-force 2 err "BG006"

run 'not json' bash "$BASH_GUARD"
expect B14-malformed-fails-open 0 none ""

###############################################################################
echo
echo "== bash-guard.sh (BG001/BG003/BG004/BG005 hardening) =="
###############################################################################

# Real git repos with controlled branches, for the BG001 current-branch
# inference arm (an unqualified force push names no branch, so it pushes
# whichever branch is checked out).
GITMAIN="$TMPROOT/bg-git-main"; mkdir -p "$GITMAIN"
( cd "$GITMAIN" && git init -q -b main . ) >/dev/null 2>&1

GITFEAT="$TMPROOT/bg-git-feature"; mkdir -p "$GITFEAT"
( cd "$GITFEAT" && git init -q -b main . && git checkout -q -b feature/x ) >/dev/null 2>&1

GITNONE="$TMPROOT/bg-no-git"; mkdir -p "$GITNONE"

cd "$GITMAIN" || exit 1
run "$(bash_json "$PUSH $FORCE")" bash "$BASH_GUARD"
expect B15-unqualified-force-blocks-on-main 2 err "BG001"

cd "$GITFEAT" || exit 1
run "$(bash_json "$PUSH $FORCE")" bash "$BASH_GUARD"
expect B16-unqualified-force-ok-on-feature-branch 0 none ""

cd "$GITNONE" || exit 1
run "$(bash_json "$PUSH $FORCE")" bash "$BASH_GUARD"
expect B17-unqualified-force-ok-when-branch-lookup-fails 0 none ""

cd "$GITMAIN" || exit 1
run "$(bash_json "$PUSH ${FORCE}-with-lease")" bash "$BASH_GUARD"
expect B18-unqualified-lease-ok-on-main 0 none ""

cd "$WORK" || exit 1

run "$(bash_json 'ng test --runInBand')" bash "$BASH_GUARD"
expect B19-ng-test-runinband-still-blocks 2 err "BG004"

run "$(bash_json 'echo run npm install if needed')" bash "$BASH_GUARD"
expect B20-pm-mismatch-not-fooled-by-prose 0 none ""

run "$(bash_json 'confirm -rf pnpm-lock.yaml')" bash "$BASH_GUARD"
expect B21-rm-not-a-substring-of-another-word 0 none ""

run "$(bash_json 'sudo rm -rf node_modules pnpm-lock.yaml')" bash "$BASH_GUARD"
expect B22-sudo-rm-still-blocks 2 err "BG005"

# Finding 1 (round 3 review): a bare "*" among the push arguments must not
# glob-expand against this script's own cwd during tokenization — that would
# inflate the positional-word count and defeat the "no refspec named"
# inference. Create real files so the fixture doesn't depend on what happens
# to already be lying around in the directory.
cd "$GITMAIN" || exit 1
touch fileA fileB fileC
run "$(bash_json "$PUSH $FORCE *")" bash "$BASH_GUARD"
expect B23-glob-star-not-expanded-still-blocks 2 err "BG001"
rm -f fileA fileB fileC

# Finding 2 (round 3 review): colon refspecs — the destination side (after
# the colon) governs, not the source side.
cd "$GITMAIN" || exit 1
run "$(bash_json "$PUSH $FORCE origin HEAD:main")" bash "$BASH_GUARD"
expect B24-colon-refspec-dst-main-blocks 2 err "BG001"

run "$(bash_json "$PUSH $FORCE origin main:feature/x")" bash "$BASH_GUARD"
expect B25-colon-refspec-src-main-dst-feature-ok 0 none ""

# Finding 3 (round 3 review): detached HEAD, as a real fixture rather than an
# argument — no checked-out branch to infer, so an unqualified force push
# must fail open.
GITDETACHED="$TMPROOT/bg-git-detached"; mkdir -p "$GITDETACHED"
( cd "$GITDETACHED" && git init -q -b main . \
    && git -c user.email=a@a -c user.name=a commit -q --allow-empty -m init \
    && git checkout -q --detach ) >/dev/null 2>&1
cd "$GITDETACHED" || exit 1
run "$(bash_json "$PUSH $FORCE")" bash "$BASH_GUARD"
expect B26-unqualified-force-ok-detached-head 0 none ""

###############################################################################
echo
echo "== hooks.json wiring =="
###############################################################################

W1_OK=0
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$ROOT/hooks/hooks.json" 2>/dev/null || W1_OK=1
check W1-hooks-json-parses "hooks.json is valid JSON" "$W1_OK"

W2_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || W2_OK=1
import json, os, re, sys
root = sys.argv[1]
d = json.load(open(os.path.join(root, "hooks", "hooks.json")))["hooks"]
for ev in ("SessionStart", "PreToolUse", "PostToolUse", "SubagentStart"):
    assert ev in d, "missing event: " + ev
cmds = [h["command"] for groups in d.values() for g in groups for h in g["hooks"]]
assert len(cmds) == 5, "expected 5 hook commands, got %d" % len(cmds)
for c in cmds:
    assert "${CLAUDE_PLUGIN_ROOT}" in c, "hook not using CLAUDE_PLUGIN_ROOT: " + c
    for script in re.findall(r"\$\{CLAUDE_PLUGIN_ROOT\}/([A-Za-z0-9_./-]+)", c):
        p = os.path.join(root, script)
        assert os.path.exists(p), "referenced script missing: " + script
        assert os.access(p, os.X_OK), "referenced script not executable: " + script
matchers = sorted(g.get("matcher", "") for g in d["PreToolUse"])
assert matchers == ["Bash", "Write|Edit"], matchers
PY
check W2-hooks-wiring "5 commands, CLAUDE_PLUGIN_ROOT paths, scripts exist and are executable" "$W2_OK"

# Content and gating are covered by SA1-SA6; here only the fail-open contract:
# garbage stdin still exits 0.
W3_OK=0
run "not json" bash "$SUBAGENT"
[ "$CODE" = "0" ] || W3_OK=1
check W3-subagent-rules-fail-open "subagent-rules exits 0 on malformed input" "$W3_OK"

# W4: per-event/matcher wiring — script AND trailing mode token, checked
# together, so a hook-lint.sh pre/post swap between PreToolUse and
# PostToolUse fails loudly instead of passing W2's existence-only checks.
# The mode is parsed as a shell token (via shlex), not matched as a
# substring, so it can't be fooled by "pre" appearing inside a path or
# inside the literal string "PreToolUse".
W4_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || W4_OK=1
import json, os, re, shlex, sys

root = sys.argv[1]
d = json.load(open(os.path.join(root, "hooks", "hooks.json")))["hooks"]


def command_for(event, matcher):
    for group in d[event]:
        if group.get("matcher", "") == matcher:
            return group["hooks"][0]["command"]
    raise AssertionError("no %s group with matcher %r" % (event, matcher))


def script_and_mode(cmd):
    # Resolve the plugin-root var to a plain path segment so shlex sees an
    # ordinary word, then tokenize like a shell would (quotes respected).
    tokens = shlex.split(cmd.replace("${CLAUDE_PLUGIN_ROOT}", "PLUGIN_ROOT"))
    for i, tok in enumerate(tokens):
        if re.search(r"PLUGIN_ROOT/scripts/[A-Za-z0-9_.-]+\.sh$", tok):
            nxt = tokens[i + 1] if i + 1 < len(tokens) else None
            # A real mode argument is a bare word (pre/post). Anything else
            # immediately following the script — a redirection like
            # "2>/dev/null;", a control operator, or nothing at all — means
            # no mode argument was passed.
            mode = nxt if nxt and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", nxt) else None
            return tok, mode
    raise AssertionError("no script invocation found in: " + cmd)


expected = [
    ("PreToolUse", "Write|Edit", "scripts/hook-lint.sh", "pre"),
    ("PostToolUse", "Write|Edit", "scripts/hook-lint.sh", "post"),
    ("PreToolUse", "Bash", "scripts/bash-guard.sh", None),
    ("SessionStart", "", "scripts/detect_project.sh", None),
    ("SubagentStart", "", "scripts/subagent-rules.sh", None),
]

for event, matcher, script, want_mode in expected:
    cmd = command_for(event, matcher)
    got_script, got_mode = script_and_mode(cmd)
    assert got_script.endswith(script), (
        "%s/%s: expected script %s, got %s" % (event, matcher, script, got_script)
    )
    assert got_mode == want_mode, (
        "%s/%s (%s): expected mode %r, got %r"
        % (event, matcher, script, want_mode, got_mode)
    )
PY
check W4-hook-mode-wiring "each event+matcher invokes the right script with the right mode token" "$W4_OK"

###############################################################################
echo
echo "== NG001-NG009 (legacy Angular) =="
###############################################################################

V22="$TMPROOT/ng22"; ng_workspace "$V22" "22.0.0"; mkdir -p "$V22/src/app"
cd "$V22" || exit 1; bash "$DETECT" >/dev/null 2>&1

V21="$TMPROOT/ng21"; ng_workspace "$V21" "21.0.0"; mkdir -p "$V21/src/app"
cd "$V21" || exit 1; bash "$DETECT" >/dev/null 2>&1

UNK="$TMPROOT/ngunk"; mkdir -p "$UNK/src/app"
printf '{"version":1,"projects":{}}\n' > "$UNK/angular.json"
printf '{"name":"x","dependencies":{}}\n' > "$UNK/package.json"
cd "$UNK" || exit 1; bash "$DETECT" >/dev/null 2>&1

cd "$V22" || exit 1

# NG001 standalone: true
run "$(write_json "$V22/src/app/a.ts" '@Component({ selector: "app-a", standalone: true, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N001-fires 2 err "NG001"

run "$(write_json "$V22/src/app/a.ts" '@Component({ selector: "app-a", template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N001-silent 0 none ""

# NG002 @NgModule
run "$(write_json "$V22/src/app/m.ts" '@NgModule({ declarations: [] })
export class M {}')" bash "$HOOK_LINT" pre
expect N002-fires 2 err "NG002"

# NG003 structural directives — template file and inline template
run "$(write_json "$V22/src/app/a.html" '<div *ngIf="ready">hi</div>')" bash "$HOOK_LINT" pre
expect N003-html-ngif 2 err "NG003"

run "$(write_json "$V22/src/app/a.html" '<li *ngFor="let x of xs">{{x}}</li>')" bash "$HOOK_LINT" pre
expect N003-html-ngfor 2 err "NG003"

run "$(write_json "$V22/src/app/a.ts" '@Component({ template: `<div *ngIf="ready"></div>` })
export class A {}')" bash "$HOOK_LINT" pre
expect N003-inline-template 2 err "NG003"

run "$(write_json "$V22/src/app/a.html" '@if (ready) { <div>hi</div> }')" bash "$HOOK_LINT" pre
expect N003-silent 0 none ""

# Standing fixtures for the HTML-comment-stripping fix (comment stripper
# only handled // and /* */ before; *ngIf/[ngClass] sitting inside an
# HTML comment was a real false positive, fixed by teaching the stripper
# about <!-- --> both at top level and inside backtick template strings).
run "$(write_json "$V22/src/app/a.html" '<!-- old: <div *ngIf="x"></div> -->
<div>hi</div>')" bash "$HOOK_LINT" pre
expect N003-html-comment-only-silent 0 none ""

run "$(write_json "$V22/src/app/a.html" '<!-- unrelated note -->
<div *ngIf="ready">hi</div>')" bash "$HOOK_LINT" pre
expect N003-html-comment-plus-real-fires 2 err "NG003"

run "$(write_json "$V22/src/app/a.ts" '@Component({ template: `<!-- <div [ngClass]="x"></div> --><div>hi</div>` })
export class A {}')" bash "$HOOK_LINT" pre
expect N008-inline-template-comment-silent 0 none ""

# Boundary pin: an HTML-comment-looking sequence inside a quoted string is
# NOT a comment -- content after it must still be scanned normally.
run "$(write_json "$V22/src/app/a.html" '<div title="<!-- fake"></div>
<div *ngIf="ready">hi</div>')" bash "$HOOK_LINT" pre
expect N003-quoted-string-not-comment-boundary 2 err "NG003"

# NG004 constructor-parameter DI, including the multi-line form.
# Must be a decorated (Angular-managed) class, or the rule has no basis --
# see the false-positive guard fixtures below.
run "$(write_json "$V22/src/app/s.ts" '@Injectable()
export class S {
  constructor(
    private http: HttpClient,
    private router: Router,
  ) {}
}')" bash "$HOOK_LINT" pre
expect N004-multiline 2 err "NG004"

run "$(write_json "$V22/src/app/s.ts" '@Injectable()
export class S {
  private http = inject(HttpClient);
}')" bash "$HOOK_LINT" pre
expect N004-silent 0 none ""

# A plain constructor with no access modifier is not injection
run "$(write_json "$V22/src/app/p.ts" 'export class P {
  constructor(name: string) { this.name = name; }
}')" bash "$HOOK_LINT" pre
expect N004-plain-ctor-ok 0 none ""

# False-positive guard: an undecorated class using ordinary TypeScript
# constructor-parameter-property syntax (a plain data/value class) is NOT
# Angular DI and must not fire NG004, even though the parameter shape is
# textually identical to the DI pattern above.
run "$(write_json "$V22/src/app/money.ts" 'export class Money {
  constructor(private amount: number, private currency: string) {}
}')" bash "$HOOK_LINT" pre
expect N004-undecorated-ctor-ok 0 none ""

# NG005 decorators
run "$(write_json "$V22/src/app/a.ts" 'export class A { @Input() name!: string; }')" bash "$HOOK_LINT" pre
expect N005-input 2 err "NG005"

run "$(write_json "$V22/src/app/a.ts" 'export class A { @Output() saved = new EventEmitter(); }')" bash "$HOOK_LINT" pre
expect N005-output 2 err "NG005"

run "$(write_json "$V22/src/app/a.ts" 'export class A { readonly name = input.required<string>(); }')" bash "$HOOK_LINT" pre
expect N005-silent 0 none ""

# NG006 explicit OnPush — v22 only
run "$(write_json "$V22/src/app/a.ts" '@Component({ changeDetection: ChangeDetectionStrategy.OnPush, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N006-fires-on-v22 2 err "NG006"

cd "$V21" || exit 1
run "$(write_json "$V21/src/app/a.ts" '@Component({ changeDetection: ChangeDetectionStrategy.OnPush, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N006-silent-on-v21 0 none ""

# Gate discipline: unknown version silences every gated rule
cd "$UNK" || exit 1
run "$(write_json "$UNK/src/app/a.ts" '@Component({ standalone: true, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N001-silent-unknown-version 0 none ""

cd "$V22" || exit 1

# NG008 ngClass / ngStyle
run "$(write_json "$V22/src/app/a.html" '<div [ngClass]="{ active: on }"></div>')" bash "$HOOK_LINT" pre
expect N008-ngclass 2 err "NG008"

run "$(write_json "$V22/src/app/a.html" '<div [class.active]="on"></div>')" bash "$HOOK_LINT" pre
expect N008-silent 0 none ""

# NG009 host decorators
run "$(write_json "$V22/src/app/a.ts" 'export class A { @HostListener("click") onClick() {} }')" bash "$HOOK_LINT" pre
expect N009-hostlistener 2 err "NG009"

run "$(write_json "$V22/src/app/a.ts" '@Component({ host: { "(click)": "onClick()" }, template: "" })
export class A {}')" bash "$HOOK_LINT" pre
expect N009-silent 0 none ""

###############################################################################
echo
echo "== NG010-NG018 (reactivity, security, workspace-gated) =="
###############################################################################

cd "$V22" || exit 1

# NG010 subscribe without teardown
run "$(write_json "$V22/src/app/a.ts" 'export class A {
  ngOnInit() { this.svc.items$.subscribe((v) => this.items.set(v)); }
}')" bash "$HOOK_LINT" pre
expect N010-bare-subscribe 2 err "NG010"

run "$(write_json "$V22/src/app/a.ts" 'export class A {
  ngOnInit() { this.svc.items$.pipe(takeUntilDestroyed(this.ref)).subscribe((v) => this.items.set(v)); }
}')" bash "$HOOK_LINT" pre
expect N010-with-teardown-ok 0 none ""

# A file with one guarded and one bare subscription must still be caught
run "$(write_json "$V22/src/app/a.ts" 'export class A {
  a() { this.x$.pipe(takeUntilDestroyed()).subscribe(f); }
  b() { this.y$.subscribe(g); }
}')" bash "$HOOK_LINT" pre
expect N010-mixed-caught 2 err "NG010"

# Spec files are exempt — test subscriptions are scoped to the test
run "$(write_json "$V22/src/app/a.spec.ts" 'it("works", () => { obs$.subscribe(done); });')" bash "$HOOK_LINT" pre
expect N010-spec-exempt 0 none ""

# NG011 signal.mutate()
run "$(write_json "$V22/src/app/a.ts" 'this.items.mutate((v) => v.push(x));')" bash "$HOOK_LINT" pre
expect N011-mutate 2 err "NG011"

# NG012 effect() writing a signal
run "$(write_json "$V22/src/app/a.ts" 'effect(() => { this.total.set(this.a() + this.b()); });')" bash "$HOOK_LINT" pre
expect N012-effect-writes 2 err "NG012"

run "$(write_json "$V22/src/app/a.ts" 'readonly total = computed(() => this.a() + this.b());
effect(() => { console.log(this.total()); });')" bash "$HOOK_LINT" pre
expect N012-effect-readonly-ok 0 none ""

# A .set() outside any effect is fine
run "$(write_json "$V22/src/app/a.ts" 'onClick() { this.count.set(1); }')" bash "$HOOK_LINT" pre
expect N012-set-outside-effect-ok 0 none ""

# NG013 @for without track
run "$(write_json "$V22/src/app/a.html" '@for (item of items(); let i = $index) { <li>{{item}}</li> }')" bash "$HOOK_LINT" pre
expect N013-no-track 2 err "NG013"

run "$(write_json "$V22/src/app/a.html" '@for (item of items(); track item.id) { <li>{{item}}</li> }')" bash "$HOOK_LINT" pre
expect N013-track-ok 0 none ""

# NG014 innerHTML
run "$(write_json "$V22/src/app/a.html" '<div [innerHTML]="body"></div>')" bash "$HOOK_LINT" pre
expect N014-innerhtml 2 err "NG014"

# NG015 bypassSecurityTrust
run "$(write_json "$V22/src/app/a.ts" 'const u = this.san.bypassSecurityTrustHtml(raw);')" bash "$HOOK_LINT" pre
expect N015-bypass 2 err "NG015"

# NG016 secrets in environment files
run "$(write_json "$V22/src/environments/environment.ts" 'export const environment = { apiKey: "sk_live_abc123def456" };')" bash "$HOOK_LINT" pre
expect N016-secret 2 err "NG016"

run "$(write_json "$V22/src/environments/environment.ts" 'export const environment = { apiKey: "" };')" bash "$HOOK_LINT" pre
expect N016-empty-ok 0 none ""

run "$(write_json "$V22/src/environments/environment.ts" 'export const environment = { apiUrl: "https://api.example.com" };')" bash "$HOOK_LINT" pre
expect N016-nonsecret-ok 0 none ""

# NG017 zone.js in a zoneless workspace
run "$(write_json "$V22/src/app/a.ts" 'import "zone.js";')" bash "$HOOK_LINT" pre
expect N017-zonejs-zoneless 2 err "NG017"

# ...and silent in a workspace that still depends on zone.js
ZONED="$TMPROOT/zoned"; ng_workspace "$ZONED" "22.0.0" '{"zone.js":"~0.15.0"}'
mkdir -p "$ZONED/src/app"; cd "$ZONED" || exit 1; bash "$DETECT" >/dev/null 2>&1
run "$(write_json "$ZONED/src/app/a.ts" 'import "zone.js";')" bash "$HOOK_LINT" pre
expect N017-silent-when-zoned 0 none ""

# NG018 Jasmine APIs in a Vitest workspace
VIT="$TMPROOT/vit"; ng_workspace "$VIT" "22.0.0" '{"vitest":"^3.0.0"}'
mkdir -p "$VIT/src/app"; cd "$VIT" || exit 1; bash "$DETECT" >/dev/null 2>&1
run "$(write_json "$VIT/src/app/a.spec.ts" 'const spy = jasmine.createSpy("x");')" bash "$HOOK_LINT" pre
expect N018-jasmine-in-vitest 2 err "NG018"

run "$(write_json "$VIT/src/app/a.spec.ts" 'const spy = vi.fn();')" bash "$HOOK_LINT" pre
expect N018-vi-ok 0 none ""

# ...and silent in a Karma workspace
KAR="$TMPROOT/kar"; ng_workspace "$KAR" "21.0.0" '{"karma":"~6.4.0"}'
mkdir -p "$KAR/src/app"; cd "$KAR" || exit 1; bash "$DETECT" >/dev/null 2>&1
run "$(write_json "$KAR/src/app/a.spec.ts" 'const spy = jasmine.createSpy("x");')" bash "$HOOK_LINT" pre
expect N018-silent-on-karma 0 none ""

cd "$V22" || exit 1

###############################################################################
echo
echo "== NG101-NG106 (advisory, post mode) =="
###############################################################################

cd "$V22" || exit 1
mkdir -p "$V22/src/app"

post_file() { # <path> <content> — write to disk, then lint in post mode
  printf '%s' "$2" > "$1"
  run "$(write_json "$1" "$2")" bash "$HOOK_LINT" post
}

# NG101 eager feature route
post_file "$V22/src/app/app.routes.ts" 'export const routes: Routes = [
  { path: "admin", component: AdminPageComponent },
];'
expect N101-eager-route 2 err "NG101"

post_file "$V22/src/app/app.routes.ts" 'export const routes: Routes = [
  { path: "admin", loadComponent: () => import("./admin/admin-page").then((m) => m.AdminPage) },
];'
expect N101-lazy-ok 0 none ""

# NG102 FormBuilder where Signal Forms are available
post_file "$V22/src/app/f.ts" 'export class F { form = this.fb.group({ name: [""] }); }'
expect N102-formbuilder 2 err "NG102"

# ...silent on v21, where Signal Forms are not stable
cd "$V21" || exit 1; mkdir -p "$V21/src/app"
post_file "$V21/src/app/f.ts" 'export class F { form = this.fb.group({ name: [""] }); }'
expect N102-silent-on-v21 0 none ""
cd "$V22" || exit 1

# NG103 providedIn root where @Service exists
post_file "$V22/src/app/s.ts" '@Injectable({ providedIn: "root" })
export class S {}'
expect N103-providedin 2 err "NG103"

# NG104 static img without ngSrc
post_file "$V22/src/app/a.html" '<img src="/assets/hero.png" alt="Hero">'
expect N104-plain-img 2 err "NG104"

post_file "$V22/src/app/a.html" '<img ngSrc="/assets/hero.png" width="800" height="600" alt="Hero">'
expect N104-ngsrc-ok 0 none ""

# A data-bound src is not a static image
post_file "$V22/src/app/a.html" '<img [src]="avatarUrl()" alt="Avatar">'
expect N104-bound-src-ok 0 none ""

# Prettier wraps long <img> tags across lines as a matter of course, so the
# multiline form is the common shape in a formatted template, not an edge
# case. grep is line-based, so this must be matched against $COLLAPSED, not
# $CODE_PATH -- a line-based match stays silent on exactly this fixture.
post_file "$V22/src/app/a.html" '<img
  src="/assets/hero.png"
  alt="Hero">'
expect N104-multiline-src 2 err "NG104"

post_file "$V22/src/app/a.html" '<img
  ngSrc="/assets/hero.png"
  width="800" height="600"
  alt="Hero">'
expect N104-multiline-ngsrc-ok 0 none ""

# Pins the flattening boundary: [^>]* cannot cross a `>`, so collapsing this
# onto one line must not let the only <img> (ngSrc-only, no static src)
# bridge past its own closing `>` into the ` src=` that belongs to the
# unrelated <div> after it. A naive `.*` in place of `[^>]*` WOULD cross
# that boundary and fire here -- see the relax-and-restore proof in the
# task report -- which is what makes this assertion load-bearing.
post_file "$V22/src/app/a.html" '<img ngSrc="/assets/hero.png" width="800" height="600" alt="Hero">
<div class="caption" src="ignored"></div>'
expect N104-no-cross-tag-match 0 none ""

# NG105 direct DOM access in a component
post_file "$V22/src/app/a.component.ts" 'export class A { init() { document.getElementById("x"); } }'
expect N105-document-access 2 err "NG105"

# NG106 HTTP call inside a component
post_file "$V22/src/app/b.component.ts" 'export class B {
  private http = inject(HttpClient);
  load() { return this.http.get("/api/items"); }
}'
expect N106-http-in-component 2 err "NG106"

# A service making HTTP calls is correct
post_file "$V22/src/app/b.service.ts" 'export class BService {
  private http = inject(HttpClient);
  load() { return this.http.get("/api/items"); }
}'
expect N106-http-in-service-ok 0 none ""

# analyze_quality.sh runs standalone and always exits 0
QA="$ROOT/scripts/analyze_quality.sh"
run "" bash "$QA" "$V22/src/app/b.component.ts"
Q1_OK=0; [ "$CODE" = "0" ] || Q1_OK=1
check Q1-analyze-exit0 "analyze_quality.sh exits 0" "$Q1_OK"

run "" bash "$QA" /nonexistent/path.ts
Q2_OK=0; [ "$CODE" = "0" ] || Q2_OK=1
check Q2-analyze-missing-file "analyze_quality.sh fails open on a missing file" "$Q2_OK"

###############################################################################
echo
echo "== skills =="
###############################################################################

S1_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || S1_OK=1
import os, re, sys, glob
root = sys.argv[1]
# `paths` is Claude Code's glob-scoping field for skills. `file_patterns`
# and `auto_suggest` are not recognised and are silently ignored, so they
# must not come back.
REQUIRED = ["name", "description", "paths"]
skills = sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md")))
assert skills, "no skills found"
for p in skills:
    txt = open(p, encoding="utf-8").read()
    assert txt.startswith("---\n"), p + ": missing frontmatter"
    fm = txt.split("---", 2)[1]
    for key in ("name:", "description:", "paths:"):
        assert key in fm, "%s: frontmatter missing %s" % (p, key)
    for key in ("file_patterns", "auto_suggest"):
        assert not re.search(r"^%s:" % key, fm, re.M), "%s: unsupported key %s" % (p, key)
    assert "Angular" in re.search(r"^description:(.*)$", fm, re.M).group(1), \
        "%s: description must scope the skill to Angular" % p
    name = re.search(r"^name:\s*(\S+)", fm, re.M).group(1)
    assert name == os.path.basename(os.path.dirname(p)), \
        "%s: frontmatter name %r != directory name" % (p, name)
    # Order check: collect top-level frontmatter keys (matched at the start
    # of a line, so a key-like substring inside a value, e.g. "name:" typed
    # inside a description sentence, can never be mistaken for a real key),
    # keep only the required ones, and require they appear in the
    # mandated relative order. Any other key a skill adds is untouched by
    # this check -- the constraint is about the required keys, not an
    # exhaustive/forbidding schema.
    top_level_keys = re.findall(r"^([A-Za-z_][A-Za-z0-9_]*):", fm, re.M)
    required_in_order = [k for k in top_level_keys if k in REQUIRED]
    assert required_in_order == REQUIRED, \
        "%s: frontmatter keys out of order: got %r, want %r" % (p, required_in_order, REQUIRED)
    assert "RULES — Follow these with no exceptions" in txt, p + ": missing RULES section"
PY
check S1-skill-shape "every SKILL.md has valid frontmatter, ordered keys, and a RULES section" "$S1_OK"

S2_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || S2_OK=1
import os, re, sys, glob
root = sys.argv[1]
lint = open(os.path.join(root, "scripts", "hook-lint.sh"), encoding="utf-8").read()
defined = set(re.findall(r"check_(ng\d{3})\s*\(\)", lint))
defined = {d.upper() for d in defined}
guard = open(os.path.join(root, "scripts", "bash-guard.sh"), encoding="utf-8").read()
defined |= set(re.findall(r"\b(BG\d{3})\b", guard))
referenced = set()
for p in glob.glob(os.path.join(root, "skills", "*", "SKILL.md")):
    referenced |= set(re.findall(r"\b((?:NG|BG)\d{3})\b", open(p, encoding="utf-8").read()))
sub = open(os.path.join(root, "scripts", "subagent-rules.sh"), encoding="utf-8").read()
referenced |= set(re.findall(r"\b((?:NG|BG)\d{3})\b", sub))
orphans = sorted(referenced - defined)
assert not orphans, "rule IDs referenced but not implemented: " + ", ".join(orphans)
PY
check S2-no-orphan-rule-ids "every rule ID cited in a skill or subagent-rules exists in a script" "$S2_OK"

S3_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || S3_OK=1
import os, re, sys
root = sys.argv[1]
lint = open(os.path.join(root, "scripts", "hook-lint.sh"), encoding="utf-8").read()
pre = {d.upper() for d in re.findall(r"check_(ng0\d{2})\s*\(\)", lint)}
sub = open(os.path.join(root, "scripts", "subagent-rules.sh"), encoding="utf-8").read()
cited = set(re.findall(r"\b(NG0\d{2})\b", sub))
missing = sorted(pre - cited)
assert not missing, "blocking rules absent from the subagent rule set: " + ", ".join(missing)
PY
check S3-subagent-covers-blocking "every blocking NG0xx rule appears in subagent-rules.sh" "$S3_OK"

###############################################################################
echo
echo "== docs and agents =="
###############################################################################

R1_OK=0
for f in README.md CLAUDE.md.template CHANGELOG.md; do
  [ -s "$ROOT/$f" ] || R1_OK=1
done
check R1-docs-exist "README, CLAUDE.md.template, CHANGELOG are present and non-empty" "$R1_OK"

R2_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || R2_OK=1
import os, re, sys
root = sys.argv[1]
lint = open(os.path.join(root, "scripts", "hook-lint.sh"), encoding="utf-8").read()
guard = open(os.path.join(root, "scripts", "bash-guard.sh"), encoding="utf-8").read()
implemented = {d.upper() for d in re.findall(r"check_(ng\d{3})\s*\(\)", lint)}
implemented |= set(re.findall(r"\b(BG\d{3})\b", guard))
readme = open(os.path.join(root, "README.md"), encoding="utf-8").read()
documented = set(re.findall(r"\b((?:NG|BG)\d{3})\b", readme))
missing = sorted(implemented - documented)
assert not missing, "rules implemented but undocumented in README: " + ", ".join(missing)
PY
check R2-readme-documents-every-rule "every implemented rule ID appears in the README" "$R2_OK"

R3_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || R3_OK=1
import os, re, sys, glob
root = sys.argv[1]
agents = sorted(glob.glob(os.path.join(root, "agents", "*.md")))
assert len(agents) == 3, "expected 3 agents, got %d" % len(agents)
for p in agents:
    txt = open(p, encoding="utf-8").read()
    assert txt.startswith("---\n"), p + ": missing frontmatter"
    fm = txt.split("---", 2)[1]
    for key in ("name:", "description:", "tools:"):
        assert key in fm, "%s: frontmatter missing %s" % (p, key)
    assert "Write" not in fm.split("tools:")[1].split("\n")[0], \
        p + ": review agents must be read-only"
PY
check R3-agents-readonly "3 agents, valid frontmatter, no write tools" "$R3_OK"

R4_OK=0
grep -q '.angular-guide-project.json' "$ROOT/CLAUDE.md.template" 2>/dev/null || R4_OK=1
check R4-template-gitignore "CLAUDE.md.template tells users to gitignore the profile cache" "$R4_OK"

###############################################################################
echo
echo "== I2: NG007 extension guard + string-literal awareness =="
###############################################################################

cd "$V22" || exit 1

# Unlike NG005/NG009/NG011, NG007 had no [ "$EXT" = "ts" ] guard, so it ran
# on .html templates and blocked ordinary prose containing the word "any".
run "$(write_json "$V22/src/app/a.html" '<p>Pick a size: any of these will do.</p>')" bash "$HOOK_LINT" pre
expect I2-html-prose-silent 0 none ""

# ...and it matched "any" as a bare word anywhere, including inside a string
# literal in a .ts file, not just the TYPE position.
run "$(write_json "$V22/src/app/a.ts" 'export const MSG = "expected type: any but got string";')" bash "$HOOK_LINT" pre
expect I2-string-literal-silent 0 none ""

# Existing positive cases must still fire after both fixes.
run "$(write_json "$V22/src/app/a.ts" 'const x: any = 1;')" bash "$HOOK_LINT" pre
expect I2-type-annotation-fires 2 err "NG007"

run "$(write_json "$V22/src/app/a.ts" 'const y = x as any;')" bash "$HOOK_LINT" pre
expect I2-as-any-fires 2 err "NG007"

run "$(write_json "$V22/src/app/a.ts" 'const z = <any>x;')" bash "$HOOK_LINT" pre
expect I2-angle-any-fires 2 err "NG007"

###############################################################################
echo
echo "== I3: apostrophe/quote must not disable HTML comment stripping =="
###############################################################################

cd "$V22" || exit 1

# At top level a bare apostrophe in HTML text content ("Don't do this") used
# to open a string literal that never found a matching close, trapping the
# scanner in "inside a string" for the rest of the file -- so a REAL <!--
# --> comment appearing later was never blanked, and a *ngIf sitting inside
# it fired a false positive that blocked the write.
run "$(write_json "$V22/src/app/a.html" '<p>Don'"'"'t do this</p>
<!-- <div *ngIf="x"></div> -->')" bash "$HOOK_LINT" pre
expect I3-apostrophe-then-comment-silent 0 none ""

# The identical file with "Do not" (no apostrophe) was already silent --
# pin that behavior so this fixture is a real differential, not a rule that
# never fired either way.
run "$(write_json "$V22/src/app/a.html" '<p>Do not do this</p>
<!-- <div *ngIf="x"></div> -->')" bash "$HOOK_LINT" pre
expect I3-no-apostrophe-baseline-silent 0 none ""

# A real violation AFTER the apostrophe-bearing text must still fire --
# the apostrophe must not swallow enforcement for the rest of the file
# either (the mirror-image failure mode).
run "$(write_json "$V22/src/app/a.html" '<p>Don'"'"'t do this</p>
<div *ngIf="ready">hi</div>')" bash "$HOOK_LINT" pre
expect I3-apostrophe-then-real-violation-fires 2 err "NG003"

# Genuinely differential (verified against the pre-I3-fix script): an
# apostrophe in TEXT content, followed by an ORDINARY attribute-quoted tag
# that must still parse correctly, followed by a REAL <!-- --> comment.
# Pre-fix, the leading apostrophe traps the scanner in a runaway string for
# the rest of the file (the "card" attribute's quote never closes it, since
# it's a double quote and the trap is on a single quote) -- so the real
# comment is never recognized, and the *ngIf inside it wrongly fires.
# Post-fix, the apostrophe is inert, the attribute quote is parsed
# correctly on its own, and the real comment is recognized and blanked.
# (Plain `title="<!-- fake"` with no preceding apostrophe -- the original
# boundary case -- is unaffected by the I3 fix either way, which is why
# that scenario alone was not a valid differential fixture for this bug.)
run "$(write_json "$V22/src/app/a.html" $'<p>Don\'t</p>\n<div class="card"></div>\n<!-- <div *ngIf="x"></div> -->')" bash "$HOOK_LINT" pre
expect I3-apostrophe-then-attribute-then-comment-silent 0 none ""

###############################################################################
echo
echo "== I4: NG012 excludes writes inside untracked() =="
###############################################################################

cd "$V22" || exit 1

# untracked() is Angular's documented escape hatch for writing outside the
# reactive graph from inside an effect -- this must not fire.
run "$(write_json "$V22/src/app/a.ts" 'effect(() => { untracked(() => this.b.set(v)); });')" bash "$HOOK_LINT" pre
expect I4-untracked-set-silent 0 none ""

run "$(write_json "$V22/src/app/a.ts" 'effect(() => { untracked(() => { this.b.update((x) => x + 1); }); });')" bash "$HOOK_LINT" pre
expect I4-untracked-update-silent 0 none ""

# A write OUTSIDE the untracked() callback, even in an effect that also
# contains an untracked() call elsewhere, must still fire.
run "$(write_json "$V22/src/app/a.ts" 'effect(() => { untracked(() => console.log(this.a())); this.total.set(this.a()); });')" bash "$HOOK_LINT" pre
expect I4-write-outside-untracked-still-fires 2 err "NG012"

# A Map/WeakMap .set(k, v) takes two arguments; a signal .set() takes one,
# so the argument count tells them apart without type information.
run "$(write_json "$V22/src/app/a.ts" 'effect(() => { this.cache.set(k, v); });')" bash "$HOOK_LINT" pre
expect I4-plain-map-set-not-flagged 0 none ""

###############################################################################
echo
echo "== I5: monorepo -- bounded downward search when the upward walk finds nothing =="
###############################################################################

# A monorepo with angular.json at apps/web/ and a session started at the
# repo root: the upward walk from $PWD finds nothing, so before this fix the
# whole plugin went silently inert (no profile, no NG001-NG006/NG013/NG102/
# NG103). Bounded downward search should find the single angular.json and
# write the profile there.
I5A="$TMPROOT/i5-mono"; mkdir -p "$I5A/apps/web"
ng_workspace "$I5A/apps/web" "22.0.0"
cd "$I5A" || exit 1
run "" bash "$DETECT"
I5A_OK=0
[ "$CODE" = "0" ] || I5A_OK=1
[ -f "$I5A/apps/web/.angular-guide-project.json" ] || I5A_OK=1
[ -f "$I5A/.angular-guide-project.json" ] && I5A_OK=1
grep -q '"angular_major": 22' "$I5A/apps/web/.angular-guide-project.json" 2>/dev/null || I5A_OK=1
check I5-monorepo-downward-search "session at repo root finds the single nested angular.json downward" "$I5A_OK"

# node_modules must be pruned from the downward search -- an angular.json
# shipped inside a dependency must never be mistaken for the workspace root.
# The fake package ALSO gets a real package.json: without that, the
# assertion below would pass vacuously even if pruning were broken, because
# find_workspace_root_down would return the node_modules path but the
# separate `[ -f "$ROOT/package.json" ]` gate would then reject it anyway
# for missing a package.json -- the same outcome for the wrong reason. With
# a real package.json present, "no profile is written" is genuinely
# contingent on node_modules having been pruned from the search.
I5B="$TMPROOT/i5-nm"; mkdir -p "$I5B/node_modules/some-pkg"
printf '{"version":1,"projects":{}}\n' > "$I5B/node_modules/some-pkg/angular.json"
printf '{"name":"some-pkg","dependencies":{"@angular/core":"^22.0.0"}}\n' > "$I5B/node_modules/some-pkg/package.json"
cd "$I5B" || exit 1
run "" bash "$DETECT"
I5B_OK=0
[ "$CODE" = "0" ] || I5B_OK=1
[ ! -f "$I5B/.angular-guide-project.json" ] || I5B_OK=1
[ ! -f "$I5B/node_modules/some-pkg/.angular-guide-project.json" ] || I5B_OK=1
check I5b-monorepo-skips-node-modules "angular.json+package.json under node_modules is never treated as a workspace root" "$I5B_OK"

# Two angular.json files at the same shallowest depth: genuinely ambiguous.
# Writing no profile is correct -- guessing wrong would be worse than
# staying inert.
I5C="$TMPROOT/i5-ambig"; mkdir -p "$I5C/apps/web" "$I5C/apps/admin"
ng_workspace "$I5C/apps/web" "22.0.0"
ng_workspace "$I5C/apps/admin" "21.0.0"
cd "$I5C" || exit 1
run "" bash "$DETECT"
I5C_OK=0
[ "$CODE" = "0" ] || I5C_OK=1
[ ! -f "$I5C/apps/web/.angular-guide-project.json" ] || I5C_OK=1
[ ! -f "$I5C/apps/admin/.angular-guide-project.json" ] || I5C_OK=1
[ ! -f "$I5C/.angular-guide-project.json" ] || I5C_OK=1
check I5c-monorepo-ambiguous-writes-no-profile "two angular.json at the same depth -> no profile written, exit 0" "$I5C_OK"

cd "$ROOT" || exit 1

###############################################################################
echo
echo "== I6: no profile at all => plugin inert; unknown-version profile => ungated rules still run =="
###############################################################################

# Branch 1: no cached profile anywhere -- NG007 has no version gate, so
# without this fix it fired in ANY .ts file in ANY repository, including a
# plain non-Angular one (e.g. a bare Express project).
I6A="$TMPROOT/i6-noprofile"; mkdir -p "$I6A/src"
run "$(write_json "$I6A/src/index.ts" 'const x: any = 1;')" bash "$HOOK_LINT" pre
expect I6-no-profile-inert 0 none ""

# Branch 2: a profile DOES exist (angular.json + package.json were found)
# but angular_major is "unknown" -- this genuinely IS an Angular workspace,
# just one whose version couldn't be resolved, so ungated rules like NG007
# must still run (unchanged from before this fix).
I6B="$TMPROOT/i6-unknown"; mkdir -p "$I6B/src"
printf '{"version":1,"projects":{}}\n' > "$I6B/angular.json"
printf '{"name":"x","dependencies":{}}\n' > "$I6B/package.json"
(cd "$I6B" && bash "$DETECT" >/dev/null 2>&1)
run "$(write_json "$I6B/src/index.ts" 'const x: any = 1;')" bash "$HOOK_LINT" pre
expect I6-unknown-version-ungated-fires 2 err "NG007"

###############################################################################
echo
echo "== I7: unterminated /* or <!-- disables only that line, not the whole file =="
###############################################################################

cd "$V22" || exit 1

# An unterminated /* used to swallow everything after it as "inside a
# comment" -- a real violation on the very next line went completely
# unenforced for the rest of the file.
run "$(write_json "$V22/src/app/a.ts" $'/* TODO fix this later\nconst x: any = 1;\n')" bash "$HOOK_LINT" pre
expect I7-unterminated-block-comment-still-catches-next-line 2 err "NG007"

# Mirror case for HTML: an unterminated <!-- must not swallow a real
# violation on a later line.
run "$(write_json "$V22/src/app/a.html" $'<!-- unterminated comment\n<div *ngIf="ready">hi</div>\n')" bash "$HOOK_LINT" pre
expect I7-unterminated-html-comment-still-catches-next-line 2 err "NG003"


cd "$ROOT" || exit 1

###############################################################################
echo
echo "== BG001: fully-qualified refs/heads/main destination is caught =="
###############################################################################

cd "$GITMAIN" || exit 1
run "$(bash_json "$PUSH $FORCE origin HEAD:refs/heads/main")" bash "$BASH_GUARD"
expect BG001-fully-qualified-colon-refspec-dst-blocks 2 err "BG001"

run "$(bash_json "$PUSH $FORCE origin refs/heads/main")" bash "$BASH_GUARD"
expect BG001-fully-qualified-standalone-ref-blocks 2 err "BG001"

run "$(bash_json "$PUSH $FORCE origin HEAD:refs/heads/feature/x")" bash "$BASH_GUARD"
expect BG001-fully-qualified-colon-refspec-dst-feature-ok 0 none ""

cd "$WORK" || exit 1

###############################################################################
echo
echo "== M8: NG016 process.env exemption is per-occurrence, URLs excluded =="
###############################################################################

cd "$V22" || exit 1

# One unrelated process.env read anywhere in the file used to suppress a
# real secret on a completely different line -- the exemption is now
# per-line, not file-wide.
run "$(write_json "$V22/src/environments/environment.ts" $'export const environment = {\n  featureFlag: process.env["FF"],\n  apiKey: "sk_live_abc123def456",\n};\n')" bash "$HOOK_LINT" pre
expect M8-process-env-elsewhere-still-catches-real-secret 2 err "NG016"

# ...and an occurrence that genuinely reads from process.env on its OWN
# line is still exempt.
run "$(write_json "$V22/src/environments/environment.ts" 'export const environment = { apiKey: process.env.API_KEY || "" };')" bash "$HOOK_LINT" pre
expect M8-process-env-same-line-still-exempt 0 none ""

# A URL is not a secret, however secret-shaped its key name looks.
run "$(write_json "$V22/src/environments/environment.ts" 'export const environment = { tokenEndpoint: "https://auth/token" };')" bash "$HOOK_LINT" pre
expect M8-url-value-not-a-secret 0 none ""

cd "$ROOT" || exit 1

###############################################################################
echo
echo "== GNU-mktemp: explicit XXXXXX templates (mktemp -t alone is BSD-only) =="
###############################################################################

# `mktemp -t <prefix>` with no X's in the template is accepted by BSD/macOS
# mktemp but REJECTED by GNU coreutils mktemp ("too few X's in template").
# Both META_TMP (the fp/tp handoff file) and CODE_TMP (the comment-stripped
# copy) must use an explicit XXXXXX template, or the plugin is silently dead
# on every Linux deployment: mktemp fails, `|| exit 0` fires immediately, and
# every one of the 30 rules stops enforcing anything -- failing open, so it
# never wedges a session, but it also never blocks anything again.
#
# Stub mktemp the way GNU coreutils actually behaves: reject any template
# whose last path component lacks at least 3 consecutive X's, delegate to
# the real mktemp otherwise. This is the same PATH-shadowing technique as
# H11, generalized to reject on template SHAPE rather than failing
# unconditionally.
REAL_MKTEMP="$(command -v mktemp)"
GNUBIN="$TMPROOT/gnu-mktemp"; mkdir -p "$GNUBIN"
cat > "$GNUBIN/mktemp" <<EOF
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    -*) continue ;;
  esac
  base=\$(basename "\$arg")
  case "\$base" in
    *XXX*) : ;;
    *) echo "mktemp: too few X's in template '\$arg'" >&2; exit 1 ;;
  esac
done
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$GNUBIN/mktemp"

cd "$V22" || exit 1

# Prove it fails against the pre-fix code: a plain known violation, run
# under the GNU-like mktemp, must still fire -- not silently pass because
# the plugin died at its first mktemp call.
run "$(write_json "$V22/src/app/a.ts" 'const x: any = 1;')" env PATH="$GNUBIN:$PATH" bash "$HOOK_LINT" pre
expect GNU1-pre-mode-real-violation-still-fires 2 err "NG007"

# ...and post mode (which also exercises CODE_TMP) must likewise still work.
# post mode reads FILE_PATH straight off disk, so the file must actually be
# written there first (mirrors the post_file() helper below, without its
# unrelated default-PATH `run` call, which would just be overwritten here).
printf '%s' '<img src="/assets/hero.png" alt="Hero">' > "$V22/src/app/a.html"
run "$(write_json "$V22/src/app/a.html" '<img src="/assets/hero.png" alt="Hero">')" env PATH="$GNUBIN:$PATH" bash "$HOOK_LINT" post
expect GNU2-post-mode-real-violation-still-fires 2 err "NG104"

cd "$ROOT" || exit 1

###############################################################################
echo
echo "== C1: file_path newline injection (arbitrary file deletion) =="
###############################################################################

# The embedded python communicated fp/tp back to bash as two stdout lines
# read with `sed -n '1p'`/`sed -n '2p'`. A file_path containing a newline
# shifted that protocol: CONTENT_PATH became the newline-split second
# segment -- an attacker-chosen RELATIVE path -- and the cleanup trap's
# alias guard only compared against FILE_PATH, so `rm -f "$CODE_PATH"`
# deleted it. file_path is model-authored, so this is reachable from prompt
# injection with no rule needing to fire. Reproduces against a decoy file in
# the cwd: must exit 0 AND leave the decoy untouched.
C1_DIR="$TMPROOT/c1"; mkdir -p "$C1_DIR"
cd "$C1_DIR" || exit 1
printf '%s' "decoy-content" > decoy.ts
C1_FP=$'/tmp/angular-guide-c1-nonexistent/x.ts\ndecoy.ts'
run "$(write_json "$C1_FP" 'const x = 1;')" bash "$HOOK_LINT" pre
C1_OK=0
[ "$CODE" = "0" ] || C1_OK=1
[ -f "$C1_DIR/decoy.ts" ] || C1_OK=1
[ "$(cat "$C1_DIR/decoy.ts" 2>/dev/null)" = "decoy-content" ] || C1_OK=1
check C1-newline-filepath-no-deletion "newline-bearing file_path: exit 0, decoy file in cwd survives" "$C1_OK"

cd "$ROOT" || exit 1

###############################################################################
echo
echo "== PY-I: hooks never import modules from the user's project directory =="
###############################################################################

# `python3 -` and `python3 -c` put the cwd on sys.path, so a repository with
# a json.py or re.py would have it executed by every hook -- SessionStart
# included -- just by opening a session there. Every interpreter must run
# isolated (-I). Each planted module writes a marker if it is ever imported.
PYI="$TMPROOT/pyi"; ng_workspace "$PYI" "22.0.0"; mkdir -p "$PYI/src/app"
for mod in json re os sys math tempfile collections shlex hashlib datetime; do
  printf 'open(%s, "a").write("%s\\n")\n' "'$PYI/PWNED'" "$mod" > "$PYI/$mod.py"
done
cd "$PYI" || exit 1
bash "$DETECT" >/dev/null 2>&1
run "$(write_json "$PYI/src/app/a.ts" 'const x: any = 1;')" bash "$HOOK_LINT" pre
printf 'x' > "$PYI/src/app/b.component.ts"
run "$(write_json "$PYI/src/app/b.component.ts" 'x')" bash "$HOOK_LINT" post
run "$(bash_json 'ng build --prod')" bash "$BASH_GUARD"
run '{"hook_event_name":"SubagentStart"}' bash "$SUBAGENT"
PYI_OK=0
[ ! -f "$PYI/PWNED" ] || PYI_OK=1
check PY-I-isolated-interpreters "no planted module in the project dir is imported by any hook ($(tr '\n' ' ' < "$PYI/PWNED" 2>/dev/null))" "$PYI_OK"
cd "$ROOT" || exit 1

###############################################################################
echo
echo "== 1.1.0: SubagentStart emits JSON additionalContext, gated on the profile =="
###############################################################################

# Claude Code only injects SubagentStart output that arrives as JSON
# hookSpecificOutput.additionalContext -- plain stdout goes to the debug log.
# sa_context <dir> -- run subagent-rules.sh from <dir>, print additionalContext
# (empty when stdout is empty or not the expected JSON shape).
sa_context() {
  cd "$1" || exit 1
  run '{"hook_event_name":"SubagentStart"}' bash "$SUBAGENT"
  printf '%s' "$OUT" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)
d = json.loads(raw)
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "SubagentStart"
print(h["additionalContext"])
' 2>/dev/null
}

SA1=$(sa_context "$V22")
SA1_OK=0
[ "$CODE" = "0" ] || SA1_OK=1
for want in NG001 NG004 NG006 NG013 NG017 "inject()" "Angular 22"; do
  printf '%s' "$SA1" | grep -qF "$want" || SA1_OK=1
done
printf '%s' "$SA1" | grep -qF "NG018" && SA1_OK=1
check SA1-v22-json-context "v22 zoneless, no vitest: JSON context with v20/v22/zoneless rules, no NG018" "$SA1_OK"

SA2=$(sa_context "$V21")
SA2_OK=0
printf '%s' "$SA2" | grep -qF "NG001" || SA2_OK=1
printf '%s' "$SA2" | grep -qF "NG006" && SA2_OK=1
check SA2-v21-no-onpush-rule "v21: v20 rules present, NG006 (OnPush default) absent" "$SA2_OK"

SA3=$(sa_context "$UNK")
SA3_OK=0
printf '%s' "$SA3" | grep -qF "NG007" || SA3_OK=1
printf '%s' "$SA3" | grep -qF "NG001" && SA3_OK=1
check SA3-unknown-version-ungated-only "unknown version: ungated rules only, no NG001" "$SA3_OK"

SA_NONNG="$TMPROOT/not-angular"; mkdir -p "$SA_NONNG"
sa_context "$SA_NONNG" >/dev/null
SA4_OK=0
[ "$CODE" = "0" ] && [ -z "$OUT" ] || SA4_OK=1
check SA4-non-angular-silent "no profile anywhere: exit 0, no output" "$SA4_OK"

# The hook payload's cwd wins over the process cwd.
cd "$SA_NONNG" || exit 1
run "$(python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"SubagentStart","cwd":sys.argv[1]}))' "$V22")" bash "$SUBAGENT"
SA5_OK=0
printf '%s' "$OUT" | grep -qF "NG001" || SA5_OK=1
check SA5-payload-cwd "profile is found from the payload cwd, not just the process cwd" "$SA5_OK"

VT="$TMPROOT/ng22-vitest"; ng_workspace "$VT" "22.0.0" '{"vitest":"^3.0.0"}'
cd "$VT" || exit 1; bash "$DETECT" >/dev/null 2>&1
SA6=$(sa_context "$VT")
SA6_OK=0
printf '%s' "$SA6" | grep -qF "NG018" || SA6_OK=1
check SA6-vitest-adds-ng018 "vitest workspace: NG018 included" "$SA6_OK"

###############################################################################
echo
echo "== 1.1.0: skills use the current resource() API =="
###############################################################################

# Angular v20 renamed resource()'s `request` option to `params` (and the
# loader argument with it). The skills must not teach the removed shape.
R4_OK=0
python3 - "$ROOT" <<'PY' 2>/dev/null || R4_OK=1
import glob, os, re, sys
bad = []
for p in glob.glob(os.path.join(sys.argv[1], "skills", "*", "SKILL.md")):
    txt = open(p, encoding="utf-8").read()
    for pat in (r"\brequest:\s*\(\)", r"\(\{\s*request\s*\}\)"):
        if re.search(pat, txt):
            bad.append("%s: %s" % (os.path.basename(os.path.dirname(p)), pat))
assert not bad, bad
PY
check R4-resource-params-api "no skill uses resource({ request }) -- it is params since v20" "$R4_OK"

###############################################################################
echo
echo "== 1.1.0: false-positive fixes (NG010, NG012, NG016, NG105) =="
###############################################################################

cd "$V22" || exit 1

# NG010: the chain start is found by walking back at paren depth 0, so an
# arrow function inside an earlier operator no longer truncates the chain.
run "$(write_json "$V22/src/app/a.ts" 'export class A {
  constructor() { this.obs$.pipe(takeUntilDestroyed(), map((x) => x.id)).subscribe((v) => this.v.set(v)); }
}')" bash "$HOOK_LINT" pre
expect FP-N010-teardown-before-arrow-op 0 none ""

run "$(write_json "$V22/src/app/a.ts" 'export class A {
  constructor() { this.obs$.pipe(take(1), filter((x) => { return !!x; })).subscribe(f); }
}')" bash "$HOOK_LINT" pre
expect FP-N010-teardown-before-block-arrow 0 none ""

run "$(write_json "$V22/src/app/a.ts" 'export class A {
  constructor() { this.obs$.pipe(map((x) => x.id)).subscribe(f); }
}')" bash "$HOOK_LINT" pre
expect FP-N010-arrow-op-no-teardown-still-fires 2 err "NG010"

# A teardown in an enclosing call does not cover an inner subscribe.
run "$(write_json "$V22/src/app/a.ts" 'export class A {
  constructor() { take(this.obs$.subscribe(f)); }
}')" bash "$HOOK_LINT" pre
expect FP-N010-enclosing-call-not-teardown 2 err "NG010"

# NG012: signal .set()/.update() take exactly one argument; a two-argument
# .set() is a Map, HttpParams, HttpHeaders, URLSearchParams or FormData.
run "$(write_json "$V22/src/app/a.ts" 'effect(() => { const p = new HttpParams().set("q", this.q()); this.log(p); });')" bash "$HOOK_LINT" pre
expect FP-N012-httpparams-set 0 none ""

run "$(write_json "$V22/src/app/a.ts" 'effect(() => { this.cache.set(this.id(), { at: Date.now(), v: 1 }); });')" bash "$HOOK_LINT" pre
expect FP-N012-map-set-two-args 0 none ""

run "$(write_json "$V22/src/app/a.ts" 'effect(() => { this.state.set({ a: this.a(), b: this.b() }); });')" bash "$HOOK_LINT" pre
expect FP-N012-object-arg-still-fires 2 err "NG012"

run "$(write_json "$V22/src/app/a.ts" 'effect(() => { this.pair.set([this.a(), this.b()]); });')" bash "$HOOK_LINT" pre
expect FP-N012-array-arg-still-fires 2 err "NG012"

run "$(write_json "$V22/src/app/a.ts" 'effect(() => { this.label.set(fmt("a, b", this.a())); });')" bash "$HOOK_LINT" pre
expect FP-N012-comma-in-string-still-fires 2 err "NG012"

# NG016: judge the value, not just the key name.
ENV="$V22/src/environments/environment.ts"
run "$(write_json "$ENV" 'export const environment = { storageKey: "app-theme", hotkey: "ctrl+k" };')" bash "$HOOK_LINT" pre
expect FP-N016-storage-key-name 0 none ""

run "$(write_json "$ENV" 'export const environment = { firebase: { apiKey: "AIzaSyD-9tSrke72PouQMnMX-a7eZSW0jkFMBWY", authDomain: "demo.firebaseapp.com" } };')" bash "$HOOK_LINT" pre
expect FP-N016-firebase-web-key-public 0 none ""

run "$(write_json "$ENV" 'export const environment = { cacheKeyPrefix: "my-app-user-preferences-v2" };')" bash "$HOOK_LINT" pre
expect FP-N016-long-readable-value 0 none ""

run "$(write_json "$ENV" 'export const environment = { dbPassword: "hunter2" };')" bash "$HOOK_LINT" pre
expect FP-N016-password-any-value-fires 2 err "NG016"

run "$(write_json "$ENV" 'export const environment = { githubToken: "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8" };')" bash "$HOOK_LINT" pre
expect FP-N016-known-prefix-fires 2 err "NG016"

run "$(write_json "$ENV" 'export const environment = { apiKey: "q8ZtV3mK1xN7pR4wL9sB2dH6fJ0cY5gT" };')" bash "$HOOK_LINT" pre
expect FP-N016-high-entropy-key-fires 2 err "NG016"

# NG105: an injected DOCUMENT (this.document) is the rule's own fix.
post_file "$V22/src/app/d.component.ts" 'export class D {
  private readonly document = inject(DOCUMENT);
  focus() { this.document.body.classList.add("x"); }
}'
expect FP-N105-injected-document 0 none ""

post_file "$V22/src/app/d.component.ts" 'export class D { w() { return window.innerWidth; } }'
expect FP-N105-global-window-still-fires 2 err "NG105"

cd "$ROOT" || exit 1

###############################################################################
echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || { printf '  - %s\n' "${FAILED_NAMES[@]}"; exit 1; }
exit 0
